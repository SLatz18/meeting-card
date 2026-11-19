import Foundation

/// The version shown in the coach menu, from the app's Info.plist (CFBundleShortVersionString and
/// CFBundleVersion). Pure, so the formatting is tested without a bundle.
public enum AppVersion {
    /// "2.0 (1)": the marketing version, then the build in parentheses. Either alone when the other
    /// is missing; nil when neither is usable. A blank value, or one Xcode never substituted
    /// (`$(MARKETING_VERSION)`), counts as missing.
    public static func display(short: String?, build: String?) -> String? {
        let s = usable(short), b = usable(build)
        switch (s, b) {
        case let (s?, b?): return "\(s) (\(b))"
        case let (s?, nil): return s
        case let (nil, b?): return "(\(b))"
        case (nil, nil): return nil
        }
    }

    public static func display(infoDictionary info: [String: Any]?) -> String? {
        display(short: info?["CFBundleShortVersionString"] as? String, build: info?["CFBundleVersion"] as? String)
    }

    /// The whole disabled menu line: `label` ("Version"), then the version, or `unknown` without one.
    public static func menuLine(label: String, unknown: String, infoDictionary info: [String: Any]?) -> String {
        guard let v = display(infoDictionary: info) else { return "\(label) \(unknown)" }
        return "\(label) \(v)"
    }

    private static func usable(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, !t.hasPrefix("$(") else { return nil }
        return t
    }
}

/// What the coach menu ends with, after Send Feedback (and the transcript entries): a separator,
/// the disabled version line, then Quit. The host maps entries to its own copy and actions.
public enum MenuFooterEntry: Equatable, Sendable {
    case separator
    /// A disabled line with the app's version.
    case version
    /// Quits the app (Cmd-Q).
    case quit
}

public enum MenuFooter {
    public static let entries: [MenuFooterEntry] = [.separator, .version, .quit]

    /// The shortcut for Quit.
    public static let quitKeyEquivalent = "q"
}
