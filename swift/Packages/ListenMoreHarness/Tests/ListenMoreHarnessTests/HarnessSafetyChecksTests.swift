import XCTest
import ListenMoreCore
@testable import ListenMoreHarness
#if canImport(Glibc)
import Glibc
#endif

/// Safety and persistence checks: live mute and pause windows, keep-nothing and the run directory, the cost
/// log on a live error, the audio-signature guard, and the socket client's SIGPIPE handling.
final class HarnessSafetyChecksTests: XCTestCase {
    let config = try! ListenMoreConfig.builtIn()

    func record(_ s: Scenario, mode: Mode) throws -> RunRecord {
        let t = try Timeline.realize(s, shapes: SyntheticVoice.shapes(s))
        var r = RunRecord(scenario: s, mode: mode, timeline: t, config: config)
        r.applied = t.controls.map { ($0.control.kind, $0.t) }
        return r
    }

    func ingest(_ t: Double, _ stream: AudioStream = .mic) -> MeteredEngine.Ingest { .init(t: t, stream: stream, samples: 320) }

    // MARK: live mute and pause windows

    /// Live mode has no barrier: frames queued before Mute are still ingested and sent for a few
    /// milliseconds to tens of milliseconds after it. The window starts when the engine handled the
    /// control (frames) plus 0.5 s (transcriber traffic), so those frames are not a failure; later ones are.
    func testLiveMuteWindowStartsWhenTheEngineHandledMute() throws {
        var r = try record(Scenarios.muteUnmute, mode: .live)
        let mute = try XCTUnwrap(r.applied.first { $0.kind == .mute }?.t)
        r.engineMicMutes = [(mute + 0.04, true)]
        r.engineIngests = [ingest(mute + 0.02)]
        r.sockets.appends = [.init(t: mute + 0.3, stream: .mic, samples: 320, loud: true)]
        XCTAssertEqual(Checks.evaluate(r).check("muted: zero mic frames")?.passed, true, "frames queued before the engine handled Mute")

        var late = r
        late.engineIngests.append(ingest(mute + 0.1))
        XCTAssertEqual(Checks.evaluate(late).check("muted: zero mic frames")?.passed, false, "a frame after the engine handled Mute")

        var sent = r
        sent.sockets.appends.append(.init(t: mute + 0.8, stream: .mic, samples: 320, loud: true))
        XCTAssertEqual(Checks.evaluate(sent).check("muted: zero mic frames")?.passed, false, "an append more than 0.5 s after the engine handled Mute")
    }

    func testOfflineMuteWindowIsExact() throws {
        var r = try record(Scenarios.muteUnmute, mode: .offline)
        let mute = try XCTUnwrap(r.applied.first { $0.kind == .mute }?.t)
        r.engineMicMutes = [(mute, true)]
        r.engineIngests = [ingest(mute + 0.02)]
        XCTAssertEqual(Checks.evaluate(r).check("muted: zero mic frames")?.passed, false, "offline, the frame after Mute is already a failure")
    }

    func testLivePauseWindowStartsWhenTheEngineStopped() throws {
        var r = try record(Scenarios.pause, mode: .live)
        let pause = try XCTUnwrap(r.applied.first { $0.kind == .pause }?.t)
        r.engineStops = [pause + 0.05]
        r.engineStarts = [r.appliedWindows(.pause, .resume).first.map(\.upperBound) ?? 0]
        r.engineIngests = [ingest(pause + 0.02), ingest(pause + 0.03, .call)]
        r.sockets.appends = [.init(t: pause + 0.3, stream: .call, samples: 320, loud: true)]
        r.captions = [CaptionRecord(t: pause + 0.3, speaker: .others, text: "late", isFinal: true)]
        XCTAssertEqual(Checks.evaluate(r).check("paused: no frames, traffic or captions")?.passed, true)

        var after = r
        after.engineIngests.append(ingest(pause + 0.5))
        XCTAssertEqual(Checks.evaluate(after).check("paused: no frames, traffic or captions")?.passed, false)
    }

    /// A judge verdict (live `not_listening`) inside the unmute grace is the oracle's tolerated cue, not a
    /// false cue after Unmute; with the judge off the same cue is one.
    func testUnmuteGraceCheckSkipsTheCuesTheOracleTolerates() throws {
        var r = try record(Scenarios.muteUnmute, mode: .live)
        let unmute = try XCTUnwrap(r.applied.first { $0.kind == .unmute }?.t)
        let y4 = try XCTUnwrap(r.timeline.line("y4"))
        let t = y4.start + 1.5
        XCTAssertLessThanOrEqual(t, unmute + config.local.unmuteGraceS + 4)
        r.cues = [CueRecord(t: t, engineT: t, type: .notListening, level: nil, source: .gpt, latencyMs: 0)]
        r.judgeOn = true
        XCTAssertEqual(Checks.evaluate(r).check("unmute grace: no false cue")?.passed, true)
        r.judgeOn = false
        XCTAssertEqual(Checks.evaluate(r).check("unmute grace: no false cue")?.passed, false)
    }

    // MARK: keep-nothing

    func testKeepNothingFailsWhenARecorderFileExistsOrTheScriptTextIsOnDisk() throws {
        let s = Scenarios.silenceToStop
        XCTAssertFalse(s.saving)
        let clean = try record(s, mode: .offline)
        XCTAssertEqual(Checks.evaluate(clean).check("keep-nothing")?.passed, true)

        var file = clean
        file.recorderLastURL = URL(fileURLWithPath: "/tmp/Call 1.md")
        XCTAssertEqual(Checks.evaluate(file).check("keep-nothing")?.passed, false, "the recorder opened a file")

        var text = clean
        text.textLeaks = ["/home/x/Documents/notes.txt"]
        XCTAssertEqual(Checks.evaluate(text).check("keep-nothing")?.passed, false, "script text in a file outside the run dir")
    }

    func testTranscriptTextOutsideTheRunDirFailsASavingRun() throws {
        var r = try record(Scenarios.muteUnmute, mode: .offline)
        XCTAssertTrue(r.scenario.saving)
        let folder = URL(fileURLWithPath: "/tmp/run/transcripts")
        r.transcriptsFolder = folder
        r.storeWritten = [folder.appendingPathComponent("Call 1.md")]
        XCTAssertEqual(Checks.evaluate(r).check("transcript stays in the run dir")?.passed, true)
        r.textLeaks = ["/tmp/elsewhere/copy.md"]
        XCTAssertEqual(Checks.evaluate(r).check("transcript stays in the run dir")?.passed, false)
    }

    func testAuditFindsScriptTextInAnyNewFileAnywhereUnderItsRoots() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("lm-harness-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let run = root.appendingPathComponent("run", isDirectory: true)
        let other = root.appendingPathComponent("docs/deep", isDirectory: true)
        try fm.createDirectory(at: run, withIntermediateDirectories: true)
        try fm.createDirectory(at: other, withIntermediateDirectories: true)
        let audit = DiskAudit(roots: [root], exclude: run)
        try "My notes\nThanks, I WILL read it after lunch.\n".write(to: other.appendingPathComponent("notes.txt"), atomically: true, encoding: .utf8)
        try "unrelated".write(to: other.appendingPathComponent("other.txt"), atomically: true, encoding: .utf8)
        try "Thanks, I will read it after lunch.".write(to: run.appendingPathComponent("Call 1.md"), atomically: true, encoding: .utf8)
        let old = other.appendingPathComponent("old.md")
        try "Thanks, I will read it after lunch.".write(to: old, atomically: true, encoding: .utf8)
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(-3600)], ofItemAtPath: old.path)

        let found = audit.filesContaining(["thanks, i will read it after lunch.", "no such phrase"])
        XCTAssertEqual(found.map { URL(fileURLWithPath: $0).lastPathComponent }, ["notes.txt"],
                       "the new file outside the run dir only: not the run dir's own file, an old file or an unrelated one")
        XCTAssertEqual(audit.filesContaining([]), [])
    }

    // MARK: the run directory

    func offlineRun(_ scenarios: [Scenario], configure: (inout HarnessOptions) -> Void = { _ in }) async throws -> [ScenarioResult] {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("lm-harness-test-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: out) }
        var options = HarnessOptions(mode: .offline, scenarios: scenarios, outputDirectory: out, environment: [:])
        configure(&options)
        return try await Harness.run(options).results
    }

    static func shortScenario(_ name: String, saving: Bool) -> Scenario {
        Scenario(name: name, summary: "short exchange", lines: [
            Line("a1", .themA, "The draft is ready for a first look.", .at(0.3)),
            Line("y1", .you, "Thanks, I will read it after lunch.", .after("a1", gap: 1.0)),
        ], saving: saving, tail: 1.5)
    }

    /// A store that also drops a file next to its folder (in the run directory, which the audit skips and
    /// the harness wipes). Its writes go through the counting wrapper, which only sees the URLs it was given.
    final class SiblingWritingStore: TranscriptStore {
        private let inner = FileTranscriptStore()
        func prepare(folder: URL) throws { try inner.prepare(folder: folder) }
        func exists(_ url: URL) -> Bool { inner.exists(url) }
        func write(_ text: String, to url: URL) throws {
            try inner.write(text, to: url)
            let stray = url.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("stray.md")
            try inner.write(text, to: stray)
        }
        func remove(_ url: URL) throws { try inner.remove(url) }
    }

    @MainActor
    func testAStoreWritingNextToItsFolderFailsASavingRun() async throws {
        let scenario = Self.shortScenario("saves", saving: true)
        let clean = try await offlineRun([scenario])
        XCTAssertEqual(clean.first?.check("transcript stays in the run dir")?.passed, true, clean.first?.check("transcript stays in the run dir")?.detail ?? "")

        let bad = try await offlineRun([scenario]) { $0.transcriptStore = SiblingWritingStore() }
        let check = try XCTUnwrap(bad.first?.check("transcript stays in the run dir"))
        XCTAssertFalse(check.passed, "a file beside the transcripts folder")
        XCTAssertTrue(check.detail.contains("stray.md"), check.detail)
    }

    @MainActor
    func testAnythingInTheRunDirOfAKeepNothingRunIsNamed() async throws {
        let scenario = Self.shortScenario("keeps-nothing", saving: false)
        let clean = try await offlineRun([scenario])
        XCTAssertEqual(clean.first?.check("keep-nothing")?.passed, true, clean.first?.check("keep-nothing")?.detail ?? "")

        let beside = try await offlineRun([scenario]) { o in
            o.afterRun = { _, dir in try? "notes".write(to: dir.appendingPathComponent("notes.md"), atomically: true, encoding: .utf8) }
        }
        let a = try XCTUnwrap(beside.first?.check("keep-nothing"))
        XCTAssertFalse(a.passed)
        XCTAssertTrue(a.detail.contains("notes.md"), a.detail)

        let inside = try await offlineRun([scenario]) { o in
            o.afterRun = { _, dir in
                let folder = dir.appendingPathComponent("transcripts", isDirectory: true)
                try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try? "notes".write(to: folder.appendingPathComponent("Call 1.md"), atomically: true, encoding: .utf8)
            }
        }
        let b = try XCTUnwrap(inside.first?.check("keep-nothing"))
        XCTAssertFalse(b.passed, "a transcript in the folder of a run that saves nothing")
        XCTAssertTrue(b.detail.contains("transcripts/Call 1.md"), b.detail)
    }

    func testRunDirectoryRules() throws {
        func result(_ s: Scenario, _ entries: [String], check name: String) throws -> Bool {
            var r = try record(s, mode: .offline)
            r.runDirEntries = entries
            if s.saving {
                let folder = URL(fileURLWithPath: "/tmp/run/transcripts")
                r.transcriptsFolder = folder
                r.storeWritten = [folder.appendingPathComponent("Call 1.md")]
            }
            return try XCTUnwrap(Checks.evaluate(r).check(name)).passed
        }
        let keep = Scenarios.silenceToStop, save = Scenarios.muteUnmute
        XCTAssertTrue(try result(keep, [], check: "keep-nothing"))
        XCTAssertFalse(try result(keep, ["transcripts"], check: "keep-nothing"), "keep-nothing: the run directory is empty")
        XCTAssertFalse(try result(keep, ["transcripts", "transcripts/Call 1.md"], check: "keep-nothing"))
        XCTAssertFalse(try result(keep, ["other"], check: "keep-nothing"))
        XCTAssertFalse(try result(keep, ["!symlink: transcripts"], check: "keep-nothing"))
        XCTAssertFalse(try result(keep, ["!unreadable: ."], check: "keep-nothing"))
        XCTAssertTrue(try result(save, ["transcripts", "transcripts/Call 1.md"], check: "transcript stays in the run dir"))
        XCTAssertFalse(try result(save, ["transcripts", "transcripts/Call 1.md", "stray.md"], check: "transcript stays in the run dir"))
        XCTAssertFalse(try result(save, ["transcripts", "!symlink: transcripts/x"], check: "transcript stays in the run dir"))
        XCTAssertFalse(try result(save, ["!symlink: transcripts"], check: "transcript stays in the run dir"))
        XCTAssertFalse(try result(save, ["transcripts", "!unreadable: transcripts/sub"], check: "transcript stays in the run dir"))
    }

    // MARK: the run directory listing

    func makeTempDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lm-harness-test-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A symlink is listed under a marker and never followed, so one named `transcripts` doesn't pass as the
    /// transcripts folder and what it points at isn't walked.
    func testASymlinkInTheRunDirectoryIsFlaggedAndNotFollowed() throws {
        let root = try makeTempDir()
        let target = try makeTempDir()
        try "secret".write(to: target.appendingPathComponent("inside.md"), atomically: true, encoding: .utf8)
        let run = RunDirectory(url: root)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("transcripts"), withDestinationURL: target)
        XCTAssertEqual(run.entries(), ["!symlink: transcripts"], "listed as a symlink, target not walked")

        let folder = root.appendingPathComponent("real", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("x"), withDestinationURL: target.appendingPathComponent("inside.md"))
        XCTAssertEqual(run.entries(), ["!symlink: real/x", "!symlink: transcripts", "real"])
    }

    func testAPlainTreeIsListedRecursively() throws {
        let root = try makeTempDir()
        let sub = root.appendingPathComponent("transcripts/deep", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try "x".write(to: sub.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try "x".write(to: root.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
        XCTAssertEqual(RunDirectory(url: root).entries(), [".hidden", "transcripts", "transcripts/deep", "transcripts/deep/a.md"])
    }

    /// A missing run directory is a failure, not an empty one.
    func testAMissingRunDirectoryDoesNotListAsEmpty() throws {
        let gone = FileManager.default.temporaryDirectory.appendingPathComponent("lm-harness-test-missing-\(UUID().uuidString)")
        XCTAssertEqual(RunDirectory(url: gone).entries(), ["!unreadable: ."])
    }

    /// A folder the walk can't list is marked, not skipped (injected lister: works as root too).
    func testAFolderThatCannotBeListedIsMarked() throws {
        let root = try makeTempDir()
        try FileManager.default.createDirectory(at: root.appendingPathComponent("transcripts/locked"), withIntermediateDirectories: true)
        let run = RunDirectory(url: root)
        let entries = run.entries { path in
            path.hasSuffix("/locked") ? nil : try? FileManager.default.contentsOfDirectory(atPath: path)
        }
        XCTAssertEqual(entries, ["!unreadable: transcripts/locked", "transcripts", "transcripts/locked"])
    }

    /// The same on the real filesystem, where a permission error needs a user that can't read past a mode 000
    /// folder: root (the CI container) can, so it skips.
    func testAnUnreadableFolderOnDiskIsMarked() throws {
        try XCTSkipIf(geteuid() == 0, "running as root: mode 000 doesn't stop the listing, so a real permission error can't be made (the injected-lister test covers the logic)")
        let root = try makeTempDir()
        let locked = root.appendingPathComponent("transcripts/locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try "x".write(to: locked.appendingPathComponent("a.md"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        addTeardownBlock { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        XCTAssertEqual(RunDirectory(url: root).entries(), ["!unreadable: transcripts/locked", "transcripts", "transcripts/locked"])
    }

    // MARK: audio signature (nit)

    func testHeifAndAvifImagesAreNotAudio() {
        func header(_ brand: String) -> Data { Data([0, 0, 0, 0x18] + Array("ftyp".utf8) + Array(brand.utf8)) }
        for brand in ["heic", "heix", "mif1", "avif", "avis"] {
            XCTAssertFalse(DiskAudit.isAudioHeader(header(brand)), "\(brand) is an image")
        }
        for brand in ["M4A ", "M4B ", "isom", "mp42", "3gp4"] {
            XCTAssertTrue(DiskAudit.isAudioHeader(header(brand)), "\(brand) stays flagged")
        }
    }

    // MARK: the cost log survives a live error

    final class FlakyOpenAI: HTTPTransport, @unchecked Sendable {
        private let inner = LiveWiringTests.FakeOpenAI()
        private let lock = NSLock()
        private var speech = 0
        let okSpeechCalls: Int

        init(okSpeechCalls: Int) { self.okSpeechCalls = okSpeechCalls }

        func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval) async throws -> (status: Int, body: Data) {
            if url.path.hasSuffix("/audio/speech") {
                let n = lock.withLock { () -> Int in
                    speech += 1
                    return speech
                }
                if n > okSpeechCalls { throw HarnessError.tts(500) }
            }
            return try await inner.post(url: url, headers: headers, body: body, timeout: timeout)
        }
    }

    /// The failure can come before the scenario runs: a throw while loading its config or creating its run
    /// directory still writes what was scored and spent so far.
    @MainActor
    func testACostLogIsWrittenWhenTheNextScenarioCannotCreateItsRunDirectory() async throws {
        let first = Self.shortScenario("first", saving: false)
        let second = Self.shortScenario("second", saving: false)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("lm-harness-test-\(UUID().uuidString)", isDirectory: true)
        let blocker = FileManager.default.temporaryDirectory.appendingPathComponent("lm-harness-test-blocker-\(UUID().uuidString)")
        defer {
            try? FileManager.default.removeItem(at: out)
            try? FileManager.default.removeItem(at: blocker)
        }
        var options = HarnessOptions(mode: .offline, scenarios: [first, second], outputDirectory: out, environment: [:])
        FileManager.default.createFile(atPath: blocker.path, contents: Data())
        options.runDirectoryParent = { scenario in scenario.name == "first" ? FileManager.default.temporaryDirectory : blocker }
        do {
            _ = try await Harness.run(options)
            XCTFail("the second scenario's run directory cannot be created")
        } catch {}
        let cost = try String(contentsOf: out.appendingPathComponent("cost-log.jsonl"), encoding: .utf8)
        XCTAssertTrue(cost.contains("\"first\""), "the first scenario's entries are logged: \(cost)")
        let results = try String(contentsOf: out.appendingPathComponent("results.md"), encoding: .utf8)
        XCTAssertTrue(results.contains("INCOMPLETE: second stopped"), results)
        XCTAssertTrue(results.contains("| first |"), results)
        XCTAssertFalse(results.contains(blocker.path), "no file path in the output files")
        XCTAssertFalse(results.contains(blocker.lastPathComponent), "no file path in the output files")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: out.appendingPathComponent("results.json"))) as? [String: Any])
        XCTAssertEqual(json["incomplete"] as? Bool, true, "results.json says the run is incomplete")
        XCTAssertEqual((json["scenarios"] as? [Any])?.count, 1)
    }

    /// A scenario whose config cannot be loaded stops the run the same way, without the config error's detail
    /// in the output files.
    @MainActor
    func testAScenarioConfigThatCannotLoadStillWritesTheOutputs() async throws {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("lm-harness-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: out) }
        var options = HarnessOptions(mode: .offline, scenarios: [Self.shortScenario("only", saving: false)], outputDirectory: out, environment: [:])
        options.engineOverrides = ["gpt": ["store": true]]
        do {
            _ = try await Harness.run(options)
            XCTFail("the engine config is invalid")
        } catch {
            XCTAssertEqual(error as? ConfigError, .invalid("gpt.store must be false"))
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
        XCTAssertEqual(names, ["cost-log.jsonl", "results.json", "results.md"])
        let results = try String(contentsOf: out.appendingPathComponent("results.md"), encoding: .utf8)
        XCTAssertTrue(results.contains("INCOMPLETE: only stopped: config error (invalid)"), results)
        XCTAssertFalse(results.contains("gpt.store"), "the config error's detail stays out of the output files")
        let json = try String(contentsOf: out.appendingPathComponent("results.json"), encoding: .utf8)
        XCTAssertTrue(json.contains("\"incomplete\" : true"), json)
        XCTAssertFalse(json.contains("gpt.store"))
    }

    @MainActor
    func testACostLogAndPartialResultsAreWrittenWhenALaterScenarioFails() async throws {
        let first = Scenario(name: "first", summary: "short exchange", lines: [
            Line("a1", .themA, "The draft is ready for a first look.", .at(0.3)),
            Line("y1", .you, "Thanks, I will read it after lunch.", .after("a1", gap: 1.0)),
        ], tail: 1.5)
        let second = Scenario(name: "second", summary: "another exchange", lines: [
            Line("a1", .themA, "The numbers came in a little higher than planned.", .at(0.3)),
            Line("y1", .you, "Then let us look at them together tomorrow.", .after("a1", gap: 1.0)),
        ], tail: 1.5)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("lm-harness-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: out) }
        let clock = HarnessClock(.wall)
        let backend = LiveBackend(http: FlakyOpenAI(okSpeechCalls: 2), webSocket: ScriptedRealtime(clock: clock, sampleRate: 24000))
        let canary = LiveWiringTests.canary
        do {
            _ = try await Harness.run(HarnessOptions(mode: .live, scenarios: [first, second], outputDirectory: out,
                                                     environment: [Harness.keyVariable: canary], liveBackend: backend))
            XCTFail("the second scenario's TTS failure should stop the run")
        } catch {
            XCTAssertEqual(error as? HarnessError, .tts(500))
        }
        let names = try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
        XCTAssertEqual(names, ["cost-log.jsonl", "results.json", "results.md"])
        let cost = try String(contentsOf: out.appendingPathComponent("cost-log.jsonl"), encoding: .utf8)
        XCTAssertTrue(cost.contains("\"tts\""), "the first scenario's TTS spend is logged: \(cost)")
        XCTAssertTrue(cost.contains("\"first\""), cost)
        let results = try String(contentsOf: out.appendingPathComponent("results.md"), encoding: .utf8)
        XCTAssertTrue(results.contains("INCOMPLETE: second stopped"), results)
        XCTAssertTrue(results.contains("| first |"), "the finished scenario has its row in the table: \(results)")
        XCTAssertFalse(results.contains("| second |"), "the failed scenario has no row")
        for n in names {
            XCTAssertFalse(try String(contentsOf: out.appendingPathComponent(n), encoding: .utf8).contains(canary), n)
        }
    }

    // MARK: SIGPIPE

    #if canImport(CHarnessTLS)
    /// Creating the socket connector makes the process ignore SIGPIPE, so a write to a peer that already
    /// closed fails with EPIPE instead of killing the process (status 141).
    func testSocketConnectorIgnoresSIGPIPE() {
        _ = signal(SIGPIPE, SIG_DFL)
        _ = SocketWebSocketConnector()
        let previous = signal(SIGPIPE, SIG_IGN)
        XCTAssertEqual(previous.map { unsafeBitCast($0, to: Int.self) } ?? 0, 1, "SIGPIPE is set to SIG_IGN")
    }
    #endif
}
