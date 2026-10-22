import XCTest
@testable import MeetingCardCore

final class GwsTests: XCTestCase {
    func testEnvBuilderFromStrippedEnv() {
        let env = Gws.buildEnv(["PATH": "/usr/bin:/bin", "FOO": "1"])
        let pw = getpwuid(getuid())!.pointee
        let dir = String(cString: pw.pw_dir), name = String(cString: pw.pw_name)
        XCTAssertEqual(env["HOME"], dir)
        XCTAssertEqual(env["USER"], name)
        XCTAssertEqual(env["LOGNAME"], name)
        XCTAssertEqual(env["PATH"], "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(dir)/.local/bin")
        XCTAssertEqual(env["FOO"], "1")
    }

    func testResolvePathOrder() {
        let h = "/h"
        // Override wins when executable.
        XCTAssertEqual(Gws.resolvePath(env: ["MEETING_CARD_GWS": "/x/gws"], home: h, isExecutable: { _ in true }), "/x/gws")
        // A non-executable override falls through to the install spots, in order.
        XCTAssertEqual(Gws.resolvePath(env: ["MEETING_CARD_GWS": "/x/gws"], home: h,
                                       isExecutable: { $0 == "/opt/homebrew/bin/gws" }), "/opt/homebrew/bin/gws")
        XCTAssertEqual(Gws.resolvePath(env: [:], home: h, isExecutable: { $0 != "/h/.local/bin/gws" }), "/opt/homebrew/bin/gws")
        XCTAssertEqual(Gws.resolvePath(env: [:], home: h, isExecutable: { $0 == "/usr/local/bin/gws" }), "/usr/local/bin/gws")
        XCTAssertEqual(Gws.resolvePath(env: [:], home: h, isExecutable: { $0 == "/h/.cargo/bin/gws" }), "/h/.cargo/bin/gws")
        XCTAssertEqual(Gws.resolvePath(env: ["MEETING_CARD_GWS": ""], home: h, isExecutable: { _ in true }), "/h/.local/bin/gws")
        // A relative override is ignored (it would resolve against the cwd).
        XCTAssertEqual(Gws.resolvePath(env: ["MEETING_CARD_GWS": "gws"], home: h, isExecutable: { _ in true }), "/h/.local/bin/gws")
        // Nothing installed: the historical default.
        XCTAssertEqual(Gws.resolvePath(env: [:], home: h, isExecutable: { _ in false }), "/h/.local/bin/gws")
    }

    func testIsExecutableFileRejectsDirectories() throws {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("mcs-exe-\(UUID())")
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: d) }
        XCTAssertFalse(Gws.isExecutableFile(d.path), "a directory is not a gws binary")
        let f = d.appendingPathComponent("gws")
        try "#!/bin/sh\n".write(to: f, atomically: true, encoding: .utf8)
        XCTAssertFalse(Gws.isExecutableFile(f.path), "not chmod +x")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        XCTAssertTrue(Gws.isExecutableFile(f.path))
    }

    func testEnvBuilderKeepsUserEnvNotStripped() {
        // Never a stripped env: the parent env is passed through, then forced keys applied.
        let env = Gws.buildEnv()
        XCTAssertGreaterThan(env.count, 4)
        for (k, v) in ProcessInfo.processInfo.environment where !["HOME", "USER", "LOGNAME", "PATH"].contains(k) {
            XCTAssertEqual(env[k], v, k)
        }
    }

    func testFetchOkStdoutOnly() throws {
        let r = FakeRunner(out: #"{"items": [{"id": "a"}]}"#, err: "Using keyring backend: keyring")
        XCTAssertEqual(try gws(r).fetch()?.map { $0.id }, ["a"])
        XCTAssertEqual(r.calls[0].executable, "/fake/gws")
        XCTAssertEqual(Gws.defaultPath, Gws.resolvePath())
        XCTAssertFalse(r.calls[0].env["HOME"]!.isEmpty)
        XCTAssertEqual(Array(r.calls[0].args.prefix(3)), ["calendar", "events", "list"])
        let p = json(r.calls[0].args[4]) as! [String: Any]
        XCTAssertEqual(p["calendarId"] as? String, "primary")
        XCTAssertEqual(p["singleEvents"] as? Bool, true)
        XCTAssertEqual(p["orderBy"] as? String, "startTime")
        XCTAssertEqual(r.calls[0].timeout, 45)
    }

    func testFetchWindowIsNowMinus10ToPlus2h() throws {
        let r = FakeRunner(out: #"{"items": []}"#)
        _ = try gws(r).fetch(now: Timing.parseDT("2026-10-06T12:00:00-05:00")!)
        let p = json(r.calls[0].args[4]) as! [String: Any]
        XCTAssertEqual(p["timeMin"] as? String, "2026-10-06T16:50:00Z")
        XCTAssertEqual(p["timeMax"] as? String, "2026-10-06T19:00:00Z")
    }

    func testFetchFailuresReturnNil() throws {
        XCTAssertNil(try gws(FakeRunner(rc: 1, err: "network")).fetch())
        XCTAssertNil(try gws(FakeRunner(out: "nope")).fetch())
        XCTAssertNil(try gws(FakeRunner(out: "{}")).fetch())
        XCTAssertNil(try gws(FakeRunner(result: .timedOut)).fetch())
        XCTAssertNil(try gws(FakeRunner(result: .launchFailed("ENOENT"))).fetch())
    }

    func testDestructiveMessageIsFatal() {
        let r = FakeRunner(rc: 1, err: "Warning: removing undecryptable credentials file (x)")
        XCTAssertThrowsError(try gws(r).fetch()) { XCTAssertTrue($0 is GwsFatal) }
        // even with rc=0 and valid JSON, the message is fatal
        let r0 = FakeRunner(rc: 0, out: #"{"items": []}"#, err: "removing undecryptable credentials")
        XCTAssertThrowsError(try gws(r0).fetch())
    }

    func testLargeStdoutNoPipeDeadlock() throws {
        // > 64 KB on BOTH pipes from a real child: a naive waitUntilExit-then-read deadlocks.
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcs-big-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let script = dir.appendingPathComponent("gws")
        let items = (0..<3000).map { "{\"id\": \"e\($0)\", \"summary\": \"padding padding padding\"}" }.joined(separator: ",")
        try "{\"items\": [\(items)]}".write(to: dir.appendingPathComponent("out.json"), atomically: true, encoding: .utf8)
        try """
        #!/bin/sh
        i=0; while [ $i -lt 3000 ]; do echo "stderr noise line $i padding padding" >&2; i=$((i+1)); done
        cat '\(dir.path)/out.json'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let got = try Gws(path: script.path, runner: ProcessGwsRunner(), log: { _ in }).fetch()
        XCTAssertEqual(got?.count, 3000)
    }

    func script(_ body: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("mcs-\(UUID())")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = dir.appendingPathComponent("gws")
        try "#!/bin/sh\n\(body)\n".write(to: f, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: f.path)
        return dir
    }

    func testProcessRunnerTimeoutKills() throws {
        // The child records its pid and whether it got SIGTERM; it must be dead on return.
        // Generous timeouts: spawning a fresh /bin/sh script here can take >1 s (endpoint scanning).
        // Deflake (traced 2026-10-06): with `sleep 30 & wait`, /bin/sh (bash 3.2) intermittently
        // (~1 in 4) exited 0 from `wait` WITHOUT running the TERM trap. The child now blocks in a
        // builtin-only loop (no fork, no `wait`), so a pending trap runs at the next command
        // boundary, deterministically and well inside the 0.5 s SIGTERM->SIGKILL grace.
        let dir = try script("D=$(dirname \"$0\")\ntrap 'echo term > \"$D/term\"; exit 0' TERM\necho $$ > \"$D/pid\"\nwhile :; do :; done")
        let t0 = Date()
        let r = ProcessGwsRunner().run(executable: dir.appendingPathComponent("gws").path, args: [],
                                       env: Gws.buildEnv(), timeout: 3)
        guard case .timedOut = r else { return XCTFail("\(r)") }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 4.3)
        let pid = pid_t(try String(contentsOf: dir.appendingPathComponent("pid"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines))!
        XCTAssertEqual(kill(pid, 0), -1, "child still alive after timeout")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dir.appendingPathComponent("term").path),
                      "child was SIGTERMed")
    }

    func testDrainHonorsTimeoutAndKeepsOutputWhenDescendantHoldsPipes() throws {
        // codex P2: child exits, a grandchild keeps the pipes open; the old drain blocked ~5 s
        // then returned EMPTY output, losing the credential-deletion warning.
        let dir = try script("sleep 12 &\necho 'Warning: removing undecryptable credentials file' >&2\necho '{\"items\": []}'\nexit 0")
        let t0 = Date()
        let r = ProcessGwsRunner().run(executable: dir.appendingPathComponent("gws").path, args: [],
                                       env: Gws.buildEnv(), timeout: 3)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 4.5, "overall timeout is authoritative")
        guard case let .exited(status, out, err) = r else { return XCTFail("\(r)") }
        XCTAssertEqual(status, 0)
        XCTAssertTrue(String(decoding: err, as: UTF8.self).contains(Gws.destructive))
        XCTAssertTrue(String(decoding: out, as: UTF8.self).contains("items"))
    }

    func testProcessRunnerSigkillsChildIgnoringSigterm() throws {
        // codex P3: a child that ignores SIGTERM must still be dead on return (SIGKILL path).
        let dir = try script("trap '' TERM\necho $$ > \"$(dirname \"$0\")/pid\"\nwhile :; do sleep 1; done")
        let t0 = Date()
        let r = ProcessGwsRunner().run(executable: dir.appendingPathComponent("gws").path, args: [],
                                       env: Gws.buildEnv(), timeout: 3)
        guard case .timedOut = r else { return XCTFail("\(r)") }
        XCTAssertLessThan(Date().timeIntervalSince(t0), 4.8)
        let pid = pid_t(try String(contentsOf: dir.appendingPathComponent("pid"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines))!
        let alive = kill(pid, 0) == 0
        if alive { kill(pid, SIGKILL) }
        XCTAssertFalse(alive, "SIGTERM-ignoring child still alive after timeout")
    }

    func testDrainSharesDeadlineWhenParentExitsLate() throws {
        // codex P3: the parent exits ~2 s (cold-start margin) BEFORE the deadline while a descendant holds both
        // pipes; the drain must use the REMAINING time, not a fresh full timeout.
        let dir = try script("sleep 20 &\nsleep 3\necho '{\"items\": []}'\nexit 0")
        let t0 = Date()
        let r = ProcessGwsRunner().run(executable: dir.appendingPathComponent("gws").path, args: [],
                                       env: Gws.buildEnv(), timeout: 5)
        let dt = Date().timeIntervalSince(t0)
        guard case let .exited(status, out, _) = r else { return XCTFail("\(r) (slow sh cold start?)") }
        XCTAssertEqual(status, 0)
        XCTAssertTrue(String(decoding: out, as: UTF8.self).contains("items"))
        XCTAssertLessThan(dt, 5.0 + 1.0, "drain got a fresh timeout instead of the shared deadline")
    }

    func testInvalidUTF8ByteDoesNotFailPoll() throws {
        // codex P2: Python decodes with errors="replace"; one bad byte must not drop the poll.
        var out = Data(#"{"items": [{"id": "a", "summary": "caf"#.utf8)
        out.append(0xFF)
        out.append(Data(#""}]}"#.utf8))
        let r = FakeRunner(result: .exited(status: 0, stdout: out, stderr: Data()))
        let got = try gws(r).fetch()
        XCTAssertEqual(got?.map { $0.id }, ["a"])
        XCTAssertEqual(got?.first?.summary, "caf\u{FFFD}")
    }
}
