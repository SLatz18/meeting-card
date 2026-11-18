import XCTest
import ListenMoreCore
@testable import ListenMoreHarness
#if canImport(Glibc)
import Glibc
#endif

/// Review follow-ups: line-scoped tolerance, scrubbed stdout, one watchdog per counter, crash cleanup,
/// per-line missed-question timing offline, caption labels in speaker ID.
final class ReviewFollowUpTests: XCTestCase {
    let config = try! ListenMoreConfig.builtIn()

    /// Offline synthetic speech is one segment per line, so the missed-question cue is due at the
    /// reply's end; live (and espeak) speech is transcribed in pieces, so it can come from the deciding word.
    func testMissedQuestionWindowIsPerLineOfflineAndPerSegmentLive() throws {
        let s = Scenarios.missedQuestion
        let t = try Timeline.realize(s, shapes: SyntheticVoice.shapes(s))
        let y2 = t.line("y2")!
        let offline = try XCTUnwrap(CueOracle.expected(t, config: config, facts: .init(keyless: false, gptStopT: nil, mode: .offline)).cues.first)
        XCTAssertEqual(offline.window.lowerBound, y2.end - 0.3, accuracy: 1e-9)
        XCTAssertEqual(offline.window.upperBound, y2.end + 1.0, accuracy: 1e-9)
        let espeak = try XCTUnwrap(CueOracle.expected(t, config: config, facts: .init(keyless: false, gptStopT: nil, mode: .offline,
                                                                                     segmentedSpeech: true)).cues.first)
        XCTAssertLessThan(espeak.window.lowerBound, y2.end - 2)
        let live = try XCTUnwrap(CueOracle.expected(t, config: config, facts: .init(keyless: false, gptStopT: nil, mode: .live)).cues.first)
        XCTAssertLessThan(live.window.lowerBound, y2.end - 2)
    }

    /// Speaker ID checks the stream, the caption's speaker and the label the caption feed showed: a
    /// caption labelled with the other side's name fails even when the socket was right.
    func testSpeakerIDChecksCaptionSpeakerAndLabel() throws {
        let s = Scenario(name: "t", summary: "", lines: [
            Line("a", .themA, "the draft is ready for a first look", .at(0), seconds: 3),
            Line("y", .you, "thanks I will read it after lunch", .after("a", gap: 1), seconds: 3),
        ])
        let timeline = try Timeline.realize(s, shapes: SyntheticVoice.shapes(s))
        var r = RunRecord(scenario: s, mode: .offline, timeline: timeline, config: config)
        let aEnd = timeline.line("a")!.end, yEnd = timeline.line("y")!.end
        r.sockets.segments = [
            TranscribedSegment(stream: .call, committedAt: aEnd + 0.2, transcribedAt: aEnd + 0.2, text: "the draft is ready for a first look"),
            TranscribedSegment(stream: .mic, committedAt: yEnd + 0.2, transcribedAt: yEnd + 0.2, text: "thanks I will read it after lunch"),
        ]
        func show(themLabel: String, youSpeaker: Speaker, youLabel: String) {
            r.captions = [CaptionRecord(t: aEnd + 0.2, speaker: .others, text: "the draft is ready for a first look", isFinal: true),
                          CaptionRecord(t: yEnd + 0.2, speaker: youSpeaker, text: "thanks I will read it after lunch", isFinal: true)]
            r.captionViews = [
                CaptionView(t: aEnd + 0.2, rows: [.init(label: themLabel, speaker: .others, text: "the draft is ready for a first look")]),
                CaptionView(t: yEnd + 0.2, rows: [.init(label: themLabel, speaker: .others, text: "the draft is ready for a first look"),
                                                  .init(label: youLabel, speaker: youSpeaker, text: "thanks I will read it after lunch")]),
            ]
        }
        show(themLabel: "Them", youSpeaker: .me, youLabel: "You")
        XCTAssertEqual(Scoring.speakers(r).correct, 2)
        show(themLabel: "Them", youSpeaker: .me, youLabel: "Them")
        XCTAssertEqual(Scoring.speakers(r).correct, 1, "right socket and speaker, wrong label shown")
        show(themLabel: "Them", youSpeaker: .others, youLabel: "Them")
        XCTAssertEqual(Scoring.speakers(r).correct, 1, "the caption carried the wrong speaker")
        r.captions = []
        r.captionViews = []
        let bare = Scoring.speakers(r)
        XCTAssertEqual(bare.correct, 2)
        XCTAssertEqual(bare.uncaptioned, 2, "no caption to check: stream only, and reported")
    }

    /// Tolerance is tied to the line that justifies it: a cue of a tolerated type elsewhere is false.
    func testToleranceIsScopedToALine() {
        let tol = Tolerance(type: .notListening, window: 10...16, reason: "")
        XCTAssertTrue(tol.covers(CueRecord(t: 12, engineT: 12, type: .notListening, level: nil, source: .gpt, latencyMs: 0)))
        let m = CueOracle.match(expected: [], tolerated: [tol], actual: [
            CueRecord(t: 12, engineT: 12, type: .notListening, level: nil, source: .gpt, latencyMs: 0),
            CueRecord(t: 30, engineT: 30, type: .notListening, level: nil, source: .gpt, latencyMs: 0),
            CueRecord(t: 12, engineT: 12, type: .interrupt, level: nil, source: .local, latencyMs: 0),
        ])
        XCTAssertEqual(m.tolerated.count, 1)
        XCTAssertEqual(m.falseCues.map(\.t), [30, 12])
    }

    /// The live mute-unmute scenario tolerates no interrupt anywhere, so a cut-in inside the unmute
    /// grace is always a false cue; judge tolerance covers only not_listening after replies.
    func testNoToleranceHidesAnInterruptAfterUnmute() throws {
        let t = try Timeline.realize(Scenarios.muteUnmute, shapes: SyntheticVoice.shapes(Scenarios.muteUnmute))
        let live = CueOracle.expected(t, config: config, facts: .init(keyless: false, gptStopT: nil, mode: .live, judgeOn: true))
        XCTAssertFalse(live.tolerated.contains { $0.type == .interrupt })
        XCTAssertTrue(live.tolerated.allSatisfy { $0.type == .notListening })
        let unmute = t.times(.unmute)[0]
        let m = CueOracle.match(expected: live.cues, tolerated: live.tolerated,
                                actual: [CueRecord(t: unmute + 1.5, engineT: 0, type: .interrupt, level: nil, source: .local, latencyMs: 0)])
        XCTAssertEqual(m.falseCues.count, 1)
        let off = CueOracle.expected(t, config: config, facts: .init(keyless: false, gptStopT: nil, mode: .live, judgeOn: false))
        XCTAssertTrue(off.tolerated.isEmpty, "judge off: nothing tolerated")
    }

    /// stdout and stderr lines go through the key scrubber.
    func testStdoutScrubber() {
        let env = [Harness.keyVariable: "sk-scrub-test-0123456789"]
        XCTAssertEqual(Harness.scrub("bad arg sk-scrub-test-0123456789!", environment: env), "bad arg [REDACTED]!")
        XCTAssertEqual(Harness.scrub("nothing here", environment: [:]), "nothing here")
    }

    /// One watchdog serves every waiter: waits resolve on add, time out on their own deadline, and the
    /// watchdog stops when nobody is waiting.
    func testAsyncCounterWaitsAndTimesOut() async {
        let c = AsyncCounter()
        async let reached = c.wait(atLeast: 1, timeout: 5)
        async let timedOut = c.wait(atLeast: 100, timeout: 0.3)
        try? await Task.sleep(nanoseconds: 50_000_000)
        c.add()
        let started = Date()
        let (a, b) = await (reached, timedOut)
        XCTAssertTrue(a)
        XCTAssertFalse(b)
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
        var results: [Bool] = []
        for i in 0..<500 {
            c.add()
            results.append(await c.wait(atLeast: i + 2, timeout: 5))
        }
        XCTAssertTrue(results.allSatisfy { $0 })
    }

    /// Run folders left by a crashed harness are removed; a live harness's folder and anything else are kept.
    func testSweepRemovesOnlyDeadRunFolders() throws {
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("lm-sweep-test-\(UUID().uuidString)")
        defer { try? fm.removeItem(at: root) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/true")
        try p.run()
        p.waitUntilExit()
        let dead = "lm-harness-\(p.processIdentifier)-\(UUID().uuidString)"
        let alive = "lm-harness-\(getpid())-\(UUID().uuidString)"
        for name in [dead, alive, "lm-harness-out", "lm-harness-test-\(UUID().uuidString)", "lm-harness-12x-\(UUID().uuidString)"] {
            try fm.createDirectory(at: root.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        XCTAssertEqual(RunDirectory.sweepStale(in: root), 0, "a folder changed in the last five minutes is kept")
        XCTAssertEqual(RunDirectory.sweepStale(in: root, now: Date().addingTimeInterval(RunDirectory.sweepMinAgeS + 1)), 1)
        let left = Set(try fm.contentsOfDirectory(atPath: root.path))
        XCTAssertFalse(left.contains(dead))
        XCTAssertTrue(left.contains(alive))
        XCTAssertTrue(left.contains("lm-harness-out"), "the default output folder is never swept")
        XCTAssertEqual(left.count, 4)
    }
}
