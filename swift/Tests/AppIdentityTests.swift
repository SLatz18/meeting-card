import XCTest
@testable import MeetingCardCore

/// The Keychain service and other bundle-scoped names come from the bundle id, so a
/// `build.sh --test-id` build never reads or writes the shipping app's Keychain item or defaults.
final class AppIdentityTests: XCTestCase {
    static let swiftDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    func read(_ path: String) throws -> String {
        try String(contentsOf: Self.swiftDir.appendingPathComponent(path), encoding: .utf8)
    }

    func testKeychainServiceIsDerivedFromBundleId() {
        XCTAssertEqual(AppIdentity.keychainService(bundleId: "com.slatz.meetingcard.swift"), "com.slatz.meetingcard.swift.openai")
        XCTAssertEqual(AppIdentity.keychainService(bundleId: "com.slatz.meetingcard.swift.test"),
                       "com.slatz.meetingcard.swift.test.openai")
        XCTAssertEqual(AppIdentity.keychainService(bundleId: "com.example.other"), "com.example.other.openai")
        XCTAssertEqual(AppIdentity.keychainService(bundleId: nil), "com.slatz.meetingcard.swift.openai")
        XCTAssertEqual(AppIdentity.keychainService(), AppIdentity.keychainService(bundleId: Bundle.main.bundleIdentifier),
                       "defaults to the running bundle")
    }

    func testScopedNamesFollowBundleId() {
        XCTAssertEqual(AppIdentity.scoped("snapshots", bundleId: "com.slatz.meetingcard.swift"), "com.slatz.meetingcard.swift.snapshots")
        XCTAssertEqual(AppIdentity.scoped("snapshots", bundleId: "com.slatz.meetingcard.swift.test"),
                       "com.slatz.meetingcard.swift.test.snapshots")
    }

    func testCoachKeychainUsesTheDerivedService() throws {
        let src = try read("App/CoachController.swift")
        XCTAssertTrue(src.contains("static let keychainService = AppIdentity.keychainService()"))
        XCTAssertTrue(src.contains("keychain: KeychainStore = KeychainStore(service: CoachController.keychainService)"))
        XCTAssertTrue(src.contains("init(defaults: UserDefaults = .standard"), "defaults domain = bundle id")
    }

    /// Only AppIdentity names the shipping id; the app and Core derive everything else from the bundle.
    func testNoHardcodedBundleIdInSources() throws {
        for dir in ["App", "Core"] {
            let root = Self.swiftDir.appendingPathComponent(dir)
            let e = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in e where url.pathExtension == "swift" && url.lastPathComponent != "AppIdentity.swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                XCTAssertFalse(text.contains("\"com.slatz.meetingcard"), "\(dir)/\(url.lastPathComponent) hardcodes the bundle id")
                XCTAssertFalse(text.contains("persistentDomain(forName: \""), "\(dir)/\(url.lastPathComponent) names a defaults domain")
            }
        }
    }

    /// Release and default builds keep the shipping identity; --test-id overrides only the two settings.
    func testBuildSettingsKeepTheShippingIdentity() throws {
        let spec = try read("project.yml")
        XCTAssertTrue(spec.contains("MEETINGCARD_APP_ID: com.slatz.meetingcard.swift\n"))
        XCTAssertTrue(spec.contains("MEETINGCARD_APP_NAME: MeetingCardSwift\n"))
        XCTAssertTrue(spec.contains("PRODUCT_BUNDLE_IDENTIFIER: \"$(MEETINGCARD_APP_ID)\""))
        let plist = try read("App/Info.plist")
        XCTAssertTrue(plist.contains("<key>CFBundleName</key>\n\t<string>$(MEETINGCARD_APP_NAME)</string>"))
        XCTAssertTrue(plist.contains("<key>CFBundleDisplayName</key>\n\t<string>$(MEETINGCARD_APP_NAME)</string>"))
        let build = try read("scripts/build.sh")
        XCTAssertTrue(build.contains("IDENTITY=(MEETINGCARD_APP_ID=com.slatz.meetingcard.swift.test \"MEETINGCARD_APP_NAME=MeetingCard (Test)\")"))
        XCTAssertTrue(build.contains("RELEASE_DD=\"$DD\"; IDENTITY=()"), "no overrides without --test-id")
    }
}
