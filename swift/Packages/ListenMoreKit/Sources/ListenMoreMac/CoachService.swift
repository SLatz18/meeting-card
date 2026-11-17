import AppKit
import ListenMoreCore

/// The coach as the app sees it: polls Core Audio running-state into the trigger, starts and stops
/// capture through `CoachRunner`, passes engine suggestions through `CuePolicy`, and flashes the
/// glow on the call app's display (else the card's). Off (the default) means no polling, no
/// capture and no network. Nothing outlives the live session: no transcripts, no per-call records.
@MainActor
public final class CoachService: CoachEngineDelegate {
    public enum State: Equatable {
        case off
        /// Enabled, waiting for a call.
        case idle
        case active(paused: Bool)
    }

    public let config: ListenMoreConfig
    public let glow: GlowOverlayController
    let monitor: CoachMonitor
    let runner: CoachRunner
    let engine: LocalCoachEngine
    let policy: CuePolicy
    private let ownBundleId: String?
    private var timer: Timer?
    public private(set) var anyApp: Bool
    public private(set) var allowlist: [String]?
    /// The display the card is on (glow fallback) and the card window to order the glow behind.
    public var fallbackScreen: () -> NSRect? = { nil }
    public var cardWindowNumber: () -> Int? = { nil }
    /// Display for a session's app; injectable for tests.
    var locateScreen: (String?, NSRect?) -> NSRect? = { CallDisplayLocator.screen(appKey: $0, fallback: $1) }
    /// The GPT layer switched itself off for this session (local cues continue).
    public private(set) var gptDisabled: GptErrorKind?
    /// Cues shown in the current session (a live counter for logs; reset at start, never kept).
    public private(set) var cuesShown = 0
    public var onChange: (() -> Void)?
    /// Mic or call-audio capture failed to start (usually a missing permission).
    public private(set) var captureProblem = false

    public init(config: ListenMoreConfig, glowStyle: GlowStyle, enabled: Bool, anyApp: Bool,
                allowlist: [String]? = nil, ownBundleId: String? = Bundle.main.bundleIdentifier,
                provider: AudioStateProvider = CoreAudioStateProvider(),
                capture: CoachCapture? = nil, transport: GptTransportFactory? = OpenAITransport(),
                readKey: @escaping () -> APIKey? = { try? KeychainStore().readKey() }) {
        self.config = config
        self.anyApp = anyApp
        self.allowlist = allowlist
        self.ownBundleId = ownBundleId
        glow = GlowOverlayController(style: glowStyle)
        engine = LocalCoachEngine(transport: transport)
        policy = CuePolicy(config: config.cues)
        let settings = TriggerSettings(config: config, anyApp: anyApp, ownPid: getpid(), ownBundleId: ownBundleId,
                                       allowlist: allowlist)
        monitor = CoachMonitor(provider: provider, trigger: CoachTrigger(settings: settings, enabled: enabled))
        let audio = capture ?? CoachAudioCapture(config: config)
        runner = CoachRunner(config: config, engine: engine, capture: audio, readKey: readKey)
        engine.delegate = self
        (audio as? CoachAudioCapture)?.onStatus = { [weak self] status in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    guard let self else { return }
                    switch status {
                    case .micFailed, .callFailed: self.captureProblem = true
                    case .running: self.captureProblem = false
                    case .idle: break
                    }
                    self.changed()
                }
            }
        }
        if enabled { startPolling() }
    }

    public var state: State {
        guard monitor.trigger.enabled else { return .off }
        guard let s = monitor.trigger.session else { return .idle }
        return .active(paused: s.paused)
    }

    /// The card chip: shown while pre-warmed or running; hidden ~30 s after call audio stops.
    public var indicator: CoachIndicator { monitor.trigger.indicator }

    public var isCapturing: Bool { runner.isCapturing }

    // MARK: controls

    public func setEnabled(_ on: Bool) {
        apply(monitor.trigger.setEnabled(on))
        on ? startPolling() : stopPolling()
        changed()
    }

    public func setAnyApp(_ on: Bool) {
        anyApp = on
        updateSettings()
    }

    /// The user's allowlist from Settings; nil restores the default call apps.
    public func setAllowlist(_ ids: [String]?) {
        allowlist = ids
        updateSettings()
    }

    private func updateSettings() {
        monitor.trigger.settings = TriggerSettings(config: config, anyApp: anyApp, ownPid: getpid(), ownBundleId: ownBundleId,
                                                   allowlist: allowlist)
        changed()
    }

    /// Manual Start (or Resume, if paused).
    public func start() { apply(monitor.trigger.manualStart(now: now)) }
    public func pause() { apply(monitor.trigger.setPaused(true)) }
    public func resume() { apply(monitor.trigger.setPaused(false)) }
    public func stop() { apply(monitor.trigger.manualStop()) }

    /// The chip's control: Pause while pre-warmed skips this call; Pause / Resume while running.
    public func chipControl() {
        switch indicator {
        case .hidden: break
        case .on:
            monitor.trigger.dismissPrewarm()
            changed()
        case .listening: pause()
        case .paused: resume()
        }
    }

    /// The user clicked Join on a card: a hint for when the call should end, never a start.
    public func joinHint(endsAt: Date) {
        monitor.trigger.joinHint(endsAt: now + endsAt.timeIntervalSinceNow, now: now)
        changed()
    }

    // MARK: polling

    var now: Double { ProcessInfo.processInfo.systemUptime }

    private func startPolling() {
        guard timer == nil else { return }
        let t = Timer(timeInterval: config.trigger.pollS, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    private func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func poll() {
        let before = indicator
        let actions = monitor.poll(now: now)
        apply(actions)
        if actions.isEmpty && indicator != before { changed() }
    }

    private func apply(_ actions: [TriggerAction]) {
        guard !actions.isEmpty else { return }
        for a in actions {
            switch a {
            case .start(let s):
                policy.reset()
                gptDisabled = nil
                cuesShown = 0
                Log.trigger.info("coach start, reason manual \(s.reason == .manual, privacy: .public)")
            case .stop(let reason):
                glow.hideAll()
                Log.trigger.info("coach stop, reason \(reason.rawValue, privacy: .public)")
            case .pause(let paused):
                if paused { glow.hideAll() }
                Log.trigger.info("coach paused \(paused, privacy: .public)")
            }
        }
        runner.apply(actions, session: monitor.trigger.session)
        changed()
    }

    private func changed() { onChange?() }

    // MARK: engine

    nonisolated public func engine(_ engine: CoachEngine, didSuggest cue: CueSuggestion) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.offer(cue) }
        }
    }

    nonisolated public func engine(_ engine: CoachEngine, gptDisabled reason: GptErrorKind) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.gptDisabled = reason
                Log.coach.info("gpt layer off, kind \(reason.rawValue, privacy: .public)")
                self.changed()
            }
        }
    }

    private func offer(_ s: CueSuggestion) {
        guard runner.isCapturing,
              let cue = policy.offer(s.type, t: s.t, onset: s.onset, source: s.source, confidence: s.confidence) else { return }
        cuesShown += 1
        let screen = locateScreen(monitor.trigger.session?.appKey, fallbackScreen())
        glow.flash(cue.color, on: screen, below: cardWindowNumber())
    }
}
