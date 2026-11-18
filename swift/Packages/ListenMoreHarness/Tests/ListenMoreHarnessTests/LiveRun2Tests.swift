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
    /// heard: it must match Them's line, not count as a wrong attribution.
    func testMutedLineIsNoCandidateForASegment() throws {
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
                       "with the muted line as a candidate, the tie went to it")
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

    /// When Them's own audio pauses longer than the cut-in rule tolerates during the opening overlap,
    /// the talk-over rule may raise the red cue instead: the oracle accepts it, in a window after Them
    /// stop. Without such a pause only an interrupt fits.
    func testTalkOverIsTheAlternativeWhenThemPauseInTheOpeningOverlap() throws {
        let s = Scenarios.interruption
        let t = try Timeline.realize(s, shapes: SyntheticVoice.shapes(s))
        let y3 = t.line("y3")!, a1 = t.line("a1")!
        let frames = Int(t.duration / 0.02) + 1
        var voiced = [Bool](repeating: true, count: frames)
        func expected(_ v: [Bool]) throws -> ExpectedCue {
            try XCTUnwrap(CueOracle.expected(t, config: config, facts: .init(keyless: true, gptStopT: nil, mode: .live, callVoiced: v)).cues.first)
        }
        XCTAssertNil(try expected(voiced).alternative, "Them talk straight through")
        for i in Int((y3.start + 0.3) / 0.02)..<Int((y3.start + 0.56) / 0.02) { voiced[i] = false }
        let e = try expected(voiced)
        let alt = try XCTUnwrap(e.alternative)
        XCTAssertEqual(alt.type, .talkOver)
        let talkOver = CueRecord(t: a1.end + 1.9, engineT: 0, type: .talkOver, level: nil, source: .local, latencyMs: 0)
        XCTAssertTrue(alt.window.contains(talkOver.t))
        XCTAssertTrue(CueOracle.match(expected: [e], tolerated: [], actual: [talkOver]).passed)
        XCTAssertFalse(CueOracle.match(expected: [try expected([Bool](repeating: true, count: frames))], tolerated: [], actual: [talkOver]).passed)
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
