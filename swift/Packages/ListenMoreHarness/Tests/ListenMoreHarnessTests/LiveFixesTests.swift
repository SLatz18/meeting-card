import XCTest
import ListenMoreCore
@testable import ListenMoreHarness

/// The fixes from the first live run, checked without the network.
final class LiveFixesTests: XCTestCase {
    let config = try! ListenMoreConfig.builtIn()

    func record(_ s: Scenario, mode: Mode = .live) throws -> RunRecord {
        let t = try Timeline.realize(s, shapes: SyntheticVoice.shapes(s))
        return RunRecord(scenario: s, mode: mode, timeline: t, config: config)
    }

    /// Latency runs from each segment's speech end, not the end of the line: a line transcribed in
    /// pieces has a positive latency for every piece.
    func testLatencyIsMeasuredFromEachSegmentsSpeechEnd() throws {
        let s = Scenario(name: "t", summary: "", lines: [Line("y", .you, "one two three four five six seven eight nine ten", .at(0), seconds: 10)])
        var r = try record(s)
        r.sockets.segments = [
            TranscribedSegment(stream: .mic, committedAt: 4.2, transcribedAt: 4.9, text: "one two three four"),
            TranscribedSegment(stream: .mic, committedAt: 10.2, transcribedAt: 10.8, text: "five six seven eight nine ten"),
        ]
        r.captions = [CaptionRecord(t: 4.9, speaker: .me, text: "one two three four", isFinal: true),
                      CaptionRecord(t: 10.8, speaker: .me, text: "five six seven eight nine ten", isFinal: true)]
        let tx = Scoring.transcription(r, keyless: false)[.me]!
        XCTAssertEqual(tx.latencies.count, 2)
        XCTAssertEqual(tx.latencies[0], 0.9, accuracy: 1e-9, "0.7 s after the commit plus the 0.2 s hangover")
        XCTAssertEqual(tx.latencies[1], 0.8, accuracy: 1e-9)
        XCTAssertTrue(tx.latencies.allSatisfy { $0 > 0 })
        XCTAssertEqual(tx.linesCaptioned, 1)
    }

    /// Attribution matches a segment to the line whose span holds its speech end and most of its words:
    /// You's words on Them's transcriber show as wrong; shared words don't confuse overlapping lines.
    func testAttributionUsesSegmentTiming() throws {
        let s = Scenario(name: "t", summary: "", lines: [
            Line("a", .themA, "the rollback steps are already written up in the shared folder", .at(0), seconds: 8),
            Line("y", .you, "the rollback steps were written for the old setup", .beforeEnd("a", lead: 4), seconds: 5),
        ])
        var r = try record(s)
        let yEnd = r.timeline.line("y")!.end
        r.sockets.segments = [
            TranscribedSegment(stream: .call, committedAt: 8.2, transcribedAt: 8.8, text: "the rollback steps are already written up"),
            TranscribedSegment(stream: .mic, committedAt: yEnd + 0.2, transcribedAt: yEnd + 0.9, text: "the rollback steps were written for"),
        ]
        XCTAssertEqual(Scoring.speakers(r).correct, 2)
        r.sockets.segments[1].stream = .call
        let wrong = Scoring.speakers(r)
        XCTAssertEqual(wrong.correct, 1, "You's words on Them's socket are a wrong attribution")
        XCTAssertEqual(wrong.total, 2)
    }

    /// Each engine's meter starts at 0: the scenario's billed seconds add up each engine's last reading.
    func testPerEngineMeterTotals() throws {
        var r = try record(Scenarios.pause)
        r.engineStarts = [-0.01, 20]
        r.meterLog = [(5, CostReading(transcribeUsd: 0.001, billedAudioS: 6)), (15, CostReading(transcribeUsd: 0.003, billedAudioS: 12)),
                      (30, CostReading(transcribeUsd: 0.002, billedAudioS: 5)), (40, CostReading(transcribeUsd: 0.004, billedAudioS: 12))]
        let total = Harness.perEngineTotal(r)
        XCTAssertEqual(total.billedAudioS, 24)
        XCTAssertEqual(total.transcribeUsd, 0.007, accuracy: 1e-12)
    }

    /// The missed-question rule decides on the reply as it's transcribed: in pieces, the soft cue can
    /// come once the decide-words-th word is spoken, before the reply ends.
    func testMissedQuestionWindowStartsAtTheDecidingWord() throws {
        let s = Scenarios.missedQuestion
        let t = try Timeline.realize(s, shapes: SyntheticVoice.shapes(s))
        let y2 = t.line("y2")!
        let e = try XCTUnwrap(CueOracle.expected(t, config: config, facts: .init(keyless: false, gptStopT: nil, mode: .live)).cues.first)
        let words = Double(ScriptText.tokens(y2.line.text).count)
        XCTAssertEqual(e.window.lowerBound, y2.start + (y2.end - y2.start) * Double(config.text.questionDecideWords) / words, accuracy: 1e-9)
        XCTAssertLessThan(e.window.lowerBound, y2.end - 2, "a cue before the reply ends is on time")
        XCTAssertEqual(e.window.upperBound, y2.end + 0.2 + CueOracle.liveTranscriptAllowanceS, accuracy: 1e-9)
    }

    /// Judge failures are classified by status and OpenAI's error code, or the thrown error's type. The
    /// regional-host redirect (401 incorrect_hostname, then a retry on the named host) is counted apart.
    func testJudgeFailureClasses() async throws {
        final class Replies: HTTPTransport, @unchecked Sendable {
            var n = 0
            func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval) async throws -> (status: Int, body: Data) {
                n += 1
                switch n {
                case 1: return (401, Data(#"{"error":{"code":"incorrect_hostname","message":"use eu.api.openai.com"}}"#.utf8))
                case 2: throw URLError(.timedOut)
                default: return (200, Data(#"{"usage":{"input_tokens":10,"output_tokens":2}}"#.utf8))
                }
            }
        }
        let http = MeteredHTTP(inner: Replies())
        let url = URL(string: "https://example.invalid")!
        _ = try await http.post(url: url, headers: [:], body: Data(), timeout: 1)
        do { _ = try await http.post(url: url, headers: [:], body: Data(), timeout: 1) } catch {}
        _ = try await http.post(url: url, headers: [:], body: Data(), timeout: 1)
        XCTAssertEqual(http.calls, 3)
        XCTAssertEqual(http.failures, ["URLError \(URLError.Code.timedOut.rawValue)"])
        XCTAssertEqual(http.hostRedirects, 1)
        XCTAssertEqual(http.tokens.input, 10)
        XCTAssertEqual(MeteredHTTP.failureClass(status: 500, root: ["error": ["code": "contains a space"]]), "HTTP 500", "only identifier-like codes")
    }

    /// The live meter counts a self-pivot judge's `401 incorrect_hostname` apart from the cue judge's, so the
    /// self-pivot check can require posts = judge calls + redirects.
    func testSelfPivotRedirectsAreCountedApart() async throws {
        struct Redirecting: HTTPTransport {
            func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval) async throws -> (status: Int, body: Data) {
                (401, Data(#"{"error":{"code":"incorrect_hostname","message":"use eu.api.openai.com"}}"#.utf8))
            }
        }
        let http = MeteredHTTP(inner: Redirecting())
        let url = URL(string: "https://example.invalid")!
        let selfPivot = Data(#"{"store":false,"text":{"format":{"name":"\#(SelfPivotJudgeSpec.name)"}}}"#.utf8)
        let cue = Data(#"{"store":false,"text":{"format":{"name":"listen_more_cue"}}}"#.utf8)
        _ = try await http.post(url: url, headers: [:], body: selfPivot, timeout: 1)
        _ = try await http.post(url: url, headers: [:], body: cue, timeout: 1)
        XCTAssertEqual(http.hostRedirects, 2)
        XCTAssertEqual(http.traffic.selfPivotRedirects, 1)
        XCTAssertEqual(http.traffic.selfPivotCalls, 1)
        XCTAssertTrue(http.failures.isEmpty, "a redirect is not a failure")
    }

    /// Live HTTP uses one URLSession for the whole process (libcurl 8.11+ aborts when one is released).
    func testLiveHTTPSessionIsShared() {
        XCTAssertTrue((LiveBackend.real().http as? EphemeralHTTPTransport) === EphemeralHTTPTransport.shared)
        XCTAssertTrue((LiveBackend.real().http as? EphemeralHTTPTransport) === (LiveBackend.real().http as? EphemeralHTTPTransport))
    }
}

/// Live judge off by default; offline judge on (a free stub); `judge: false` makes 0 judge calls.
@MainActor
final class JudgeSwitchTests: XCTestCase {
    func testJudgeOffMakesNoJudgeCalls() async throws {
        XCTAssertFalse(HarnessOptions(mode: .live, outputDirectory: URL(fileURLWithPath: "/tmp")).judgeOn)
        XCTAssertTrue(HarnessOptions(mode: .offline, outputDirectory: URL(fileURLWithPath: "/tmp")).judgeOn)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("lm-harness-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: out) }
        let summary = try await Harness.run(HarnessOptions(mode: .offline, scenarios: [Scenarios.missedQuestion], outputDirectory: out,
                                                           environment: [:], judge: false))
        let r = try XCTUnwrap(summary.results.first)
        XCTAssertTrue(r.passed, r.failures.map(\.detail).joined(separator: "; "))
        XCTAssertEqual(r.judgeCalls, 0)
        XCTAssertEqual(r.check("judge off: 0 judge calls")?.passed, true)
        XCTAssertEqual(r.cues.outcomes.compactMap(\.actual).map(\.type), [.missedQuestion], "transcript rules don't need the judge")
    }
}
