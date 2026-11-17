import Foundation

// Auto-on trigger: the coach starts when one app (counting its helper processes) has audio input
// AND output running continuously for ~3 s, and stops when either stays off for ~30 s. Detection
// reads only Core Audio "is running" state; no audio is captured to detect a call.

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
    /// Never trigger on these (MeetingCard itself, the listen-more prototype), in any mode.
    public var excludedBundleIds: [String]
    public var ownPid: Int32
    public var startAfterS: Double
    public var stopAfterS: Double

    public init(allowlist: [String], anyApp: Bool = false, excludedBundleIds: [String], ownPid: Int32,
                startAfterS: Double = 3, stopAfterS: Double = 30) {
        self.allowlist = allowlist
        self.anyApp = anyApp
        self.excludedBundleIds = excludedBundleIds
        self.ownPid = ownPid
        self.startAfterS = startAfterS
        self.stopAfterS = stopAfterS
    }

    /// `allowlist` is the user's edited list from Settings; nil means the config's call apps.
    public init(config: ListenMoreConfig, anyApp: Bool, ownPid: Int32, ownBundleId: String?, allowlist: [String]? = nil) {
        self.init(allowlist: allowlist ?? config.captureTargets.map(\.bundleId), anyApp: anyApp,
                  excludedBundleIds: config.trigger.excludeBundleIds + [ownBundleId].compactMap { $0 },
                  ownPid: ownPid, startAfterS: config.trigger.startAfterS, stopAfterS: config.trigger.stopAfterS)
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
    /// The calendar event the user joined ended.
    case eventEnded
    case manual
    /// The opt-in setting was switched off.
    case disabled
}

public struct CoachSession: Equatable, Sendable {
    public var reason: CoachStartReason
    /// The app being coached (lowercased bundle ID); nil for a manual start until an app qualifies.
    public var appKey: String?
    public var startedAt: Double
    /// Calendar end of the event joined from a card (a hint, never a requirement).
    public var endsAt: Double?
    public var paused = false
}

/// The coach chip's state. Hidden unless the coach is pre-warmed or running; a session ends (and
/// the chip hides) `stopAfterS` (~30 s) after the call app's input or output goes off.
public enum CoachIndicator: String, Equatable, Sendable {
    case hidden
    /// Enabled and pre-warmed, not streaming yet.
    case on
    /// Session running: audio is being analysed.
    case listening
    /// Session paused by the user: no capture, no streams.
    case paused
}

public enum TriggerAction: Equatable, Sendable {
    case start(CoachSession)
    case stop(CoachStopReason)
    case pause(Bool)
}

/// The session state machine. Pure: feed it snapshots and times, act on the returned actions.
public struct CoachTrigger: Sendable {
    public var settings: TriggerSettings
    /// The opt-in setting. Off (the default) means no session ever starts.
    public private(set) var enabled: Bool
    public private(set) var session: CoachSession?
    private var qualifyingSince: [String: Double] = [:]
    /// Apps that must stop qualifying before they may auto-start again (after a manual or
    /// event-end stop), so a still-running call does not restart the coach 3 s later.
    public private(set) var suppressed: Set<String> = []
    private var offSince: Double?
    private var hintEndsAt: Double?
    private var lastGroups: [String: TriggerSettings.AppAudio] = [:]

    public init(settings: TriggerSettings, enabled: Bool = false) {
        self.settings = settings
        self.enabled = enabled
    }

    public var isActive: Bool { session != nil }
    public var isCapturing: Bool { session.map { !$0.paused } ?? false }

    /// Pre-warmed: enabled, no session yet, but a call looks imminent (Join was clicked on a card
    /// for an event that hasn't ended, or a call app is inside the start debounce).
    public var isPrewarmed: Bool {
        guard enabled, session == nil else { return false }
        return hintEndsAt != nil || qualifyingSince.keys.contains { !suppressed.contains($0) }
    }

    public var indicator: CoachIndicator {
        if let s = session { return s.paused ? .paused : .listening }
        return isPrewarmed ? .on : .hidden
    }

    public mutating func setEnabled(_ on: Bool) -> [TriggerAction] {
        enabled = on
        guard !on, session != nil else { return [] }
        return end(.disabled)
    }

    /// Feed one poll. Returns at most one start or stop.
    public mutating func tick(_ snap: AudioStateSnapshot, now: Double) -> [TriggerAction] {
        guard enabled else { return session == nil ? [] : end(.disabled) }
        let groups = settings.group(snap)
        lastGroups = groups
        for (key, a) in groups where a.both && snap.defaultInputRunning {
            if qualifyingSince[key] == nil { qualifyingSince[key] = now }
        }
        qualifyingSince = qualifyingSince.filter { groups[$0.key]?.both == true && snap.defaultInputRunning }
        suppressed = suppressed.filter { groups[$0]?.both == true }
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
            if groups[key]?.both == true {
                offSince = nil
            } else {
                let since = offSince ?? now
                offSince = since
                if now - since >= settings.stopAfterS - 1e-9 { return end(.audioEnded) }
            }
            return []
        }
        guard let key = qualified(now: now) else { return [] }
        let s = CoachSession(reason: .audio, appKey: key, startedAt: now, endsAt: hintEndsAt)
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
            return [.pause(false)]
        }
        let key = qualified(now: now)
        let s = CoachSession(reason: .manual, appKey: key, startedAt: now, endsAt: nil)
        session = s
        offSince = nil
        return [.start(s)]
    }

    public mutating func manualStop() -> [TriggerAction] {
        guard session != nil else { return [] }
        return end(.manual, suppress: true)
    }

    public mutating func setPaused(_ on: Bool) -> [TriggerAction] {
        guard var s = session, s.paused != on else { return [] }
        s.paused = on
        session = s
        return [.pause(on)]
    }

    /// Pause while pre-warmed (chip "On", no session yet): skip this call. Clears the Join hint
    /// and suppresses apps already in the start debounce until their audio stops.
    public mutating func dismissPrewarm() {
        guard session == nil else { return }
        hintEndsAt = nil
        for key in qualifyingSince.keys { suppressed.insert(key) }
    }

    /// The user clicked Join on a card: remember the event's end. An audio session that is running
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
            for (key, a) in lastGroups where a.both { suppressed.insert(key) }
        }
        session = nil
        offSince = nil
        if reason == .eventEnded { hintEndsAt = nil }
        return [.stop(reason)]
    }
}

/// Polls an `AudioStateProvider` into a `CoachTrigger`. The shell drives `poll` from a timer.
public final class CoachMonitor {
    public let provider: AudioStateProvider
    public var trigger: CoachTrigger

    public init(provider: AudioStateProvider, trigger: CoachTrigger) {
        self.provider = provider
        self.trigger = trigger
    }

    public func poll(now: Double) -> [TriggerAction] {
        trigger.tick(provider.snapshot(), now: now)
    }
}
