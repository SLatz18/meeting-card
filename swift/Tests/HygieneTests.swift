import XCTest
@testable import MeetingCardCore

/// Brief's test-hygiene fix: the suite must NEVER write the real log or state dir.
final class HygieneTests: XCTestCase {
    func stamp(_ u: URL) -> String {
        guard let a = try? FileManager.default.attributesOfItem(atPath: u.path) else { return "absent" }
        return "\(a[.size] ?? 0)@\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0)"
    }

    func testSuiteNeverTouchesRealLogOrState() throws {
        let prod = AppPaths.production
        XCTAssertTrue(prod.logFile.path.hasSuffix("Library/Logs/MeetingCardSwift.log"))
        XCTAssertTrue(prod.stateDir.path.hasSuffix("Library/Application Support/MeetingCardSwift"))
        let state = prod.stateDir.appendingPathComponent("last-card.json")
        let before = (stamp(prod.logFile), stamp(state))

        // Even a direct attempt at the production paths is refused under XCTest.
        let l = Logger(paths: prod, mirrorToStderr: false)
        l.log("meet1 hygiene probe")
        XCTAssertEqual(l.refused, 1)
        XCTAssertFalse(StateWriter(paths: prod).write(windowNumber: 1, ev: fx("meet")))

        // The normal test path (temp dir) writes fine.
        let tmp = AppPaths.temporary()
        Logger(paths: tmp, mirrorToStderr: false).log("ok")
        XCTAssertTrue(StateWriter(paths: tmp).write(windowNumber: 7, ev: fx("meet")))
        let st = json(try String(contentsOf: tmp.stateDir.appendingPathComponent("last-card.json"))) as! [String: Any]
        XCTAssertEqual(st["windowNumber"] as? Int, 7)
        XCTAssertEqual(st["eventId"] as? String, "meet1")
        XCTAssertEqual(st["start"] as? String, "2026-10-06T09:25:00-05:00")
        XCTAssertNotNil(st["pid"] as? Int)
        XCTAssertTrue(try String(contentsOf: tmp.logFile).contains("ok"))

        XCTAssertEqual(stamp(prod.logFile), before.0)
        XCTAssertEqual(stamp(state), before.1)
    }

    /// Fixture runs (`--fixture`, render/eyeball tooling) never write the live log/state.
    func testFixtureModeUsesOwnPaths() {
        let prod = AppPaths.production, fx = AppPaths.fixture
        XCTAssertTrue(fx.logFile.path.hasSuffix("Library/Logs/MeetingCardSwift-fixture.log"))
        XCTAssertTrue(fx.stateDir.path.hasSuffix("Library/Application Support/MeetingCardSwift-fixture"))
        XCTAssertNotEqual(fx.logFile, prod.logFile)
        XCTAssertNotEqual(fx.stateDir, prod.stateDir)
        XCTAssertEqual(AppPaths.forRun(fixture: true), fx)
        XCTAssertEqual(AppPaths.forRun(fixture: false), prod)
    }

    func testLogLineIs12HourWithUTF8() throws {
        let tmp = AppPaths.temporary()
        Logger(paths: tmp, mirrorToStderr: false).log("caf\u{e9}")
        let line = try String(contentsOf: tmp.logFile, encoding: .utf8)
        XCTAssertNotNil(line.range(of: "^\\d{4}-\\d{2}-\\d{2} \\d{2}:\\d{2}:\\d{2} (AM|PM) caf\u{e9}\n$", options: .regularExpression), line)
    }
}
