import Foundation

// MARK: seams (ListenMoreMac provides the real ones; tests provide fakes)

/// The user's microphone. `handler` receives mono Float32 at `sampleRate`, on any thread.
public protocol MicSource: AnyObject {
    func start(sampleRate: Int, handler: @escaping @Sendable ([Float]) -> Void) throws
    func stop()
    /// Muted closes the input device (no audio, the device released) and keeps the handler; unmuting
    /// reopens it. Muted before `start`, `start` opens nothing until unmuted. Call capture is
    /// unaffected. `stop()` clears it. Returns false when unmuting couldn't reopen the device.
    @discardableResult
    func setMuted(_ muted: Bool) -> Bool
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
    /// Live transcription text while capturing (content: RAM only, never logged).
    func coachSession(_ session: CoachSession, didCaption event: CaptionEvent)
    func coachSession(_ session: CoachSession, didMeter reading: CostReading)
}

public extension CoachSessionDelegate {
    func coachSessionDidChange(_ session: CoachSession) {}
    func coachSession(_ session: CoachSession, didShow cue: Cue) {}
    func coachSession(_ session: CoachSession, didReport problem: CoachSession.Problem) {}
    func coachSession(_ session: CoachSession, didCaption event: CaptionEvent) {}
    func coachSession(_ session: CoachSession, didMeter reading: CostReading) {}
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
        /// The call's audio is silent (no buffers, or buffers of zeros): see `AudioFlowMeter`.
        case callAudioSilent(SilenceKind)
        /// The transcriber refused `input_audio_buffer.clear` after Mute; nothing stopped.
        case transcriberClearRejected
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
    /// The user's own Mute (`setMicMuted`): the coach isn't listening to their mic. Off at every session start.
    public private(set) var micMuted = false

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
    /// The mic's own switch inside `gate`: closed by Mute, so a buffer the device was already
    /// delivering when it stopped is dropped too.
    private let micGate = AudioGate()
    private var fallback = CaptureFallbackPolicy()
    private let callLevel = CallLevelMeter()
    private var captionFinal = 0
    private var captionPartial = 0
    private var captionWindowStart: TimeInterval = 0
    private var detectionThrottle = DetectionLogThrottle()
    /// What the host knows about the permissions a call needs; shown beside each detection check.
    public var permissionSummary: () -> PermissionSummary = { .unknown }
    private let callFlow = AudioFlowMeter(source: .call, watchesSilence: true)
    private let micFlow = AudioFlowMeter(source: .mic, watchesSilence: false)
    private var shownAt: [CueType: TimeInterval] = [:]
    /// Wall-clock time this session's capture first started, and how long after it the running engine
    /// started. Each engine counts from 0 (Pause and the call app's mute restart it), so the session's
    /// cue policy compares engine times shifted by `engineOffset`: cooldowns carry across a restart.
    private var sessionCaptureStart: TimeInterval?
    private var engineOffset: TimeInterval = 0
    /// Which engine start is running (counted here and on the engine queue in the same order): a
    /// suggestion the previous engine raised but that reaches the main thread after a restart carries
    /// the old number and is dropped.
    private var engineGeneration = 0
    private var timer: Timer?
    private var callTask: Task<Void, Never>?
    private var bridge: EngineDelegateBridge?
    /// The mic device is closed (`MicSource.setMuted(true)`) while capture runs: the session's app
    /// reported its call ended (see `syncMic`).
    public private(set) var micDeviceOff = false
    /// The session's app, as the diagnostics file names it (the app that started it, or the first one captured).
    private var loggedApp: LogToken?
    /// Why capture is held now (for the pause line that releases it).
    private var heldCause: HoldCause = .none

    private static func holdCause(_ session: TriggerSession?) -> HoldCause {
        guard let session else { return .none }
        return session.paused ? .user : session.muted ? .callMuted : .none
    }

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
        bridge.queue = self.engine
        self.engine.delegate = bridge
        bridge.session = self
    }

    /// Runs after each poll (the host re-resolves the call's window here, as windows change).
    public var onTick: (() -> Void)?

    /// The trigger's indicator, with Listening shown as Mic off while the user is muted. Pause and the
    /// call app's mute hold all capture, so they show over it.
    public var indicator: CoachIndicator {
        let i = trigger.indicator
        return i == .listening && micMuted ? .micOff : i
    }
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

    /// The app is quitting: the session ends with reason `quit`, then capture stops.
    public func quit() {
        stopPolling()
        apply(trigger.quit())
        stopCapture()
    }

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

    /// Mute: the coach stops listening to the user's mic and only that. The mic engine is stopped
    /// (the device is released and its voice processing ends), its gate closes, and the engine drops
    /// what it held of the user's speech, so no mic audio reaches the engine or OpenAI and no "me"
    /// text is produced. Call capture, the other side's captions and the cues that need only the
    /// other side keep going. It lasts until unmuted or the session ends (a new session starts
    /// unmuted). Pause and the call app's mute hold all capture on top of it and leave it as it was:
    /// resuming from either keeps the mic off. Nothing to mute without a session. Never touches the
    /// call app.
    public func setMicMuted(_ muted: Bool) {
        guard trigger.session != nil, muted != micMuted else { return }
        micMuted = muted
        CoachLog.record(.micMuted(muted))
        if isCapturing {
            if muted {
                syncMic()
                engine.setMicMuted(true)
            } else {
                engine.setMicMuted(false)
                syncMic()
            }
        }
        changed()
    }

    /// The one place Mute reaches the mic device: it stops and restarts capture through `MicSource`.
    /// A host mic with its own mute API (the ducking work owns `MicCapture`) swaps in here alone.
    /// Through `syncMic`, for Mute and call end alike: the mic stays started with the session's
    /// handler, and only its gate and `MicSource.setMuted` change. Off pauses the gate first, so a
    /// buffer the device was already delivering is dropped; on resumes the same gate for that handler.
    private func setMicDevice(on: Bool) {
        if on {
            micGate.resume()
            if !mic.setMuted(false) {
                micGate.pause()
                captureProblem = true
                delegate?.coachSession(self, didReport: .micUnavailable)
            }
        } else {
            micGate.pause()
            mic.setMuted(true)
        }
    }

    /// Pause while pre-warmed (indicator `.on`): skip this call. Nothing starts for the call that is
    /// starting now; the next call starts normally.
    public func skipThisCall() {
        trigger.dismissPrewarm()
        changed()
    }

    /// Stop: the coach is off for the rest of this call. A running session stops and its app stays
    /// suppressed until its call audio ends; a pending Join hint is dropped, so nothing pre-warms
    /// again for this call. The next call starts normally.
    public func stopForThisCall() {
        apply(trigger.manualStop())
        trigger.dismissPrewarm()
        changed()
    }

    /// One control for the indicator: skip while pre-warmed, Pause while listening or muted, Resume
    /// while paused (still held if the call app is muted).
    public func toggleFromIndicator() {
        switch indicator {
        case .hidden: break
        case .on: skipThisCall()
        case .listening, .muted, .micOff: setPaused(true)
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
        logDetection(actions)
        apply(actions)
        // A manual session adopting the call app changes what to capture without an action.
        let captureChanged = actions.isEmpty && syncCapture()
        let micChanged = syncMic()
        if actions.isEmpty && (captureChanged || micChanged || indicator != before) { changed() }
        checkCallFallback()
        logAudioFlow()
        onTick?()
    }

    /// One detection check, logged when what was seen or decided changes, else once per ten seconds.
    private func logDetection(_ actions: [TriggerAction]) {
        guard let snapshot = signal.detectionSnapshot() else { return }
        let now = wallClock()
        let started = actions.contains { if case .start = $0 { return true } else { return false } }
        let check = DetectionDiagnostics.evaluate(snapshot: snapshot, settings: trigger.settings, enabled: trigger.enabled,
                                                  inSession: trigger.session != nil, suppressed: trigger.suppressed,
                                                  startTimers: trigger.startTimers(now: now), started: started,
                                                  permission: permissionSummary())
        if detectionThrottle.shouldLog(check, now: now) { CoachLog.record(.detectCheck(check)) }
    }

    /// Flow lines every ten seconds while capturing, and a note when the call's audio goes silent.
    private func logAudioFlow() {
        guard isCapturing else { return }
        let now = wallClock()
        if now - captionWindowStart >= AudioFlowMeter.interval { logCaptionsReceived(now: now) }
        for event in callFlow.tick(now: now) + micFlow.tick(now: now) {
            CoachLog.record(event)
            if case .callAudioSilent(_, _, let kind, _) = event {
                delegate?.coachSession(self, didReport: .callAudioSilent(kind))
            }
        }
    }

    /// Caption events the host got in the last window: counts only, never the text.
    private func logCaptionsReceived(now: TimeInterval) {
        CoachLog.record(.captionsReceived(seconds: Int((now - captionWindowStart).rounded()), final: captionFinal, partial: captionPartial))
        captionFinal = 0
        captionPartial = 0
        captionWindowStart = now
    }

    private func apply(_ actions: [TriggerAction]) {
        guard !actions.isEmpty else { return }
        for a in actions {
            switch a {
            case .start(let started):
                let app = LogToken.bundleIdOrNil(started.appKey)
                loggedApp = app
                if started.reason == .audio { CoachLog.record(.callDetected(bundleId: app)) }
                heldCause = Self.holdCause(started)
                CoachLog.record(.sessionStarted(reason: started.reason, bundleId: app, held: started.held, cause: heldCause))
                // A new session never inherits the previous one's engine (or OpenAI sessions).
                stopCapture()
                cuePolicy.reset()
                shownAt.removeAll()
                sessionCaptureStart = nil
                engineOffset = 0
                gptStopped = nil
                judgeStopped = nil
                cuesShown = 0
                captureProblem = false
                micMuted = false
            case .stop(let reason):
                CoachLog.record(.callEnded(bundleId: loggedApp, reason: reason))
                CoachLog.record(.sessionStopped(reason: reason))
                loggedApp = nil
                renderer.clear()
                micMuted = false
            case .pause(let paused):
                if paused { heldCause = Self.holdCause(trigger.session) }
                CoachLog.record(.sessionPaused(paused, cause: heldCause))
                if !paused { heldCause = .none }
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
        if loggedApp == nil, bundleIds.count == 1 { loggedApp = LogToken.bundleId(bundleIds[0]) }
        capturingBundleIds = bundleIds
        captureStage = stage
        let engine = engine
        let gate = gate
        if isNewSession {
            fallback.reset()
            callLevel.reset()
            captionFinal = 0
            captionPartial = 0
            captionWindowStart = wallClock()
            callFlow.start(now: wallClock())
            micFlow.start(now: wallClock())
            let key: APIKey?
            var availability = KeyAvailability.absent
            if (keys as? KeyGateStateProviding)?.gateState == .rejected {
                key = nil
                availability = .rejected
            } else {
                do {
                    key = try keys.readKey()
                    availability = key == nil ? .absent : .present
                    CoachLog.record(.keyRead(key == nil ? .absent : .present, status: nil, at: .call))
                } catch {
                    key = nil
                    CoachLog.record(.keyRead(.unreadable, status: CoachLog.status(of: error), at: .call))
                    delegate?.coachSession(self, didReport: .keyUnreadable)
                }
            }
            gateGeneration = gate.openNew()
            let now = wallClock()
            let start = sessionCaptureStart ?? now
            sessionCaptureStart = start
            engineOffset = now - start
            engineGeneration += 1
            engine.start(config: config, apiKey: key, keyAvailability: availability)
            // Muted before it starts (the user's Mute or a pending call end), so the device never
            // opens even briefly; the gate stays closed until `setMicDevice(on: true)` reopens it.
            micDeviceOff = micShouldBeOff
            if micMuted { engine.setMicMuted(true) }
            if micDeviceOff { mic.setMuted(true) }
            startMic()
            if micDeviceOff { micGate.pause() }
        }
        let level = callLevel
        let flow = callFlow
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
                    flow.record(samples)
                    engine.ingest(.call, samples: samples, time: 0)
                }
                if !gate.admits(gen) { await call.stop() }
            } catch {
                guard let self, gate.admits(gen) else { return }
                self.captureProblem = true
                if !(error is LoggedFailure) {
                    let failure = CoachLog.domainAndCode(error)
                    CoachLog.record(.callAudioFailed(stage: stage, step: nil, domain: failure.domain, code: failure.code))
                }
                self.delegate?.coachSession(self, didReport: .callCaptureFailed(stage: stage))
                self.changed()
            }
        }
    }

    private func startMic() {
        let engine = engine
        let gate = gate
        let gen = gateGeneration
        let micGate = micGate
        let micGen = micGate.openNew()
        let flow = micFlow
        do {
            try mic.start(sampleRate: config.audio.sampleRate) { samples in
                if gate.admits(gen) && micGate.admits(micGen) {
                    flow.record(samples)
                    engine.ingest(.mic, samples: samples, time: 0)
                }
            }
        } catch {
            micGate.close()
            captureProblem = true
            delegate?.coachSession(self, didReport: .micUnavailable)
        }
    }

    /// The device is closed while capture runs for the user's Mute or a call-end report.
    private var micShouldBeOff: Bool { micMuted || trigger.callEndPending }

    /// A call-end report closes the mic device at once (and with it voice processing's ducking and
    /// any Bluetooth headset hold), ahead of the session's own end; the engine and call capture keep
    /// running, so a report that flips back only reopens the device, and never while the user has
    /// Mute on. The mic stays started with the session's handler throughout. Without a report for the
    /// session's app, the mic runs until the session ends.
    @discardableResult
    private func syncMic() -> Bool {
        guard isCapturing, micDeviceOff != micShouldBeOff else { return false }
        micDeviceOff = micShouldBeOff
        setMicDevice(on: !micDeviceOff)
        return true
    }

    private func stopCapture() {
        guard !capturingBundleIds.isEmpty else { return }
        // Closed first and synchronously: not one buffer reaches the engine (or OpenAI) after this,
        // even while call capture is still stopping asynchronously.
        gate.close()
        let now = wallClock()
        for event in callFlow.finish(now: now) + micFlow.finish(now: now) { CoachLog.record(event) }
        if captionFinal + captionPartial > 0 { logCaptionsReceived(now: now) }
        capturingBundleIds = []
        captureStage = .parentApps
        let previous = callTask
        previous?.cancel()
        mic.stop()
        micDeviceOff = false
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
            CoachLog.record(.fallbackEngaged(stage: next))
            delegate?.coachSession(self, didReport: .fallbackEngaged(stage: next))
            startCapture(bundleIds: capturingBundleIds, stage: next)
        }
    }

    fileprivate func show(_ s: CueSuggestion, generation: Int) {
        let offset = engineOffset
        guard isCapturing, generation == engineGeneration,
              var cue = cuePolicy.offer(s.type, t: s.t + offset, onset: s.onset + offset, source: s.source,
                                        confidence: s.confidence, level: s.level) else { return }
        cue.t = s.t
        cue.onset = s.onset
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

    fileprivate func caption(_ event: CaptionEvent) {
        guard isCapturing else { return }
        switch event {
        case .final: captionFinal += 1
        case .partial: captionPartial += 1
        }
        delegate?.coachSession(self, didCaption: event)
    }

    fileprivate func clearRejected() {
        guard isCapturing else { return }
        delegate?.coachSession(self, didReport: .transcriberClearRejected)
    }

    fileprivate func meter(_ reading: CostReading) {
        guard isCapturing else { return }
        delegate?.coachSession(self, didMeter: reading)
    }

    /// Test hook: deliver caption text as if the engine produced it.
    func deliverCaptionForTesting(_ event: CaptionEvent) {
        caption(event)
    }

    private func changed() {
        delegate?.coachSessionDidChange(self)
    }

    /// Test hook: wait until every queued engine call has run.
    func drainEngineForTesting() {
        engine.drain()
    }

    /// Test hook: deliver a suggestion as if the running engine produced it.
    func deliverForTesting(_ s: CueSuggestion) {
        show(s, generation: engineGeneration)
    }

    /// Test hook: deliver a suggestion as if the engine of start number `generation` produced it.
    func deliverForTesting(_ s: CueSuggestion, generation: Int) {
        show(s, generation: generation)
    }

    /// Test hook: the running engine's start number.
    var engineGenerationForTesting: Int { engineGeneration }
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

    /// Closes without retiring the generation, so `resume()` admits the same handler again.
    func pause() {
        lock.lock()
        open = false
        lock.unlock()
    }

    func resume() {
        lock.lock()
        open = true
        lock.unlock()
    }
}

/// Forwards engine callbacks (from the engine queue) to the session on the main thread.
final class EngineDelegateBridge: CoachEngineDelegate, @unchecked Sendable {
    @MainActor weak var session: CoachSession?
    weak var queue: EngineQueue?

    /// Called on the engine queue, so `queue.generation` is the engine that raised the suggestion.
    func engine(_ engine: CoachEngine, didSuggest cue: CueSuggestion) {
        let generation = queue?.generation ?? 0
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.session?.show(cue, generation: generation) }
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

    func engine(_ engine: CoachEngine, caption: CaptionEvent) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.session?.caption(caption) }
        }
    }

    func engine(_ engine: CoachEngine, meter: CostReading) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.session?.meter(meter) }
        }
    }

    func engine(_ engine: CoachEngine, clearRejected speaker: Speaker) {
        DispatchQueue.main.async {
            MainActor.assumeIsolated { self.session?.clearRejected() }
        }
    }
}

/// Serializes every call into the engine on one queue, so `CoachEngine` implementations need no locks.
public final class EngineQueue: @unchecked Sendable {
    private let engine: CoachEngine
    private let queue = DispatchQueue(label: "com.listenmore.engine", qos: .userInteractive)
    private let generationLock = NSLock()
    private var startCount = 0

    /// How many times the engine has been started, counted on the queue as each start runs.
    public var generation: Int { generationLock.withLock { startCount } }

    public init(_ engine: CoachEngine) {
        self.engine = engine
    }

    public var delegate: CoachEngineDelegate? {
        get { queue.sync { engine.delegate } }
        set { queue.sync { engine.delegate = newValue } }
    }

    public func start(config: ListenMoreConfig, apiKey: APIKey?, keyAvailability: KeyAvailability) {
        queue.async {
            self.generationLock.withLock { self.startCount += 1 }
            self.engine.start(config: config, apiKey: apiKey, keyAvailability: keyAvailability)
        }
    }

    public func ingest(_ stream: AudioStream, samples: [Float], time: TimeInterval) {
        queue.async { self.engine.ingest(stream, samples: samples, time: time) }
    }

    public func setMicMuted(_ muted: Bool) {
        queue.async { self.engine.setMicMuted(muted) }
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
