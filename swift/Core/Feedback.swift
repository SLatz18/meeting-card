import Foundation

/// "Send Feedback": a link to a new GitHub issue on the `feedback.yml` issue form, pre-filled through
/// the form's field ids with the four values in `Field` and nothing else. The repo turns blank issues
/// off, so a plain `body=` link would land on the template chooser and lose its text. The app only
/// opens this URL in the browser: no token, no API call.
public enum Feedback {
    public static let issuesNew = "https://github.com/SLatz18/meeting-card/issues/new"
    public static let template = "feedback.yml"
    /// Our own budget for the whole URL, far below the length where GitHub answers 414 URI Too Long.
    public static let maxURLLength = 2048
    /// Per pre-filled value, in Unicode scalars (so even 4-byte scalars keep the URL in budget).
    public static let maxValueLength = 32

    /// The issue form fields the link fills (their `id`s), in URL order.
    public enum Field: String, CaseIterable, Sendable {
        case appVersion = "app-version"
        case buildNumber = "build-number"
        case macOSVersion = "macos-version"
        case buildType = "build-type"
    }

    public struct Info: Equatable, Sendable {
        public var appVersion: String
        public var buildNumber: String
        public var macOSVersion: String
        public var identity: AppIdentity

        public init(appVersion: String, buildNumber: String, macOSVersion: String, identity: AppIdentity) {
            self.appVersion = appVersion
            self.buildNumber = buildNumber
            self.macOSVersion = macOSVersion
            self.identity = identity
        }

        /// The running app's: version and build number from its Info.plist, the macOS version, and
        /// whether this is the shipping identity.
        public static func current(infoDictionary: [String: Any]? = Bundle.main.infoDictionary,
                                   os: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion,
                                   identity: AppIdentity = .current) -> Info {
            func string(_ key: String) -> String { infoDictionary?[key] as? String ?? "" }
            return Info(appVersion: string("CFBundleShortVersionString"), buildNumber: string("CFBundleVersion"),
                        macOSVersion: "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)", identity: identity)
        }

        public func value(_ field: Field) -> String {
            switch field {
            case .appVersion: appVersion
            case .buildNumber: buildNumber
            case .macOSVersion: macOSVersion
            case .buildType: identity.isRelease ? FeedbackCopy.buildRelease : FeedbackCopy.buildTestId
            }
        }
    }

    /// `template` first, then each field's cleaned value.
    public static func queryItems(_ info: Info) -> [(name: String, value: String)] {
        [("template", template)] + Field.allCases.map { ($0.rawValue, clean(info.value($0))) }
    }

    public static func url(_ info: Info) -> URL {
        let query = queryItems(info).map { "\(encode($0.name))=\(encode($0.value))" }.joined(separator: "&")
        return URL(string: "\(issuesNew)?\(query)")!
    }

    /// RFC 3986 unreserved characters. Everything else (space, newline, `+`, `&`, `=`, `#`, `%`, non-ASCII)
    /// is percent-encoded as UTF-8, so a value can't end the query early or start another field.
    static let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    public static func encode(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }

    /// One line (control characters and line breaks become spaces), trimmed, at most `maxValueLength`
    /// scalars; `FeedbackCopy.unknown` when nothing is left.
    public static func clean(_ s: String) -> String {
        let breaks = CharacterSet.controlCharacters.union(.newlines)
        var scalars = String.UnicodeScalarView()
        for u in s.unicodeScalars { scalars.append(breaks.contains(u) ? " " : u) }
        let line = String(scalars).trimmingCharacters(in: .whitespaces)
        let capped = String(String.UnicodeScalarView(line.unicodeScalars.prefix(maxValueLength)))
            .trimmingCharacters(in: .whitespaces)
        return capped.isEmpty ? FeedbackCopy.unknown : capped
    }
}

/// The "issues are public" notice shown before the browser opens. "Don't show again" is a defaults
/// flag keyed through AppIdentity, so a `--test-id` build keeps its own.
public struct FeedbackNotice {
    public enum Choice: Sendable {
        case `continue`
        case cancel
    }

    public static func key(for identity: AppIdentity) -> String { identity.scoped("feedback.hidePublicNotice") }

    public let defaults: UserDefaults
    public let key: String

    public init(defaults: UserDefaults, identity: AppIdentity) {
        self.defaults = defaults
        key = Self.key(for: identity)
    }

    public var shouldShow: Bool { !defaults.bool(forKey: key) }

    /// Whether to open the link. "Don't show again" sticks only on Open GitHub (`.continue`); Cancel opens nothing and
    /// the notice shows next time.
    @discardableResult
    public func resolve(_ choice: Choice, dontShowAgain: Bool) -> Bool {
        switch choice {
        case .continue:
            if dontShowAgain { defaults.set(true, forKey: key) }
            return true
        case .cancel:
            return false
        }
    }
}
