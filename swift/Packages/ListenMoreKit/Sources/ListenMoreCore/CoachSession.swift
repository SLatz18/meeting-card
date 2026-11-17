import Foundation

// MARK: seams (ListenMoreMac provides the real ones; tests provide fakes)

/// The user's microphone. `handler` receives mono Float32 at `sampleRate`, on any thread.
public protocol MicSource: AnyObject {
    func start(sampleRate: Int, handler: @escaping @Sendable ([Float]) -> Void) throws
    func stop()
}

/// Call output ("everyone else"). Restarted with a higher `stage` when the helper fallback engages.
public protocol CallSource: AnyObject, Sendable {
    func start(bundleIds: [String], stage: CaptureStage, sampleRate: Int,
               handler: @escaping @Sendable ([Float]) -> Void) async throws
    func stop() async
}

/// What window-title detection (`WindowTitleSignal`) looks at: visible window titles and
/// per-process "is producing audio" flags.
public protocol MeetingProbe: AnyObject {
    func windows() -> [WindowInfo]
    func audioActive() -> [String: Bool]
}

public protocol APIKeyProvider {
    /// nil when no key is stored. Implementations never log the key.
    func readKey() throws -> APIKey?
}

/// Draws a cue. The host's renderer owns every visual decision (via `CoachStyle` or its own theme).
@MainActor
public protocol CueRenderer: AnyObject {
    func render(_ cue: Cue)
    func clear()
}

@MainActor
public protocol CoachSessionDelegate: AnyObject {
    /// The indicator, session, capture or GPT state changed; read them off the session.
    func coachSessionDidChange(_ session: CoachSession)
    func coachSession(_ session: CoachSession, didShow cue: Cue)
    /// Counters and error classes only, never content.
    func coachSession(_ session: CoachSession, didReport problem: CoachSession.Problem)
}

public extension CoachSessionDelegate {
    func coachSessionDidChange(_ session: CoachSession) {}
    func coachSession(_ session: CoachSession, didShow cue: Cue) {}
    func coachSession(_ session: CoachSession, didReport problem: CoachSession.Problem) {}
}

// MARK: session

/// The coach session runner: `CoachTrigger` (auto-on from a `CallSignal`, manual Start, Pause, skip
/// this call, join hints) decides when to listen; mic + call capture with the Chromium helper fallback
/// feed the engine; suggestions pass through `CuePolicy` to the host's renderer. Capture and the engine
/// (and with it every OpenAI session) run only while a session is active and not paused. Audio and
/// text stay in memory.
@MainActor
public final class CoachSession {
    public enum Problem: Equatable, Sendable {
        case micUnavailable
        case callCaptureFailed(stage: CaptureStage)
        case keyUnreadable
        case fallbackEngaged(stage: CaptureStage)
    }

    public let config: ListenMoreConfig
    public weak var delegate: CoachSessionDelegate?
    public private(set) var trigger: CoachTrigger
    public private(set) var capturingBundleIds: [String] = []
    public private(set) var captureStage: CaptureStage = .parentApps
    /// Set when the GPT layer turned itself off this session (local cues continue).
    public private(set) var gptStopped: GptStopReason?
    /// Set when judging stopped this session after repeated provider failures: the failure that
    /// stopped it (transcription, the transcript rules and local cues continue). Kept until the next session.
    public private(set) var judgeStopped: JudgeFailure?
    /// Cues shown in the current session (a live counter; reset at start, never kept).
    public private(set) var cuesShown = 0
    /// Mic or call capture failed to start in the current session (usually a missing permission).
    public private(set) var captureProblem = false

    private let engine: EngineQueue
    private let mic: MicSource
    private let call: CallSource
    private let signal: CallSignal
    private let callState: CallStateProvider?
    private let keys: APIKeyProvider
    private let renderer: CueRenderer
    private let cuePolicy: CuePolicy
    private let wallClock: () -> TimeInterval
    private let gate = AudioGate()
    private var gateGeneration = 0
    private var fallback = CaptureFallbackPolicy()
    private let callLevel = CallLevelMeter()
    private var shownAt: [CueType: TimeInterval] = [:]
    private var timer: Timer?
    private var callTask: Task<Void, Never>?
    private var bridge: EngineDelegateBridge?

    public init(config: ListenMoreConfig, engine: CoachEngine, mic: MicSource, call: CallSource, signal: CallSignal,
                keys: APIKeyProvider, renderer: CueRenderer, settings: TriggerSettings, enabled: Bool = true,
                callState: CallStateProvider? = nil,
                wallClock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.config = config
        self.engine = EngineQueue(engine)
        self.mic = mic
        self.call = call
        self.signal = signal
        self.callState = callState
        self.keys = keys
        self.renderer = renderer
        self.wallClock = wallClock
        trigger = CoachTrigger(settings: settings, enabled: enabled)
        cuePolicy = CuePolicy(config: config.cues)
        let bridge = EngineDelegateBridge()
        self.bridge = bridge
        self.engine.delegate = bridge
        bridge.session = self
    }

    public var indicator: CoachIndicator { trigger.indicator }
    public var session: TriggerSession? { trigger.session }
    public var isEnabled: Bool { trigger.enabled }
    public var isCapturing: Bool { !capturingBundleIds.isEmpty }

    /// Polls the call signal every `interval` (default `trigger.poll_s`) until `stopPolling()`.
    public func startPolling(interval: TimeInterval? = nil) {
        guard timer == nil else { return }
        let t = Timer(timeInterval: interval ?? config.trigger.pollS, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    public func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    public var isPolling: Bool { timer != nil }

    public func shutdown() {
        stopPolling()
        apply(trigger.setEnabled(false))
        stopCapture()
    }

    // MARK: controls

    /// The opt-in switch. Off ends any session and stops polling-driven starts.
    public func setEnabled(_ on: Bool) {
        apply(trigger.setEnabled(on))
        changed()
    }

    /// New allowlist / any-app / exclusion settings (takes effect on the next poll).
    public func update(settings: TriggerSettings) {
        trigger.settings = settings
        changed()
    }

    /// Manual Start, or Resume if paused.
    public func startManual() { apply(trigger.manualStart(now: wallClock())) }
    public func stopManual() { apply(trigger.manualStop()) }
    public func setPaused(_ paused: Bool) { apply(trigger.setPaused(paused)) }

    /// Pause while pre-warmed (indicator `.on`): skip this call. Nothing starts for the call that is
    /// starting now; the next call starts normally.
    public func skipThisCall() {
        trigger.dismissPrewarm()
        changed()
    }

    /// One control for the indicator: skip while pre-warmed, Pause while listening or muted, Resume
    /// while paused (still held if the call app is muted).
    public func toggleFromIndicator() {
        switch indicator {
        case .hidden: break
        case .on: skipThisCall()
        case .listening, .muted: setPaused(true)
        case .paused: setPaused(false)
        }
    }

    /// The user joined a calendar event ending at `endsAt` (seconds on this session's clock): a hint
    /// for when the session should end, never a start.
    public func joinHint(endsAt: TimeInterval) {
        trigger.joinHint(endsAt: endsAt, now: wallClock())
        changed()
    }

    public func joinHint(endsAt date: Date) {
        joinHint(endsAt: wallClock() + date.timeIntervalSinceNow)
    }

    /// Seconds left before each cue type can glow again (for hosts whose style shows cooldowns).
    public func cooldowns() -> [CueType: TimeInterval] {
        let now = wallClock()
        var out: [CueType: TimeInterval] = [:]
        for (type, at) in shownAt {
            let left = cuePolicy.cooldown - (now - at)
            if left > 0 { out[type] = left }
        }
        return out
    }

    // MARK: trigger + capture

    public func tick() {
        let before = indicator
        let reading = signal.poll(trigger.settings)
        let actions = trigger.tick(liveApps: reading.liveApps, inputRunning: reading.inputRunning, now: wallClock(),
                                   callStates: callState?.callStates() ?? [:])
        apply(actions)
        // A manual session adopting the call app changes what to capture without an action.
        if actions.isEmpty && (syncCapture() || indicator != before) { changed() }
        checkCallFallback()
    }

    private func apply(_ actions: [TriggerAction]) {
        guard !actions.isEmpty else { return }
        for a in actions {
            switch a {
            case .start:
                // A new session never inherits the previous one's engine (or OpenAI sessions).
                stopCapture()
                cuePolicy.reset()
                shownAt.removeAll()
                gptStopped = nil
                judgeStopped = nil
                cuesShown = 0
                captureProblem = false
            case .stop:
                renderer.clear()
            case .pause(let paused):
                cuePolicy.paused = paused
                if paused { renderer.clear() }
            }
        }
        syncCapture()
        changed()
    }

    @discardableResult
    private func syncCapture() -> Bool {
        let wanted = wantedBundleIds()
        guard wanted != capturingBundleIds else { return false }
        if wanted.isEmpty {
            stopCapture()
        } else {
            startCapture(bundleIds: wanted, stage: .parentApps)
        }
        return true
    }

    /// What to capture: the session's app, or every configured call app for a manual start with no
    /// call yet. Nothing while paused, muted in the call app, or without a session.
    func wantedBundleIds() -> [String] {
        guard let s = trigger.session, !s.held else { return [] }
        return s.appKey.map { [$0] } ?? config.captureTargets.map(\.bundleId)
    }

    private func startCapture(bundleIds: [String], stage: CaptureStage) {
        let isNewSession = capturingBundleIds.isEmpty
        capturingBundleIds = bundleIds
        captureStage = stage
        let engine = engine
        let gate = gate
        if isNewSession {
            fallback.reset()
            callLevel.reset()
            let key: APIKey?
            do {
                key = try keys.readKey()
            } catch {
                key = nil
                delegate?.coachSession(self, didReport: .keyUnreadable)
            }
            gateGeneration = gate.openNew()
            engine.start(config: config, apiKey: key)
            let gen = gateGeneration
            do {
                try mic.start(sampleRate: config.audio.sampleRate) { samples in
                    if gate.admits(gen) { engine.ingest(.mic, samples: samples, time: 0) }
                }
            } catch {
                captureProblem = true
                delegate?.coachSession(self, didReport: .micUnavailable)
            }
        }
        let level = callLevel
        let call = call
        let rate = config.audio.sampleRate
        let gen = gateGeneration
        // Capture operations run strictly in order; a start superseded before it runs is skipped.
        let previous = callTask
        previous?.cancel()
        callTask = Task { [weak self] in
            await previous?.value
            guard !Task.isCancelled else { return }
            do {
                try await call.start(bundleIds: bundleIds, stage: stage, sampleRate: rate) { samples in
                    guard gate.admits(gen) else { return }
                    level.record(samples)
                    engine.ingest(.call, samples: samples, time: 0)
                }
                if !gate.admits(gen) { await call.stop() }
            } catch {
                guard let self, gate.admits(gen) else { return }
                self.captureProblem = true
                self.delegate?.coachSession(self, didReport: .callCaptureFailed(stage: stage))
                self.changed()
            }
        }
    }

    private func stopCapture() {
        guard !capturingBundleIds.isEmpty else { return }
        // Closed first and synchronously: not one buffer reaches the engine (or OpenAI) after this,
        // even while call capture is still stopping asynchronously.
        gate.close()
        capturingBundleIds = []
        captureStage = .parentApps
        let previous = callTask
        previous?.cancel()
        mic.stop()
        let call = call
        callTask = Task {
            await previous?.value
            await call.stop()
        }
        engine.stop()
        callLevel.reset()
        renderer.clear()
    }

    /// Chromium helper fallback: if the call stream stays silent while the captured app's helpers
    /// (`<bundle id>.*`, e.g. Chrome, Dia, or Electron apps like Slack) are producing output, per-app
    /// filtering missed them; escalate to helper apps, then a process tap.
    private func checkCallFallback() {
        guard !capturingBundleIds.isEmpty else { return }
        let helpersAudible = signal.helpersAudible(bundleIds: capturingBundleIds)
        let now = wallClock()
        if let next = fallback.observe(callDbfs: callLevel.recentDbfs(now: now), helpersAudible: helpersAudible, now: now) {
            delegate?.coachSession(self, didReport: .fallbackEngaged(stage: next))
            startCapture(bundleIds: capturingBundleIds, stage: next)
        }
    }

    fileprivate func show(_ s: CueSuggestion) {
        guard isCapturing,
              let cue = cuePolicy.offer(s.type, t: s.t, onset: s.onset, source: s.source, confidence: s.confidence, level: s.level) else { return }
        shownAt[cue.type] = wallClock()
        cuesShown += 1
        renderer.render(cue)
        delegate?.coachSession(self, didShow: cue)
    }

    fileprivate func gptDidStop(_ reason: GptStopReason) {
        guard isCapturing else { return }
        gptStopped = reason
        changed()
    }

    fileprivate func judgeDidStop(_ failure: JudgeFailure) {
        guard isCapturing else { return }
        judgeStopped = failure
        changed()
    }

    private func changed() {
        delegate?.coachSessionDidChange(self)
    }

    /// Test hook: wait until every queued engine call has run.
    func drainEngineForTesting() {
        engine.drain()
    }

    /// Test hook: deliver a suggestion as if the engine produced it.
    func deliverForTesting(_ s: CueSuggestion) {
        show(s)
    }
}

/// On/off switch between capture callbacks (any thread) and the engine. Each session opens a new
/// generation, so a straggling buffer from an earlier session is never admitted into a later one.
final class AudioGate: @unchecked Sendable {
    private let lock = NSLock()
    private var generation = 0
    private var open = false

    func openNew() -> Int {
        lock.lock()
        defer { lock.unlock() }
        generation += 1
        open = true
        return generation
    }

    func close() {
        lock.lock()
        open = false
        generation += 1
        lock.unlock()
    }

    func admits(_ gen: Int) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return open && gen == generation
    }
}

/// Forwards engine callbacks (from the engine queue) to the session on the main thread.
final class EngineDelegateBridge: CoachEngineDelegate, @unchecked Sendable {
    @MainActor weak var session: CoachSession?

    func engine(_ engine: CoachEngine, didSuggest cue: CueSuggestion) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.session?.show(cue) }
        }
    }

    func engine(_ engine: CoachEngine, gptStopped reason: GptStopReason) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.session?.gptDidStop(reason) }
        }
    }

    func engine(_ engine: CoachEngine, judgeStopped failure: JudgeFailure) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.session?.judgeDidStop(failure) }
        }
    }
}

/// Serializes every call into the engine on one queue, so `CoachEngine` implementations need no locks.
public final class EngineQueue: @unchecked Sendable {
    private let engine: CoachEngine
    private let queue = DispatchQueue(label: "com.listenmore.engine", qos: .userInteractive)

    public init(_ engine: CoachEngine) {
        self.engine = engine
    }

    public var delegate: CoachEngineDelegate? {
        get { queue.sync { engine.delegate } }
        set { queue.sync { engine.delegate = newValue } }
    }

    public func start(config: ListenMoreConfig, apiKey: APIKey?) {
        queue.async { self.engine.start(config: config, apiKey: apiKey) }
    }

    public func ingest(_ stream: AudioStream, samples: [Float], time: TimeInterval) {
        queue.async { self.engine.ingest(stream, samples: samples, time: time) }
    }

    public func stop() {
        queue.async { self.engine.stop() }
    }

    /// Waits until everything queued so far has run (tests).
    public func drain() {
        queue.sync {}
    }
}

/// Loudness of the call stream over the last second, written from the capture thread.
public final class CallLevelMeter: @unchecked Sendable {
    private let lock = NSLock()
    private var lastDbfs: Double = -.infinity
    private var lastTime: TimeInterval = 0
    private let clock: @Sendable () -> TimeInterval

    public init(clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.clock = clock
    }

    public func record(_ samples: [Float]) {
        let db = AudioMath.rmsDbfs(samples)
        let now = clock()
        lock.lock()
        lastDbfs = db
        lastTime = now
        lock.unlock()
    }

    public func recentDbfs(now: TimeInterval) -> Float {
        lock.lock()
        defer { lock.unlock() }
        return now - lastTime > 1 ? -.infinity : Float(lastDbfs)
    }

    public func reset() {
        lock.lock()
        lastDbfs = -.infinity
        lastTime = 0
        lock.unlock()
    }
}
