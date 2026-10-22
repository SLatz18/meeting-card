import Foundation

/// One read-only snapshot of what is on the Mac (#4). No TCC grant: the App fills it from
/// NSWorkspace (frontmost bundle id, default https handler) and a libproc process list.
/// Never window titles (Screen Recording), never Accessibility, never AppleScript.
public struct OpenProbe: Equatable, Sendable {
    /// Bundle id of the frontmost app (nil = unknown).
    public var frontmost: String?
    /// PIDs of Zoom's in-meeting helper (`zoom.us.app/.../CptHost`). Verified live 2026-10-06:
    /// a new CptHost appears ~3s after joining.
    public var zoomMeetingPIDs: Set<Int32>
    /// Default https handler's bundle id (where Meet / Teams / Webex links open).
    public var defaultBrowser: String?
    public init(frontmost: String? = nil, zoomMeetingPIDs: Set<Int32> = [], defaultBrowser: String? = nil) {
        self.frontmost = frontmost; self.zoomMeetingPIDs = zoomMeetingPIDs; self.defaultBrowser = defaultBrowser
    }
}

/// "Stay until the meeting opens" (#4): pure state over injected snapshots + a monotonic clock.
/// Zoom: opened = a CptHost whose PID was NOT running at the Join click (Scott may already be in
/// a meeting); the browser coming forward (Zoom's launch page) never counts (CTO ruling).
/// Meet / Teams / Webex: opened = the default browser (as of the click) is frontmost.
/// Accepted limit: a dead Meet / Teams tab looks opened.
public struct OpenWatch: Equatable, Sendable {
    public static let timeout: TimeInterval = 15
    /// #4 simplified (Scott 2026-10-06 10:24pm): detection is OFF. Join shows "Joining..." for
    /// `joinHold` seconds, then the card closes; no probe (process list, frontmost) ever runs.
    /// The detection code below stays for a later version; flip this to bring it back.
    public static let detectionEnabled = false
    public static let joinHold: TimeInterval = 8

    public enum Expect: Equatable, Sendable {
        case zoomMeeting(baseline: Set<Int32>)
        case browser(String?)
        /// Detection off: a fixed `joinHold`, then closed.
        case hold
    }
    public enum Step: Equatable, Sendable { case waiting, opened(String), timedOut }

    public let expect: Expect
    public let startedAt: TimeInterval

    public init(provider: String, at t: TimeInterval, probe: OpenProbe) {
        startedAt = t
        expect = provider == "zoom" ? .zoomMeeting(baseline: probe.zoomMeetingPIDs) : .browser(probe.defaultBrowser)
    }

    /// Detection off (#4 simplified): no probe at the click or after.
    public init(holdAt t: TimeInterval) { startedAt = t; expect = .hold }

    public func step(_ p: OpenProbe, at t: TimeInterval) -> Step {
        switch expect {
        case .hold:
            return t - startedAt >= OpenWatch.joinHold ? .opened("joined, \(Int(OpenWatch.joinHold))s hold") : .waiting
        case .zoomMeeting(let base):
            if let pid = p.zoomMeetingPIDs.subtracting(base).min() { return .opened("zoom meeting pid \(pid)") }
        case .browser(let id):
            if let id, p.frontmost == id { return .opened("browser \(id) frontmost") }
        }
        return t - startedAt >= OpenWatch.timeout ? .timedOut : .waiting
    }

    public var label: String {
        switch expect {
        case .zoomMeeting(let b): "zoom CptHost (baseline \(b.sorted()))"
        case .browser(let id): "browser \(id ?? "unknown")"
        case .hold: "fixed \(Int(OpenWatch.joinHold))s hold"
        }
    }
}
