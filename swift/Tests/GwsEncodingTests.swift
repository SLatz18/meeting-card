import XCTest
@testable import MeetingCardCore

/// Port of tests/test_gws_encoding.py. The Python failure (py2app interpreter with an ASCII
/// locale) has no direct Swift analogue: Swift decodes Data explicitly. These tests prove it
/// against a REAL child process running under the C locale.
final class GwsEncodingTests: XCTestCase {
    static let payloadSummary = "Team Standup \u{2014} What is Ops \u{e9} \u{2192}"
    var dir: URL!

    override func setUpWithError() throws {
        dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcs-enc-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    /// Python `_fake_gws`: a shell script that cats stderr then stdout and exits rc.
    func fakeGws(rc: Int = 0, err: String = "Using keyring backend: keyring") throws -> String {
        let payload = "{\"items\": [{\"id\": \"x\", \"summary\": \"\(Self.payloadSummary)\"}]}"
        try Data(payload.utf8).write(to: dir.appendingPathComponent("out.json"))
        try Data(err.utf8).write(to: dir.appendingPathComponent("err.txt"))
        let script = dir.appendingPathComponent("gws")
        try "#!/bin/sh\ncat '\(dir.path)/err.txt' >&2\ncat '\(dir.path)/out.json'\nexit \(rc)\n"
            .write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    /// Runner that forces the child's locale to C (the condition that broke Python).
    struct CLocaleRunner: GwsRunner {
        func run(executable: String, args: [String], env: [String: String], timeout: TimeInterval) -> RunResult {
            var e = env; e["LC_ALL"] = "C"; e["LANG"] = "C"
            return ProcessGwsRunner().run(executable: executable, args: args, env: e, timeout: timeout)
        }
    }

    // test_child_really_is_ascii -> Swift: the child really is in an ASCII locale.
    func testChildLocaleIsCAndStillDecodes() throws {
        let r = CLocaleRunner().run(executable: "/bin/sh", args: ["-c", "locale charmap"], env: Gws.buildEnv(), timeout: 5)
        guard case let .exited(0, out, _) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), "US-ASCII")
        let got = try Gws(path: try fakeGws(), runner: CLocaleRunner(), log: { _ in }).fetch()
        XCTAssertEqual(got?.first?.summary, Self.payloadSummary)
    }

    // test_fetch_decodes_utf8_under_ascii_locale
    func testFetchDecodesUTF8FromRealProcess() throws {
        let got = try Gws(path: try fakeGws(), runner: CLocaleRunner(), log: { _ in }).fetch()
        XCTAssertEqual(got?.map { $0.id }, ["x"])
        XCTAssertEqual(got?.first?.summary, Self.payloadSummary)
    }

    // test_log_survives_non_ascii_under_ascii_locale
    func testLogSurvivesNonASCIIStderr() throws {
        let paths = AppPaths(logFile: dir.appendingPathComponent("mc.log"), stateDir: dir.appendingPathComponent("st"))
        let logger = Logger(paths: paths, mirrorToStderr: false)
        let g = Gws(path: try fakeGws(rc: 1, err: "caf\u{e9} \u{2014} boom"), runner: CLocaleRunner(), log: { logger.log($0) })
        XCTAssertNil(try g.fetch())
        logger.log("title \u{2014} ok")
        let text = try String(contentsOf: paths.logFile, encoding: .utf8)
        XCTAssertTrue(text.contains("caf\u{e9} \u{2014} boom"), text)
        XCTAssertTrue(text.contains("title \u{2014} ok"), text)
    }

    // test_exec_failure_log_is_bounded: a failure must not dump gws stdout into the log.
    func testFailureLogIsBounded() throws {
        var junk = Data(repeating: UInt8(ascii: "x"), count: 20000); junk.append(0xE2)
        let logs = LogBox()
        XCTAssertNil(try gws(FakeRunner(result: .exited(status: 0, stdout: junk, stderr: Data())), logs).fetch())
        let long = String(repeating: "x", count: 20000)
        XCTAssertNil(try gws(FakeRunner(result: .launchFailed("boom " + long)), logs).fetch())
        XCTAssertEqual(logs.lines.count, 2)
        XCTAssertLessThan(logs.lines[0].count, 400)
        XCTAssertFalse(logs.lines[0].contains("xxxxxxxx"), logs.lines[0])
        XCTAssertLessThan(logs.lines[1].count, 400)
    }
}
