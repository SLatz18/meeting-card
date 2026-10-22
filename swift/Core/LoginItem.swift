import Foundation

/// v2.5 #1: launch at login (SMAppService.mainApp, registered by the App). The decision of WHETHER
/// this process may register lives here, pure and tested: only the installed copy at
/// ~/Applications/MeetingCardSwift.app, never a build/dd product, a scratch copy, or a fixture run
/// (registering any of those would make that copy Scott's login item).
public enum LoginItem {
    public static let appName = "MeetingCardSwift.app"

    public enum Outcome: Equatable {
        case registered, already, error(String), skipped(String)
        var label: String {
            switch self {
            case .registered: "registered"
            case .already: "already"
            case .error(let e): "error: \(e)"
            case .skipped(let why): "skipped: \(why)"
            }
        }
    }

    /// `bundlePath` should already be symlink-resolved by the caller; `.`/`..`/trailing `/` are
    /// normalized here. Exact full-path match only: no suffix / contains matching.
    public static func shouldRegister(bundlePath: String, fixture: Bool, home: String) -> Bool {
        guard !fixture, !bundlePath.isEmpty, !home.isEmpty else { return false }
        let norm = { (p: String) in URL(fileURLWithPath: p).standardizedFileURL.path }
        let want = norm((home as NSString).appendingPathComponent("Applications/" + appName))
        return norm(bundlePath) == want
    }

    public static func logLine(status: String, outcome: Outcome) -> String {
        "login item: \(status) (\(outcome.label))"
    }
}
