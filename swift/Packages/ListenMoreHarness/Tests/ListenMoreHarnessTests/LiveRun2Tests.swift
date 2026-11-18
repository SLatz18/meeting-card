import XCTest
import ListenMoreCore
@testable import ListenMoreHarness

/// Fixes from the second live run (1b435dc4 on the box).
final class LiveRun2Tests: XCTestCase {
    let config = try! ListenMoreConfig.builtIn()

    /// mute-unmute with the live run's clip lengths for a2 and y2 (TTS made y2 end before a2 does).
    func muteRecord() throws -> RunRecord {
        let s = Scenarios.muteUnmute
        var shapes = SyntheticVoice.shapes(s)
        shapes["a2"] = ClipShape(lead: 0, voiced: 8.05, total: 8.05)
        shapes["y2"] = ClipShape(lead: 0, voiced: 5.35, total: 5.35)
        let t = try Timeline.realize(s, shapes: shapes)
        var r = RunRecord(scenario: s, mode: .live, timeline: t, config: config)
        r.applied = t.controls.map { ($0.control.kind, $0.t) }
        return r
    }

    /// mute-unmute's muted You line disputes Them's ("...the database is the risky part..."). A Them
    /// segment holding just those words ties on word share with the muted line, which no transcriber
    /// should hear: the tie goes to Them's line, so it isn't a wrong attribution.
    func testTieGoesToTheLineThatCouldBeHeard() throws {
        var r = try muteRecord()
        let a2 = r.timeline.line("a2")!, y2 = r.timeline.line("y2")!
        XCTAssertTrue(r.appliedWindows(.mute, .unmute).contains { $0.contains(y2.start) && $0.contains(y2.end) })
        let end = y2.end - 0.4
        XCTAssertTrue(end > a2.start && end < a2.end)
        r.sockets.segments = [TranscribedSegment(stream: .call, committedAt: end + 0.2, transcribedAt: end + 0.9,
                                                 text: "the database is the risky part")]
        let sp = Scoring.speakers(r)
        XCTAssertEqual(sp.total, 1)
        XCTAssertEqual(sp.correct, 1, sp.mismatches.joined(separator: "; "))
        XCTAssertFalse(Scoring.reachableLines(r).contains { $0.line.id == "y2" })
        XCTAssertEqual(Scoring.line(for: r.sockets.segments[0], lines: r.timeline.lines, hangover: 0.2)?.line.id, "y2",
                       "without the preference, the tie went to the muted line")
    }

    /// The muted You line's own words on the call stream mean You's audio leaked onto Them's
    /// transcriber while muted: a named mismatch, not a skipped segment.
    func testMutedLineOnTheCallStreamFails() throws {
        var r = try muteRecord()
        let y2 = r.timeline.line("y2")!
        r.sockets.segments = [TranscribedSegment(stream: .call, committedAt: y2.end - 1.0, transcribedAt: y2.end - 0.3,
                                                 text: "hold on I want to argue with that because I am not sure")]
        let sp = Scoring.speakers(r)
        XCTAssertEqual(sp.total, 1)
        XCTAssertEqual(sp.correct, 0)
        XCTAssertTrue(sp.mismatches.first?.contains("holds y2 (you)") == true, sp.mismatches.joined())
        XCTAssertTrue(sp.mismatches.first?.contains("spoken while muted or paused reached a transcriber") == true, sp.mismatches.joined())
        XCTAssertEqual(Checks.evaluate(r).check("speaker-id")?.passed, false)
    }

    /// A caption the host got but the caption feed never showed is a named mismatch, not a pass: the
    /// stream and the caption's speaker are right, the feed just doesn't have it.
    func testCaptionMissingFromTheFeedIsAMismatch() throws {
        var r = try muteRecord()
        let a1 = r.timeline.line("a1")!
        let text = "let me share where the migration stands before we decide anything"
        r.sockets.segments = [TranscribedSegment(stream: .call, committedAt: a1.end + 0.2, transcribedAt: a1.end + 0.8, text: text)]
        r.captions = [CaptionRecord(t: a1.end + 0.8, speaker: .others, text: text, isFinal: true)]
        r.captionViews = [CaptionView(t: a1.end + 0.8, rows: [.init(label: "Them", speaker: .others, text: text)])]
        XCTAssertEqual(Scoring.speakers(r).correct, 1, "shown in the feed: correct")
        r.captionViews = [CaptionView(t: a1.end + 0.8, rows: [.init(label: "Them", speaker: .others, text: "something else entirely")])]
        let missingRow = Scoring.speakers(r)
        XCTAssertEqual(missingRow.correct, 0)
        XCTAssertTrue(missingRow.mismatches.first?.contains("its caption is missing from the caption feed") == true, missingRow.mismatches.joined())
        r.captionViews = []
        XCTAssertEqual(Scoring.speakers(r).correct, 0, "no feed update at all for that caption")
    }

    /// A wrong attribution names the segment, so a live report says which one.
    func testMismatchIsNamed() throws {
        var r = try muteRecord()
        let y5 = r.timeline.line("y5")!
        r.sockets.segments = [TranscribedSegment(stream: .call, committedAt: y5.end + 0.2, transcribedAt: y5.end + 0.9,
                                                 text: "the rollback steps were written for the old setup")]
        let sp = Scoring.speakers(r)
        XCTAssertEqual(sp.correct, 0)
        XCTAssertEqual(sp.mismatches.count, 1)
        XCTAssertTrue(sp.mismatches[0].hasPrefix("call segment ending"), sp.mismatches[0])
        XCTAssertTrue(sp.mismatches[0].contains("holds y5 (you)"), sp.mismatches[0])
    }

    /// The interruption script's voiced frames (from line spans), with Them silent for `gapFrames`
    /// frames starting `after` seconds into You's cut-in.
    func interruptionFacts(gapFrames: Int, after: Double) throws -> (Timeline, CueOracle.Facts) {
        let s = Scenarios.interruption
        let t = try Timeline.realize(s, shapes: SyntheticVoice.shapes(s))
        let n = Int(t.duration / 0.02) + 1
        func voiced(_ stream: AudioStream) -> [Bool] {
            (0..<n).map { i in t.lines.contains { $0.line.voice.stream == stream && Double(i) * 0.02 >= $0.start && Double(i) * 0.02 < $0.end } }
        }
        var call = voiced(.call)
        let first = Int((t.line("y3")!.start + after) / 0.02)
        for k in first..<(first + gapFrames) { call[k] = false }
        return (t, .init(keyless: true, gptStopT: nil, mode: .live, callVoiced: call, micVoiced: voiced(.mic)))
    }

    func cutIn(gapFrames: Int, after: Double) throws -> ExpectedCue {
        let (t, facts) = try interruptionFacts(gapFrames: gapFrames, after: after)
        return try XCTUnwrap(CueOracle.expected(t, config: config, facts: facts).cues.first { $0.type == .interrupt })
    }

    /// The engine drops a cut-in when Them stop for longer than `LocalLayer.cutInMaxOthersGapS` before
    /// its opening overlap has built up; only then does the talk-over rule get to raise the red cue.
    func testTalkOverAlternativeFollowsTheEnginesGapTolerance() throws {
        XCTAssertEqual(LocalLayer.cutInMaxOthersGapS, 0.16, accuracy: 1e-9)
        XCTAssertNil(try cutIn(gapFrames: 0, after: 0.2).alternative, "Them talk straight through")
        XCTAssertNil(try cutIn(gapFrames: 8, after: 0.2).alternative, "0.16 s: within the tolerance")
        let over = try cutIn(gapFrames: 9, after: 0.2)
        XCTAssertEqual(over.alternative?.type, .talkOver, "0.18 s: the engine drops the cut-in")
        XCTAssertNil(try cutIn(gapFrames: 25, after: 1.0).alternative, "a pause after 0.6 s of overlap has built up changes nothing")
    }

    /// The pause You start in is allowed `cut_in_onset_gap_ms` (0.3 s) from You's onset, as in the engine:
    /// Them silent from two frames before y3's start (their speaking tail is over by the time You's VAD
    /// confirms) for 15 frames past it leave the cut-in alone; 16 frames offer talk-over.
    func testTalkOverAlternativeFollowsTheOnsetGapTolerance() throws {
        XCTAssertEqual(config.local.cutInOnsetGapMs, 300)
        func cutIn(onsetGapFrames: Int) throws -> ExpectedCue {
            let (t, facts0) = try interruptionFacts(gapFrames: 0, after: 0)
            var facts = facts0
            let first = Int((t.line("y3")!.start / 0.02).rounded())
            for k in (first - 2)..<(first + onsetGapFrames) { facts.callVoiced[k] = false }
            return try XCTUnwrap(CueOracle.expected(t, config: config, facts: facts).cues.first { $0.type == .interrupt })
        }
        XCTAssertNil(try cutIn(onsetGapFrames: 15).alternative, "0.30 s from the onset: within the tolerance")
        XCTAssertEqual(try cutIn(onsetGapFrames: 16).alternative?.type, .talkOver, "0.32 s: the engine drops the cut-in")
    }

    /// Them count as speaking for `LocalLayer.speakingTailS` after their last voiced frame, and the cut-in
    /// starts once You's VAD has confirmed (two frames by default). Their last voiced frame one frame
    /// before You's start is still inside that tail, so the pause that follows is a later one (0.16 s, 12
    /// quiet frames being 0.24 s); with two frames between, You's start lands in the pause and the same
    /// 0.24 s of quiet runs 0.20 s from it, inside the onset tolerance.
    func testTalkOverAlternativeCountsTheEnginesSpeakingTail() throws {
        XCTAssertEqual(config.vad.onsetFrames, 2)
        func cutIn(framesBeforeStart back: Int, quietFrames: Int) throws -> ExpectedCue {
            let (t, facts0) = try interruptionFacts(gapFrames: 0, after: 0)
            var facts = facts0
            let first = Int((t.line("y3")!.start / 0.02).rounded())
            for k in (first - back)..<(first - back + quietFrames) { facts.callVoiced[k] = false }
            return try XCTUnwrap(CueOracle.expected(t, config: config, facts: facts).cues.first { $0.type == .interrupt })
        }
        XCTAssertEqual(try cutIn(framesBeforeStart: 1, quietFrames: 12).alternative?.type, .talkOver, "still speaking at the onset: 0.24 s")
        XCTAssertNil(try cutIn(framesBeforeStart: 2, quietFrames: 12).alternative, "the onset lands in the pause: 0.20 s from it")
        XCTAssertNil(try cutIn(framesBeforeStart: 1, quietFrames: 8).alternative, "still speaking at the onset, 0.16 s: kept")
    }

    /// A line starting at or past the end of the known audio has no gaps to measure: (0, 0), not a read
    /// past the end of the voicing arrays.
    func testOpeningOverlapGapsPastTheEndOfTheAudioAreZero() {
        let voiced = Array(repeating: true, count: 10)
        let facts = CueOracle.Facts(keyless: true, gptStopT: nil, mode: .offline, callVoiced: voiced, micVoiced: voiced)
        for start in [0.18, 0.20, 1.0, 100.0] {
            let gaps = CueOracle.openingOverlapGaps(facts, from: start, until: start + 1.0, overlapS: 0.6, confirmFrames: 2)
            XCTAssertEqual(gaps.atOnset, 0, "from \(start)")
            XCTAssertEqual(gaps.later, 0, "from \(start)")
        }
    }

    /// The alternative is accepted only in its window after Them stop, and only where it was offered.
    func testTalkOverMatchesOnlyWhereOffered() throws {
        let (t, _) = try interruptionFacts(gapFrames: 0, after: 0)
        let talkOver = CueRecord(t: t.line("a1")!.end + 1.9, engineT: 0, type: .talkOver, level: nil, source: .local, latencyMs: 0)
        let offered = try cutIn(gapFrames: 13, after: 0.3)
        XCTAssertTrue(try XCTUnwrap(offered.alternative).window.contains(talkOver.t))
        XCTAssertTrue(CueOracle.match(expected: [offered], tolerated: [], actual: [talkOver]).passed)
        XCTAssertFalse(CueOracle.match(expected: [try cutIn(gapFrames: 0, after: 0)], tolerated: [], actual: [talkOver]).passed)
    }

    /// Only a cancel up to a second after an engine stop is the expected close on Pause; one before it isn't.
    func testCancelWindowIsAfterTheStopOnly() async throws {
        struct Cancelling: HTTPTransport {
            func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval) async throws -> (status: Int, body: Data) {
                throw URLError(.cancelled)
            }
        }
        var r = try muteRecord()
        r.origin = 100
        r.engineStops = [10]
        let clock = HarnessClock(.simulated)
        let http = MeteredHTTP(inner: Cancelling(), clock: clock)
        for t in [109.5, 110.4] {
            clock.advance(to: t)
            do { _ = try await http.post(url: URL(string: "https://example.invalid")!, headers: [:], body: Data(), timeout: 1) } catch {}
        }
        let judge = try XCTUnwrap(Harness.costEntries(Checks.evaluate(r), record: r, http: http).first { $0.kind == "judge" })
        XCTAssertEqual(judge.fields["cancelled_at_engine_stop"], 1)
        XCTAssertEqual(judge.fields["cancelled_otherwise"], 1)
        XCTAssertEqual(judge.fields["failed_calls"], 0)
    }

    /// A judge call cancelled when the engine stops (Pause) is counted as cancelled, not failed.
    func testCancelledJudgeCallIsNotAFailure() async {
        struct Cancelling: HTTPTransport {
            func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval) async throws -> (status: Int, body: Data) {
                throw URLError(.cancelled)
            }
        }
        let clock = HarnessClock(.simulated)
        clock.advance(to: 12.5)
        let http = MeteredHTTP(inner: Cancelling(), clock: clock)
        do { _ = try await http.post(url: URL(string: "https://example.invalid")!, headers: [:], body: Data(), timeout: 1) } catch {}
        XCTAssertEqual(http.calls, 1)
        XCTAssertEqual(http.failures, [])
        XCTAssertEqual(http.cancelled, [12.5])
        XCTAssertTrue(MeteredHTTP.isCancellation(CancellationError()))
        XCTAssertFalse(MeteredHTTP.isCancellation(URLError(.timedOut)))
    }
}
