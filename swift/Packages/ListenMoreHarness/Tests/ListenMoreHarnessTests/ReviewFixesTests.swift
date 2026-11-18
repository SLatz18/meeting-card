import XCTest
import ListenMoreCore
@testable import ListenMoreHarness
#if canImport(Glibc)
import Glibc
#endif

/// Tests for the review's required items and nits: live windows, keep-nothing, the cost log on a live
/// error, the audio-signature guard, and the socket client's SIGPIPE handling.
final class ReviewFixesTests: XCTestCase {
    let config = try! ListenMoreConfig.builtIn()

    func record(_ s: Scenario, mode: Mode) throws -> RunRecord {
        let t = try Timeline.realize(s, shapes: SyntheticVoice.shapes(s))
        var r = RunRecord(scenario: s, mode: mode, timeline: t, config: config)
        r.applied = t.controls.map { ($0.control.kind, $0.t) }
        return r
    }

    func ingest(_ t: Double, _ stream: AudioStream = .mic) -> MeteredEngine.Ingest { .init(t: t, stream: stream, samples: 320) }

    // MARK: live mute and pause windows (item 6)

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

    // MARK: keep-nothing (item 7)

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

    // MARK: the cost log survives a live error (item 8)

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
        XCTAssertTrue(results.contains("first"), "the finished scenario is in the table")
        for n in names {
            XCTAssertFalse(try String(contentsOf: out.appendingPathComponent(n), encoding: .utf8).contains(canary), n)
        }
    }

    // MARK: SIGPIPE (item 3)

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
