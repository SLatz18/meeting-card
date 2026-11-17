import XCTest
@testable import MeetingCardCore

/// Everything keyed by the bundle id comes from AppIdentity, so a `build.sh --test-id` build shares
/// nothing with the shipping app, and the shipping app's paths and ids never move.
final class AppIdentityTests: XCTestCase {
    static let swiftDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    func read(_ path: String) throws -> String {
        try String(contentsOf: Self.swiftDir.appendingPathComponent(path), encoding: .utf8)
    }

    func testKeychainServiceIsDerivedFromBundleId() {
        XCTAssertEqual(AppIdentity.release.keychainService, "com.slatz.meetingcard.swift.openai")
        XCTAssertEqual(AppIdentity.test.keychainService, "com.slatz.meetingcard.swift.test.openai")
        XCTAssertEqual(AppIdentity(bundleId: "com.example.other").keychainService, "com.example.other.openai")
        XCTAssertEqual(AppIdentity.current.bundleId, Bundle.main.bundleIdentifier ?? AppIdentity.release.bundleId,
                       "the running bundle's id")
    }

    func testFileStemFollowsBundleId() {
        XCTAssertEqual(AppIdentity.release.fileStem, "MeetingCardSwift")
        XCTAssertEqual(AppIdentity.test.fileStem, "MeetingCardSwift-Test")
        XCTAssertEqual(AppIdentity(bundleId: "com.example.other").fileStem, "MeetingCardSwift-com.example.other")
    }

    /// Existing users' state stays put: the shipping identity's paths and ids are exactly as before.
    func testReleaseIdentityIsUnchanged() {
        let r = AppIdentity.release, home = NSHomeDirectory()
        XCTAssertEqual(r.bundleId, "com.slatz.meetingcard.swift")
        XCTAssertEqual(AppPaths.production(for: r).logFile.path, home + "/Library/Logs/MeetingCardSwift.log")
        XCTAssertEqual(AppPaths.production(for: r).stateDir.path, home + "/Library/Application Support/MeetingCardSwift")
        XCTAssertEqual(AppPaths.fixture(for: r).logFile.path, home + "/Library/Logs/MeetingCardSwift-fixture.log")
        XCTAssertEqual(AppPaths.fixture(for: r).stateDir.path, home + "/Library/Application Support/MeetingCardSwift-fixture")
        XCTAssertEqual(r.keychainService, "com.slatz.meetingcard.swift.openai")
        XCTAssertEqual(r.scoped("snapshots"), "com.slatz.meetingcard.swift.snapshots")
        XCTAssertEqual(r.scoped("gws"), "com.slatz.meetingcard.swift.gws")
        XCTAssertEqual(r.loginItemAppName, "MeetingCardSwift.app")
        XCTAssertTrue(LoginItem.shouldRegister(bundlePath: home + "/Applications/MeetingCardSwift.app", fixture: false,
                                               home: home, identity: r))
    }

    /// The test identity shares no filesystem path, defaults domain, Keychain service or login item
    /// with the shipping identity (compared case-insensitively, as APFS does by default).
    func testTestIdentitySharesNothingWithRelease() {
        let home = NSHomeDirectory()
        func files(_ id: AppIdentity) -> [String] {
            let paths = [AppPaths.production(for: id), AppPaths.fixture(for: id)].flatMap { [$0.logFile.path, $0.stateDir.path] }
            let loginItem = id.loginItemAppName.map { [home + "/Applications/" + $0] } ?? []
            return (paths + loginItem).map { $0.lowercased() }
        }
        let rf = files(.release), tf = files(.test)
        for t in tf {
            for r in rf {
                XCTAssertNotEqual(t, r)
                XCTAssertFalse(t.hasPrefix(r + "/"), "\(t) is inside \(r)")
                XCTAssertFalse(r.hasPrefix(t + "/"), "\(r) is inside \(t)")
            }
        }

        // Defaults domains (the standard domain is the bundle id; suites are scoped) and Keychain services.
        func names(_ id: AppIdentity) -> Set<String> {
            Set([id.bundleId, id.scoped("snapshots"), id.keychainService, id.scoped("gws")].map { $0.lowercased() })
        }
        XCTAssertTrue(names(.release).isDisjoint(with: names(.test)), "\(names(.release).intersection(names(.test)))")

        XCTAssertNil(AppIdentity.test.loginItemAppName)
        for p in [home + "/Applications/MeetingCardSwift.app", home + "/Applications/MeetingCardSwift-Test.app"] {
            XCTAssertFalse(LoginItem.shouldRegister(bundlePath: p, fixture: false, home: home, identity: .test), p)
        }
    }

    func testAppUsesTheCurrentIdentity() throws {
        let coach = try read("App/CoachController.swift")
        XCTAssertTrue(coach.contains("static let keychainService = AppIdentity.current.keychainService"))
        XCTAssertTrue(coach.contains("keychain: KeychainStore = KeychainStore(service: CoachController.keychainService)"))
        XCTAssertTrue(coach.contains("init(defaults: UserDefaults = .standard"), "defaults domain = bundle id")
        let controller = try read("App/Controller.swift")
        XCTAssertTrue(controller.contains("paths = AppPaths.forRun(fixture: args.fixture != nil, identity: .current)"))
        XCTAssertTrue(controller.contains("let identity = AppIdentity.current\n"))
        XCTAssertTrue(controller.contains("home: home, identity: identity)"))
        XCTAssertTrue(controller.contains("DispatchQueue(label: AppIdentity.current.scoped(\"gws\")"))
        XCTAssertEqual(try read("App/UISnapshots.swift").components(separatedBy: "AppIdentity.current.scoped(\"snapshots\")").count, 4,
                       "menu, Settings and coach card shots")
    }

    /// Only AppIdentity names the shipping id or the app's file names; only AppPaths builds ~/Library paths.
    func testNoHardcodedIdentityInSources() throws {
        for dir in ["App", "Core"] {
            let root = Self.swiftDir.appendingPathComponent(dir)
            let e = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in e where url.pathExtension == "swift" && url.lastPathComponent != "AppIdentity.swift" {
                let name = "\(dir)/\(url.lastPathComponent)"
                let text = try String(contentsOf: url, encoding: .utf8)
                XCTAssertFalse(text.contains("\"com.slatz.meetingcard"), "\(name) hardcodes the bundle id")
                XCTAssertFalse(text.contains("persistentDomain(forName: \""), "\(name) names a defaults domain")
                XCTAssertFalse(text.contains("suiteName: \""), "\(name) names a defaults suite")
                XCTAssertFalse(text.contains("\"MeetingCardSwift.app"), "\(name) names the installed app")
                if name != "Core/Logger.swift" {
                    XCTAssertFalse(text.contains("Library/"), "\(name) builds a ~/Library path")
                }
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
        XCTAssertTrue(build.contains("IDENTITY=(MEETINGCARD_APP_ID=\(AppIdentity.test.bundleId) \"MEETINGCARD_APP_NAME=MeetingCard (Test)\")"))
        XCTAssertTrue(build.contains("RELEASE_DD=\"$DD\"; IDENTITY=()"), "no overrides without --test-id")
    }
}
