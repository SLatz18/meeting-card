import Foundation

/// Why call detection did or did not start a session on one check. Named tokens only.
public enum DetectionReason: String, Equatable, Sendable {
    /// The session started on this check.
    case started
    /// An app holds the mic and plays audio, and its start timer is running (`met` once it has run
    /// `startAfterS` seconds).
    case startTimer
    case coachDisabled
    /// A session is already running.
    case inSession
    /// The default input device is not running, so nothing is using a mic.
    case inputDeviceIdle
    /// The input device is running but Core Audio lists no process for it.
    case noProcesses
    /// No process holds the input.
    case noMicHolder
    /// A process holds the input but has no bundle ID Core Audio could name, so it can never be matched.
    case unidentifiedProcess
    /// An app holds the mic but is not on the allow list (and "any app" is off).
    case appNotAllowed
    /// An app holds the mic but is excluded (this app, another coach app).
    case appExcluded
    /// An allowed app holds the mic and no audio is playing from it.
    case noCallAudio
    /// An allowed app qualifies but is suppressed until its audio stops (after a stop for this call).
    case suppressed
}

public enum DetectionResult: String, Equatable, Sendable {
    case met
    case notMet
}

/// Whether the permissions a coached call needs are known to be granted. The detector does not depend on
/// them (Core Audio's running flags need none); the line says so, to put a refusal beside a silent call.
public enum PermissionSummary: String, Equatable, Sendable {
    case granted
    case notGranted
    case unknown
}

/// What one detection check saw and decided.
public struct DetectionCheck: Equatable, Sendable {
    /// The app holding the mic input (a bundle ID), or nil.
    public var micApp: LogToken?
    /// Audio is playing from that app.
    public var callAudio: Bool
    public var result: DetectionResult
    public var reason: DetectionReason
    /// Seconds the start timer has run, while it runs.
    public var timerSeconds: Int?
    public var permission: PermissionSummary

    public init(micApp: LogToken?, callAudio: Bool, result: DetectionResult, reason: DetectionReason,
                timerSeconds: Int? = nil, permission: PermissionSummary = .unknown) {
        self.micApp = micApp
        self.callAudio = callAudio
        self.result = result
        self.reason = reason
        self.timerSeconds = timerSeconds
        self.permission = permission
    }

    /// What a repeat of the same check does not change: the throttle logs when this changes.
    var signature: [String] {
        [micApp?.value ?? "none", String(callAudio), result.rawValue, reason.rawValue, permission.rawValue]
    }
}

public enum DetectionDiagnostics {
    /// The decision for one poll, from the Core Audio snapshot and the trigger's state. Pure.
    /// - Parameters:
    ///   - startTimers: seconds each app key has qualified (input and output running) so far.
    ///   - started: the trigger started a session on this poll.
    public static func evaluate(snapshot: AudioStateSnapshot, settings: TriggerSettings, enabled: Bool, inSession: Bool,
                                suppressed: Set<String>, startTimers: [String: Double], started: Bool,
                                permission: PermissionSummary = .unknown) -> DetectionCheck {
        let grouped = settings.group(snapshot)
        let holders = snapshot.processes.filter { $0.isRunningInput && $0.pid != settings.ownPid }
        func check(_ micApp: LogToken?, _ callAudio: Bool, _ result: DetectionResult, _ reason: DetectionReason,
                   timer: Double? = nil) -> DetectionCheck {
            DetectionCheck(micApp: micApp, callAudio: callAudio, result: result, reason: reason,
                           timerSeconds: timer.map { Int($0) }, permission: permission)
        }

        // The app to talk about: an allowed app holding the mic if there is one, else the first holder.
        let mapped = holders.compactMap { p in settings.appKey(for: p).map { (p, $0) } }
        let lead = mapped.first
        let leadName: LogToken? = lead.map { LogToken($0.1) }
            ?? holders.first.flatMap { LogToken($0.owningBundleId ?? $0.bundleId) }
            ?? (holders.isEmpty ? nil : LogToken("unidentified"))
        let callAudio = lead.map { grouped[$0.1]?.output ?? false } ?? holders.contains { $0.isRunningOutput }

        guard enabled else { return check(leadName, callAudio, .notMet, .coachDisabled) }
        if started { return check(leadName, callAudio, .met, .started, timer: startTimers[lead?.1 ?? ""] ?? settings.startAfterS) }
        guard !inSession else { return check(leadName, callAudio, .notMet, .inSession) }
        guard snapshot.defaultInputRunning else { return check(leadName, callAudio, .notMet, .inputDeviceIdle) }
        guard !snapshot.processes.isEmpty else { return check(nil, false, .notMet, .noProcesses) }
        guard !holders.isEmpty else { return check(nil, false, .notMet, .noMicHolder) }

        let live = grouped.filter { $0.value.both }.keys.sorted()
        if let key = live.first(where: { !suppressed.contains($0) }) {
            let elapsed = startTimers[key] ?? 0
            let met = elapsed >= settings.startAfterS - 1e-9
            return check(LogToken(key), true, met ? .met : .notMet, .startTimer, timer: elapsed)
        }
        if let key = live.first { return check(LogToken(key), true, .notMet, .suppressed) }
        if lead != nil { return check(leadName, callAudio, .notMet, .noCallAudio) }

        if holders.contains(where: { ($0.bundleId ?? "").isEmpty && ($0.owningBundleId ?? "").isEmpty }) {
            return check(LogToken("unidentified"), callAudio, .notMet, .unidentifiedProcess)
        }
        let excluded = holders.allSatisfy { p in
            [p.bundleId, p.owningBundleId].compactMap { $0 }.contains { id in
                settings.excludedBundleIds.contains { BundleIds.belongs(id, to: $0) }
            }
        }
        return check(leadName, callAudio, .notMet, excluded ? .appExcluded : .appNotAllowed)
    }
}

/// Decides which checks reach the log: every change of what was seen or decided, and otherwise one
/// line per `heartbeat` seconds, so a quiet stretch shows the detector is alive without flooding.
public struct DetectionLogThrottle: Sendable {
    public static let heartbeat: TimeInterval = 10

    private var lastSignature: [String]?
    private var lastLoggedAt: TimeInterval = 0

    public init() {}

    public mutating func shouldLog(_ check: DetectionCheck, now: TimeInterval) -> Bool {
        let changed = lastSignature != check.signature
        guard changed || now - lastLoggedAt >= Self.heartbeat - 1e-9 else { return false }
        lastSignature = check.signature
        lastLoggedAt = now
        return true
    }

    public mutating func reset() {
        lastSignature = nil
    }
}
