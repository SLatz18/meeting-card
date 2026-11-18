import Foundation

// Auto-on trigger: the coach starts when one app (counting its helper processes) has audio input
// AND output running continuously for `startAfterS`, and stops when either stays off for
// `stopAfterS`. Detection reads only Core Audio "is running" state; no audio is captured to detect a
// call. Any other per-app "a call is live" signal (e.g. window titles) can drive the same machine
// through `tick(liveApps:inputRunning:now:)`. An optional app-level call state (`CallStateProvider`)
// can end a session sooner: when it reports the session's call `ended`, the stop takes
// `endedStopAfterS` instead of `stopAfterS`. Without a report, Core Audio decides.

/// What an app-level provider (e.g. a call app's accessibility state) knows about a call.
public enum CallState: String, Equatable, Sendable {
    case started
    /// Ended in the app, even if it still holds its audio devices.
    case ended
    /// Still in the call with the mic muted in the app.
    case muted
}

/// Optional app-level call state per app key (lowercased bundle ID, as `TriggerSettings.appKey`
/// makes them). Apps without an entry fall back to Core Audio. `ended` stops the session after
/// `endedStopAfterS` and keeps that app from auto-starting while it stays ended; `muted` holds the
/// session's capture (the pause path) until the app reports anything else. `started` and `muted`
/// never start a session or hold one open, so a stale provider can't keep the coach listening.
public protocol CallStateProvider: AnyObject {
    func callStates() -> [String: CallState]
}

/// Core Audio process object state (macOS 14.4+: kAudioProcessPropertyIsRunningInput/Output).
public struct AudioProcessState: Equatable, Sendable {
    public var pid: Int32
    public var bundleId: String?
    /// Nearest ancestor with a bundle ID, for helper processes Core Audio reports without one.
    public var owningBundleId: String?
    public var isRunningInput: Bool
    public var isRunningOutput: Bool

    public init(pid: Int32, bundleId: String?, owningBundleId: String? = nil, isRunningInput: Bool, isRunningOutput: Bool) {
        self.pid = pid
        self.bundleId = bundleId
        self.owningBundleId = owningBundleId
        self.isRunningInput = isRunningInput
        self.isRunningOutput = isRunningOutput
    }
}

public struct AudioStateSnapshot: Equatable, Sendable {
    /// kAudioDevicePropertyDeviceIsRunningSomewhere on the default input device.
    public var defaultInputRunning: Bool
    public var processes: [AudioProcessState]

    public init(defaultInputRunning: Bool, processes: [AudioProcessState]) {
        self.defaultInputRunning = defaultInputRunning
        self.processes = processes
    }
}

/// Source of audio-running state. The Core Audio implementation lives in ListenMoreMac; tests use a fake.
public protocol AudioStateProvider: AnyObject {
    func snapshot() -> AudioStateSnapshot
}

public struct TriggerSettings: Equatable, Sendable {
    /// Bundle IDs of call apps (helpers group with them by dotted prefix).
    public var allowlist: [String]
    /// "Coach any app" option: any app with input + output counts, not just the allowlist.
    public var anyApp: Bool
    /// Never trigger on these (the host app itself, other coach apps), in any mode.
    public var excludedBundleIds: [String]
    public var ownPid: Int32
    public var startAfterS: Double
    public var stopAfterS: Double
    /// Stop delay once a `CallStateProvider` reports the session's call ended.
    public var endedStopAfterS: Double

    public init(allowlist: [String], anyApp: Bool = false, excludedBundleIds: [String], ownPid: Int32,
                startAfterS: Double = 3, stopAfterS: Double = 30, endedStopAfterS: Double = 3) {
        self.allowlist = allowlist
        self.anyApp = anyApp
        self.excludedBundleIds = excludedBundleIds
        self.ownPid = ownPid
        self.startAfterS = startAfterS
        self.stopAfterS = stopAfterS
        self.endedStopAfterS = endedStopAfterS
    }

    /// `allowlist` is the user's edited list; nil means the config's call apps. Self-exclusion is the
    /// host's own PID and bundle ID, `excludedBundleIds` from the host, and the config's list.
    public init(config: ListenMoreConfig, anyApp: Bool, ownPid: Int32, ownBundleId: String?,
                excludedBundleIds: [String] = [], allowlist: [String]? = nil) {
        self.init(allowlist: allowlist ?? config.captureTargets.map(\.bundleId), anyApp: anyApp,
                  excludedBundleIds: config.trigger.excludeBundleIds + excludedBundleIds + [ownBundleId].compactMap { $0 },
                  ownPid: ownPid, startAfterS: config.trigger.startAfterS, stopAfterS: config.trigger.stopAfterS,
                  endedStopAfterS: config.trigger.endedStopAfterS)
    }

    /// The app a process belongs to for triggering, or nil if it can never trigger.
    /// Allowlisted apps group by dotted prefix (`com.google.Chrome.helper` -> `com.google.chrome`);
    /// with `anyApp`, other apps group by stripping a `.helper*` suffix. Lowercased.
    public func appKey(for p: AudioProcessState) -> String? {
        guard p.pid != ownPid else { return nil }
        let ids = [p.bundleId, p.owningBundleId].compactMap { $0 }.filter { !$0.isEmpty }
        guard !ids.isEmpty else { return nil }
        for id in ids where excludedBundleIds.contains(where: { BundleIds.belongs(id, to: $0) }) {
            return nil
        }
        for id in ids {
            if let a = allowlist.first(where: { BundleIds.belongs(id, to: $0) }) { return a.lowercased() }
        }
        guard anyApp, let id = p.owningBundleId ?? p.bundleId else { return nil }
        return BundleIds.stripHelperSuffix(id)
    }

    public struct AppAudio: Equatable, Sendable {
        public var input = false
        public var output = false
        public var both: Bool { input && output }
    }

    /// Input/output running per app key.
    public func group(_ s: AudioStateSnapshot) -> [String: AppAudio] {
        var out: [String: AppAudio] = [:]
        for p in s.processes {
            guard let key = appKey(for: p) else { continue }
            var a = out[key] ?? AppAudio()
            a.input = a.input || p.isRunningInput
            a.output = a.output || p.isRunningOutput
            out[key] = a
        }
        return out
    }
}

public enum CoachStartReason: Equatable, Sendable {
    /// An app had input + output running for `startAfterS`.
    case audio
    case manual
}

public enum CoachStopReason: String, Equatable, Sendable {
    /// The session's app had input or output off for `stopAfterS`.
    case audioEnded
    /// A `CallStateProvider` reported the session's call ended, `endedStopAfterS` ago.
    case callEnded
    /// The calendar event the user joined ended.
    case eventEnded
    case manual
    /// The app is quitting.
    case quit
    /// The opt-in setting was switched off.
    case disabled
}

/// One coaching session as the trigger sees it (no audio, no text).
public struct TriggerSession: Equatable, Sendable {
    public var reason: CoachStartReason
    /// The app being coached (lowercased bundle ID); nil for a manual start until an app qualifies.
    public var appKey: String?
    public var startedAt: Double
    /// Calendar end of the event joined from a card (a hint, never a requirement).
    public var endsAt: Double?
    /// Paused by the user.
    public var paused = false
    /// The session's app reports its mic muted: capture is held like a pause, without the user's pause.
    public var muted = false
    /// No capture: paused by the user or muted in the call app.
    public var held: Bool { paused || muted }
}

/// What a host shows for the coach (MeetingCard: the chip on the card; the standalone app: the menu
/// bar). Hidden unless the coach is pre-warmed or running; a session ends (and the indicator hides)
/// `stopAfterS` after the call app's input or output goes off.
public enum CoachIndicator: String, Equatable, Sendable {
    case hidden
    /// Enabled and pre-warmed, not streaming yet.
    case on
    /// Session running: audio is being analysed.
    case listening
    /// Session paused by the user: no capture, no streams.
    case paused
    /// Session held because the call app reports the mic muted: no capture, no streams.
    case muted
    /// Session listening to the call with the user's mic off (the coach's own Mute,
    /// `CoachSession.setMicMuted`): call audio is still analysed, nothing comes from the mic.
    /// `CoachSession` reports it; the trigger never does.
    case micOff
}

public enum TriggerAction: Equatable, Sendable {
    case start(TriggerSession)
    case stop(CoachStopReason)
    /// Capture held (true) or resumed (false): the user's pause or the call app's mute.
    case pause(Bool)
}

/// The session state machine. Pure: feed it snapshots and times, act on the returned actions.
public struct CoachTrigger: Sendable {
    public var settings: TriggerSettings
    /// The opt-in setting. Off (the default) means no session ever starts.
    public private(set) var enabled: Bool
    public private(set) var session: TriggerSession?
    private var qualifyingSince: [String: Double] = [:]
    /// Apps that must stop qualifying before they may auto-start again (after a manual or
    /// event-end stop), so a still-running call does not restart the coach 3 s later.
    public private(set) var suppressed: Set<String> = []
    private var offSince: Double?
    private var endedSince: Double?
    private var hintEndsAt: Double?
    private var lastLive: Set<String> = []

    public init(settings: TriggerSettings, enabled: Bool = false) {
        self.settings = settings
        self.enabled = enabled
    }

    public var isActive: Bool { session != nil }
    public var isCapturing: Bool { session.map { !$0.held } ?? false }
    /// Seconds each app has had its input and output running together, for the diagnostics.
    public func startTimers(now: Double) -> [String: Double] {
        qualifyingSince.mapValues { max(0, now - $0) }
    }

    /// The session's app reports its call ended; the session itself ends `endedStopAfterS` later.
    public var callEndPending: Bool { session != nil && endedSince != nil }

    /// Pre-warmed: enabled, no session yet, but a call looks imminent (Join was clicked on a card
    /// for an event that hasn't ended, or a call app is inside the start debounce).
    public var isPrewarmed: Bool {
        guard enabled, session == nil else { return false }
        return hintEndsAt != nil || qualifyingSince.keys.contains { !suppressed.contains($0) }
    }

    public var indicator: CoachIndicator {
        if let s = session { return s.paused ? .paused : s.muted ? .muted : .listening }
        return isPrewarmed ? .on : .hidden
    }

    public mutating func setEnabled(_ on: Bool) -> [TriggerAction] {
        enabled = on
        guard !on, session != nil else { return [] }
        return end(.disabled)
    }

    /// Feed one Core Audio poll. Returns at most one start or stop.
    public mutating func tick(_ snap: AudioStateSnapshot, now: Double, callStates: [String: CallState] = [:]) -> [TriggerAction] {
        let live = Set(settings.group(snap).filter { $0.value.both }.keys)
        return tick(liveApps: live, inputRunning: snap.defaultInputRunning, now: now, callStates: callStates)
    }

    /// Feed one poll of any call signal: the app keys (lowercased bundle IDs) with a live call, and
    /// whether the default input device is running, plus any app-level call states. Returns at most
    /// one start or stop.
    public mutating func tick(liveApps audioLive: Set<String>, inputRunning: Bool, now: Double,
                              callStates: [String: CallState] = [:]) -> [TriggerAction] {
        guard enabled else { return session == nil ? [] : end(.disabled) }
        let states = Dictionary(callStates.map { ($0.key.lowercased(), $0.value) }, uniquingKeysWith: { a, _ in a })
        let ended = Set(states.filter { $0.value == .ended }.keys)
        // Suppression and event-end bookkeeping follow Core Audio, so an app that still holds its
        // devices after its call ended doesn't restart the coach when the provider loses track.
        lastLive = audioLive
        suppressed = suppressed.filter { audioLive.contains($0) }
        let live = audioLive.subtracting(ended)
        for key in live where inputRunning {
            if qualifyingSince[key] == nil { qualifyingSince[key] = now }
        }
        qualifyingSince = qualifyingSince.filter { live.contains($0.key) && inputRunning }
        if let h = hintEndsAt, now >= h { hintEndsAt = nil }

        if var s = session {
            if let e = s.endsAt, now >= e {
                return end(.eventEnded, suppress: true)
            }
            if s.appKey == nil, let key = qualified(now: now) {
                s.appKey = key
                session = s
            }
            guard let key = s.appKey else { return [] }
            if ended.contains(key) {
                let since = endedSince ?? now
                endedSince = since
                if now - since >= settings.endedStopAfterS - 1e-9 { return end(.callEnded, suppress: true) }
            } else {
                endedSince = nil
            }
            if live.contains(key) {
                offSince = nil
            } else {
                let since = offSince ?? now
                offSince = since
                if now - since >= settings.stopAfterS - 1e-9 { return end(.audioEnded) }
            }
            let muted = states[key] == .muted
            guard s.muted != muted else { return [] }
            let wasHeld = s.held
            s.muted = muted
            session = s
            return wasHeld == s.held ? [] : [.pause(s.held)]
        }
        guard let key = qualified(now: now) else { return [] }
        var s = TriggerSession(reason: .audio, appKey: key, startedAt: now, endsAt: hintEndsAt)
        s.muted = states[key] == .muted
        session = s
        offSince = nil
        return [.start(s)]
    }

    /// Longest-qualifying app past the debounce that is not suppressed.
    private func qualified(now: Double) -> String? {
        qualifyingSince
            .filter { now - $0.value >= settings.startAfterS - 1e-9 && !suppressed.contains($0.key) }
            .min { $0.value != $1.value ? $0.value < $1.value : $0.key < $1.key }?.key
    }

    public mutating func manualStart(now: Double) -> [TriggerAction] {
        guard enabled else { return [] }
        if var s = session {
            guard s.paused else { return [] }
            s.paused = false
            session = s
            return [.pause(s.held)]
        }
        let key = qualified(now: now)
        let s = TriggerSession(reason: .manual, appKey: key, startedAt: now, endsAt: nil)
        session = s
        offSince = nil
        return [.start(s)]
    }

    /// The app is quitting: ends any session, so the log says why it ended.
    public mutating func quit() -> [TriggerAction] {
        guard session != nil else { return [] }
        return end(.quit)
    }

    public mutating func manualStop() -> [TriggerAction] {
        guard session != nil else { return [] }
        return end(.manual, suppress: true)
    }

    public mutating func setPaused(_ on: Bool) -> [TriggerAction] {
        guard var s = session, s.paused != on else { return [] }
        s.paused = on
        session = s
        return [.pause(s.held)]
    }

    /// Pause while pre-warmed (indicator `.on`, no session yet): skip this call. Clears the Join
    /// hint and suppresses apps already in the start debounce until their call signal stops.
    public mutating func dismissPrewarm() {
        guard session == nil else { return }
        hintEndsAt = nil
        for key in qualifyingSince.keys { suppressed.insert(key) }
    }

    /// The user joined a calendar event (MeetingCard: Join on a card): remember the event's end. An audio session that is running
    /// (or starts before the end) stops at that time. Never starts anything by itself.
    public mutating func joinHint(endsAt: Double, now: Double) {
        guard endsAt > now else { return }
        hintEndsAt = endsAt
        if var s = session, s.reason == .audio, s.endsAt == nil {
            s.endsAt = endsAt
            session = s
        }
    }

    private mutating func end(_ reason: CoachStopReason, suppress: Bool = false) -> [TriggerAction] {
        if suppress {
            if let key = session?.appKey { suppressed.insert(key) }
            suppressed.formUnion(lastLive)
        }
        session = nil
        offSince = nil
        endedSince = nil
        if reason == .eventEnded { hintEndsAt = nil }
        return [.stop(reason)]
    }
}

/// Polls an `AudioStateProvider` into a `CoachTrigger`. The shell drives `poll` from a timer.
public final class CoachMonitor {
    public let provider: AudioStateProvider
    public let callState: CallStateProvider?
    public var trigger: CoachTrigger

    public init(provider: AudioStateProvider, trigger: CoachTrigger, callState: CallStateProvider? = nil) {
        self.provider = provider
        self.trigger = trigger
        self.callState = callState
    }

    public func poll(now: Double) -> [TriggerAction] {
        trigger.tick(provider.snapshot(), now: now, callStates: callState?.callStates() ?? [:])
    }
}
