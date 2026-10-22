import XCTest
@testable import MeetingCardCore

/// v2.5 #1 (Scott 9:05am): launch at login via SMAppService.mainApp, but ONLY from the installed app.
final class LoginItemTests: XCTestCase {
    let home = "/Users/jdoe"
    var installed: String { home + "/Applications/MeetingCardSwift.app" }

    func testInstalledLiveRegisters() {
        XCTAssertTrue(LoginItem.shouldRegister(bundlePath: installed, fixture: false, home: home))
        XCTAssertTrue(LoginItem.shouldRegister(bundlePath: installed + "/", fixture: false, home: home), "trailing slash")
    }

    func testBuildCopyNeverRegisters() {
        let dd = home + "/src/x/swift/build/dd/Build/Products/Release/MeetingCardSwift.app"
        XCTAssertFalse(LoginItem.shouldRegister(bundlePath: dd, fixture: false, home: home))
    }

    func testFixtureNeverRegisters() {
        XCTAssertFalse(LoginItem.shouldRegister(bundlePath: installed, fixture: true, home: home))
    }

    func testOtherApplicationsPathsNeverRegister() {
        for p in ["/Applications/MeetingCardSwift.app",
                  home + "/scratch/Applications/MeetingCardSwift.app",
                  home + "/Applications/Old/MeetingCardSwift.app",
                  home + "/Applications/MeetingCardSwift copy.app",
                  "/Users/other/Applications/MeetingCardSwift.app",
                  home + "/Applications/../tmp/Applications/MeetingCardSwift.app",
                  ""] {
            XCTAssertFalse(LoginItem.shouldRegister(bundlePath: p, fixture: false, home: home), p)
        }
    }

    func testDotSegmentsNormalize() {
        XCTAssertTrue(LoginItem.shouldRegister(bundlePath: home + "/Applications/./MeetingCardSwift.app", fixture: false, home: home))
    }

    func testLogLines() {
        XCTAssertEqual(LoginItem.logLine(status: "enabled", outcome: .already), "login item: enabled (already)")
        XCTAssertEqual(LoginItem.logLine(status: "enabled", outcome: .registered), "login item: enabled (registered)")
        XCTAssertEqual(LoginItem.logLine(status: "requiresApproval", outcome: .registered),
                       "login item: requiresApproval (registered)")
        XCTAssertEqual(LoginItem.logLine(status: "notRegistered", outcome: .error("boom")),
                       "login item: notRegistered (error: boom)")
        XCTAssertEqual(LoginItem.logLine(status: "notRegistered", outcome: .skipped("not installed copy")),
                       "login item: notRegistered (skipped: not installed copy)")
    }

    /// The App wiring: gated on shouldRegister, registers only when not enabled, one attempt per launch.
    func testAppWiring() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("App/Controller.swift"), encoding: .utf8)
        XCTAssertTrue(src.contains("SMAppService.mainApp"))
        XCTAssertTrue(src.contains("LoginItem.shouldRegister("))
        XCTAssertTrue(src.contains("resolvingSymlinksInPath()"))
        XCTAssertTrue(src.contains("args.fixture != nil"))
        XCTAssertFalse(src.contains("unregister("), "never unregisters")
        XCTAssertTrue(src.contains("if svc.status == .requiresApproval {"), "a user-disabled item is not re-registered")
    }
}
