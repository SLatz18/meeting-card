import Foundation

/// Names scoped by the running app's bundle id. The id comes from the build (`MEETINGCARD_APP_ID`
/// in project.yml), so a `scripts/build.sh --test-id` build (`com.slatz.meetingcard.swift.test`)
/// gets its own Keychain item, UserDefaults domain and privacy grants, never the real app's.
public enum AppIdentity {
    /// The shipping bundle id; stands in only when there is no bundle id (not running from a bundle).
    public static let releaseBundleId = "com.slatz.meetingcard.swift"

    /// `<bundle id>.<suffix>`.
    public static func scoped(_ suffix: String, bundleId: String? = Bundle.main.bundleIdentifier) -> String {
        "\(bundleId ?? releaseBundleId).\(suffix)"
    }

    /// The Keychain service of the OpenAI key: `com.slatz.meetingcard.swift.openai` in the shipping app.
    public static func keychainService(bundleId: String? = Bundle.main.bundleIdentifier) -> String {
        scoped("openai", bundleId: bundleId)
    }
}
