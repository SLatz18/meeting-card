import Foundation

/// Everything keyed by the running app's bundle id: Keychain service, UserDefaults suites, queue
/// labels, the log and Application Support names, and the login item. The id comes from the build
/// (`MEETINGCARD_APP_ID` in project.yml), so a `scripts/build.sh --test-id` build gets `.test` and
/// shares none of these with the shipping app. The shipping app's values never change, so existing
/// users' state stays where it is.
public struct AppIdentity: Equatable, Sendable {
    public let bundleId: String
    public init(bundleId: String) { self.bundleId = bundleId }

    public static let release = AppIdentity(bundleId: "com.slatz.meetingcard.swift")
    /// `scripts/build.sh --test-id`.
    public static let test = AppIdentity(bundleId: "com.slatz.meetingcard.swift.test")

    /// The running bundle's; the shipping identity only when there is no bundle id (not running from a bundle).
    public static var current: AppIdentity { Bundle.main.bundleIdentifier.map(AppIdentity.init(bundleId:)) ?? .release }

    public var isRelease: Bool { self == .release }

    /// `<bundle id>.<suffix>`.
    public func scoped(_ suffix: String) -> String { "\(bundleId).\(suffix)" }

    /// The Keychain service of the OpenAI key: `com.slatz.meetingcard.swift.openai` in the shipping app.
    public var keychainService: String { scoped("openai") }

    /// The log file and Application Support dir name: `MeetingCardSwift` for the shipping app,
    /// `MeetingCardSwift-Test` for `com.slatz.meetingcard.swift.test`, `MeetingCardSwift-<id>` otherwise.
    public var fileStem: String {
        let base = "MeetingCardSwift"
        if isRelease { return base }
        let family = Self.release.bundleId + "."
        guard bundleId.hasPrefix(family), bundleId.count > family.count else { return "\(base)-\(bundleId)" }
        let rest = bundleId.dropFirst(family.count)
        return "\(base)-\(rest.prefix(1).uppercased())\(rest.dropFirst())"
    }

    /// The Application Support dir that holds saved call transcripts (opt-in): `MeetingCard` for the
    /// shipping app, `MeetingCard-Test` for `com.slatz.meetingcard.swift.test`, `MeetingCard-<id>`
    /// otherwise (the `fileStem` suffix on the user-facing name).
    public var transcriptsDirName: String { "MeetingCard" + fileStem.dropFirst("MeetingCardSwift".count) }

    /// The installed copy's bundle name, the only copy that may register as a login item
    /// (`~/Applications/MeetingCardSwift.app`); nil for any other identity, so a test build never
    /// becomes a login item.
    public var loginItemAppName: String? { isRelease ? "MeetingCardSwift.app" : nil }
}
