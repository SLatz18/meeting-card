import AppKit
import AVFoundation
import CoreGraphics
import ListenMoreCore

/// The coach for a host app, wired with the real parts: Core Audio running-state drives the trigger
/// (`AudioActivitySignal`), `MicCapture` + `CallCapture` feed `LocalCoachEngine`, and cues glow on the
/// call app's display (else the host's fallback display), ordered behind the host's window. Styling,
/// the key store (and with it the Keychain service name) and self-exclusion are the host's. Off means
/// no polling, no capture and no network. Nothing outlives the live session.
@MainActor
public final class CoachService: CoachSessionDelegate {
    public enum State: Equatable {
        case off
        /// Enabled, waiting for a call.
        case idle
        case active(paused: Bool)
    }

    public let config: ListenMoreConfig
    public let glow: GlowOverlayController
    public let session: CoachSession
    /// The session's mic, for a host's diagnostics; the session alone starts and stops it.
    public let mic: MicSource
    public let ownBundleId: String?
    public let excludedBundleIds: [String]
    public private(set) var anyApp: Bool
    public private(set) var allowlist: [String]?
    /// The display the host's window is on (glow fallback) and the window to order the glow behind.
    public var fallbackScreen: () -> NSRect? = { nil }
    public var hostWindowNumber: () -> Int? = { nil }
    /// Display for a session's app: the one place the call's window is chosen, for the glow and (through
    /// `glowScreen`) the host's coach card. Injectable for tests.
    var locateScreen: (String?, NSRect?) -> NSRect? = { CallDisplayLocator.screen(appKey: $0, fallback: $1) }
    public var onChange: (() -> Void)?
    /// A cue was shown (after the glow started).
    public var onCue: ((Cue) -> Void)?
    /// The display the last cue's glow went to: `locateScreen`'s choice of the call's window, or the
    /// fallback display when it found none. nil until a cue and after the session ends. Reading it
    /// reads nothing; only the glow's own placement does.
    public private(set) var glowScreen: NSRect?
    /// A coach session (one call) started or ended.
    public var onCallStart: (() -> Void)?
    public var onCallEnd: (() -> Void)?
    /// Live transcription text and the per-call cost meter (content: RAM only, never logged).
    public var onCaption: ((CaptionEvent) -> Void)?
    public var onMeter: ((CostReading) -> Void)?
    private var seenSessionStart: Double?

    /// - Parameters:
    ///   - keys: where the OpenAI key comes from, e.g. `KeychainStore(service: "<host's service>")`.
    ///   - ownBundleId / excludedBundleIds: never trigger on these (plus the config's `trigger.exclude_bundle_ids`).
    ///   - callState: optional app-level call state; an `ended` report stops in `trigger.ended_stop_after_s`
    ///     instead of the Core Audio `trigger.stop_after_s`.
    public init(config: ListenMoreConfig, glowStyle: GlowStyle, enabled: Bool, anyApp: Bool,
                allowlist: [String]? = nil,
                ownBundleId: String? = Bundle.main.bundleIdentifier, excludedBundleIds: [String] = [],
                keys: APIKeyProvider = KeychainStore(),
                provider: AudioStateProvider = CoreAudioStateProvider(),
                callState: CallStateProvider? = nil,
                mic: MicSource = MicCapture(), call: CallSource? = nil,
                engine: CoachEngine = LocalCoachEngine(transports: .urlSession()),
                glow: GlowOverlayController? = nil) {
        self.config = config
        self.mic = mic
        self.anyApp = anyApp
        self.allowlist = allowlist
        self.ownBundleId = ownBundleId
        self.excludedBundleIds = excludedBundleIds
        let glow = glow ?? GlowOverlayController(style: glowStyle)
        self.glow = glow
        let settings = TriggerSettings(config: config, anyApp: anyApp, ownPid: getpid(), ownBundleId: ownBundleId,
                                       excludedBundleIds: excludedBundleIds, allowlist: allowlist)
        session = CoachSession(config: config, engine: engine, mic: mic, call: call ?? CallCapture(config: config),
                               signal: AudioActivitySignal(provider: provider), keys: keys, renderer: glow,
                               settings: settings, enabled: enabled, callState: callState)
        session.delegate = self
        session.permissionSummary = { Self.permissionSummary() }
        glow.placement = { [weak self] in
            guard let self else { return .init(screen: nil) }
            let screen = self.locateScreen(self.session.session?.appKey, self.fallbackScreen())
            self.glowScreen = screen
            return .init(screen: screen, belowWindow: self.hostWindowNumber())
        }
        if enabled { session.startPolling() }
    }

    public var state: State {
        guard session.isEnabled else { return .off }
        guard let s = session.session else { return .idle }
        return .active(paused: s.paused)
    }

    /// On (pre-warmed), Listening or Paused; hidden ~`trigger.stop_after_s` after call audio stops.
    public var indicator: CoachIndicator { session.indicator }
    public var isCapturing: Bool { session.isCapturing }
    /// The GPT layer stopped itself this session (local cues continue).
    public var gptStopped: GptStopReason? { session.gptStopped }
    /// Judging stopped this session after repeated provider failures, and why (no key text, ever).
    public var judgeStopped: JudgeFailure? { session.judgeStopped }
    /// Cues shown in the current session (a live counter; reset at start, never kept).
    public var cuesShown: Int { session.cuesShown }
    /// Mic or call-audio capture failed to start (usually a missing permission).
    public var captureProblem: Bool { session.captureProblem }

    // MARK: controls

    public func setEnabled(_ on: Bool) {
        session.setEnabled(on)
        on ? session.startPolling() : session.stopPolling()
    }

    public func setAnyApp(_ on: Bool) {
        anyApp = on
        updateSettings()
    }

    /// The user's allowlist; nil restores the config's call apps.
    public func setAllowlist(_ ids: [String]?) {
        allowlist = ids
        updateSettings()
    }

    private func updateSettings() {
        session.update(settings: TriggerSettings(config: config, anyApp: anyApp, ownPid: getpid(), ownBundleId: ownBundleId,
                                                 excludedBundleIds: excludedBundleIds, allowlist: allowlist))
    }

    /// Manual Start (or Resume, if paused).
    public func start() { session.startManual() }
    public func pause() { session.setPaused(true) }
    public func resume() { session.setPaused(false) }
    public func stop() { session.stopManual() }
    /// The app is quitting: the session ends with reason `quit`.
    public func quit() { session.quit() }
    /// The coach's own Mute: it stops listening to the user's mic only (`CoachSession.setMicMuted`).
    public var micMuted: Bool { session.micMuted }
    public func setMicMuted(_ muted: Bool) { session.setMicMuted(muted) }
    /// Pause while pre-warmed: skip this call.
    public func skipThisCall() { session.skipThisCall() }
    /// Off for the rest of this call, pre-warmed or in a session.
    public func stopForThisCall() { session.stopForThisCall() }

    /// The indicator's one control: skip this call while pre-warmed, Pause while listening, Resume while paused.
    public func chipControl() { session.toggleFromIndicator() }

    /// The user joined a calendar event: a hint for when the call should end, never a start.
    public func joinHint(endsAt: Date) { session.joinHint(endsAt: endsAt) }

    func poll() { session.tick() }

    // MARK: CoachSessionDelegate

    public func coachSessionDidChange(_ session: CoachSession) {
        if session.session == nil { glowScreen = nil }
        let start = session.session?.startedAt
        if start != seenSessionStart {
            if seenSessionStart != nil { onCallEnd?() }
            seenSessionStart = start
            if start != nil {
                Self.logPermissions()
                onCallStart?()
            }
        }
        onChange?()
    }

    /// Granted when both the mic and screen recording are; unknown while the mic's answer is still pending.
    static func permissionSummary() -> PermissionSummary {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: return CGPreflightScreenCaptureAccess() ? .granted : .notGranted
        case .denied, .restricted: return .notGranted
        case .notDetermined: return .unknown
        @unknown default: return .unknown
        }
    }

    /// What the OS says about the two permissions a call needs, when a session starts. There is no public
    /// check for System Audio Recording; a refusal shows up as a call-audio failure code instead.
    static func logPermissions() {
        let mic: PermissionState
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: mic = .granted
        case .denied: mic = .denied
        case .restricted: mic = .restricted
        case .notDetermined: mic = .notDetermined
        @unknown default: mic = .notDetermined
        }
        CoachLog.record(.permission(.microphone, mic))
        CoachLog.record(.permission(.screenRecording, CGPreflightScreenCaptureAccess() ? .granted : .notGranted))
    }

    public func coachSession(_ session: CoachSession, didShow cue: Cue) { onCue?(cue) }

    public func coachSession(_ session: CoachSession, didCaption event: CaptionEvent) { onCaption?(event) }

    public func coachSession(_ session: CoachSession, didMeter reading: CostReading) { onMeter?(reading) }

    public func coachSession(_ session: CoachSession, didReport problem: CoachSession.Problem) {
        switch problem {
        case .micUnavailable: Log.coach.error("mic unavailable")
        case .callCaptureFailed(let stage): Log.coach.error("call capture failed, stage \(stage.rawValue, privacy: .public)")
        case .keyUnreadable: Log.coach.error("key unreadable")
        case .fallbackEngaged(let stage): Log.coach.info("capture fallback, stage \(stage.rawValue, privacy: .public)")
        // A refused System Audio Recording permission delivers silence: put the permission states beside it.
        case .callAudioSilent(let kind):
            Log.coach.info("call audio silent, kind \(kind.rawValue, privacy: .public)")
            Self.logPermissions()
        // The event type only: no audio, no text, nothing from the server's reply.
        case .transcriberClearRejected: Log.coach.info("realtime input_audio_buffer.clear rejected")
        }
    }
}
