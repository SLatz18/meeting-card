import XCTest
import ListenMoreCore
@testable import ListenMoreHarness

/// The self-pivot precision run's plumbing, offline only (a stub answers; the paid run is never made here): the
/// cases reach the gate as expected (the shadow numbers), every request sends store false and nothing but the
/// self-pivot judge is asked, the bar catches a false cue on a negative, and no case text reaches an output.
final class PivotEvalTests: XCTestCase {
    func run(_ answer: String) async throws -> (report: PivotEval.Report, files: [URL]) {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("lm-pivot-eval-test-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: out) }
        let secret = "dry-run-secret-value"
        let r = try await PivotEval.runAndWrite(http: StubJudgeHTTP(selfPivotAnswer: (answer, 0.99)), key: try XCTUnwrap(APIKey(secret)),
                                                secrets: [secret], out: out, mode: "test")
        XCTAssertTrue(r.keyLeaks.isEmpty)
        for f in r.files { XCTAssertFalse(try String(contentsOf: f, encoding: .utf8).contains(secret)) }
        return (r.report, r.files)
    }

    /// The negative set includes the celebrate (group plan) and message-passing replies; the positive set the
    /// acknowledge-then-story and group-call pivots.
    func testTheSetsCoverTheReviewedCases() {
        let negatives = Set(PivotEval.negatives.map(\.name)), positives = Set(PivotEval.positives.map(\.name))
        for n in ["celebrate-group-plan", "message-mom-says-hi", "message-son-asked", "message-sends-love", "name-only-redirect",
                  "ack-then-ask", "pure-commiseration"] {
            XCTAssertTrue(negatives.contains(n), n)
        }
        for p in ["ack-then-story", "group-reaction-then-story", "sorry-then-own-hospital-story"] { XCTAssertTrue(positives.contains(p), p) }
        XCTAssertTrue(negatives.isDisjoint(with: positives))
    }

    /// With a judge that says no: no cue, store false on every request, only self-pivot requests, no case text in
    /// the outputs. The gate's shadow numbers: every positive but the known plural miss, and among the negatives
    /// only the name-only redirect (which the judge has to turn down).
    func testDryRunPlumbingAndShadowNumbers() async throws {
        let (r, files) = try await run("none")
        XCTAssertTrue(r.passed)
        XCTAssertEqual(r.falseCues.count, 0)
        XCTAssertEqual(r.recall, 0)
        XCTAssertEqual(r.positives.filter { !$0.candidate }.map(\.name), ["plural-own-story-gate-miss"])
        XCTAssertEqual(r.negatives.filter(\.candidate).map(\.name), ["name-only-redirect"])
        XCTAssertEqual(r.requests, r.outcomes.filter(\.candidate).count, "one request per candidate")
        XCTAssertEqual(r.requests, 12, "12 judged cases, 12 requests")
        XCTAssertTrue(r.outcomes.allSatisfy { $0.requests == ($0.candidate ? 1 : 0) && $0.requests == $0.judgeCalls })
        XCTAssertTrue(r.requestMismatches.isEmpty)
        XCTAssertEqual(r.storeViolations, 0)
        XCTAssertEqual(r.otherJudgeRequests, 0)
        XCTAssertTrue(r.snippetLeaks.isEmpty)
        XCTAssertEqual(files.map(\.lastPathComponent).sorted(), ["SUMMARY.md", "cost-log.jsonl", "pivot-eval.json", "pivot-eval.md"])
    }

    /// The stub's 400 input and 20 output tokens price at 0.00005 a request: each judged case reports it, the
    /// unjudged ones 0, and the total is their sum, in the JSON, SUMMARY.md and the cost log.
    func testSelfPivotUsdIsReportedPerCaseAndInTotal() async throws {
        let (r, files) = try await run("none")
        let each = 0.00005
        for o in r.outcomes { XCTAssertEqual(o.selfPivotUsd, o.judged ? each : 0, accuracy: 1e-12, o.name) }
        XCTAssertEqual(r.selfPivotUsd, 12 * each, accuracy: 1e-12)
        func read(_ name: String) throws -> String {
            try String(contentsOf: try XCTUnwrap(files.first { $0.lastPathComponent == name }), encoding: .utf8)
        }
        let summary = try read("SUMMARY.md")
        XCTAssertTrue(summary.contains("self_pivot_usd total: **0.000600**"), summary)
        XCTAssertTrue(summary.contains("| reminds-me | 1 | 400 | 20 | 0.000050 |"), summary)
        XCTAssertTrue(summary.contains("| celebrate-group-plan | 0 | 0 | 0 | 0.000000 |"), summary)
        XCTAssertTrue(summary.contains("| **total** | 12 | 4800 | 240 | **0.000600** |"), summary)
        XCTAssertTrue(try read("pivot-eval.md").contains("self_pivot_usd total: 0.000600"))
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try read("pivot-eval.json").utf8)) as? [String: Any])
        XCTAssertEqual(try XCTUnwrap(json["self_pivot_usd"] as? Double), 12 * each, accuracy: 1e-12)
        let cases = try XCTUnwrap(json["cases"] as? [[String: Any]])
        XCTAssertEqual(cases.count, r.outcomes.count)
        XCTAssertEqual(try XCTUnwrap(cases.first { $0["name"] as? String == "reminds-me" }?["self_pivot_usd"] as? Double), each, accuracy: 1e-12)
        let log = try read("cost-log.jsonl").split(separator: "\n").map {
            try XCTUnwrap(JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any])
        }
        XCTAssertEqual(log.count, r.outcomes.count + 1, "one entry per case and a total")
        let perCase = log.filter { $0["kind"] as? String == "judge" }
        XCTAssertEqual(perCase.compactMap { $0["self_pivot_usd"] as? Double }.reduce(0, +), 12 * each, accuracy: 1e-12)
        XCTAssertEqual(perCase.filter { ($0["self_pivot_calls"] as? Double) == 1 }.count, 12)
        let total = try XCTUnwrap(log.first { $0["kind"] as? String == "judge_total" })
        XCTAssertEqual(try XCTUnwrap(total["self_pivot_usd"] as? Double), 12 * each, accuracy: 1e-12)
        XCTAssertEqual(total["self_pivot_calls"] as? Double, 12)
        XCTAssertEqual(total["calls"] as? Double, 12)
    }

    /// A slow reply (the stub waits before answering) and a reply that names another host
    /// (`401 incorrect_hostname`, the paid run's first call) each still send one request per judged case.
    func testSlowAndHostRedirectRepliesSendOneRequestPerCase() async throws {
        let config = try PivotEval.config()
        let key = try XCTUnwrap(APIKey("dry-run-secret-value"))
        let slow = ReplyingHTTP(inner: StubJudgeHTTP(selfPivotAnswer: ("none", 0.99)), delayNs: 60_000_000)
        let slowReport = await PivotEval.run(PivotEval.cases, http: slow, key: key, config: config)
        XCTAssertEqual(slow.posts, 12)
        XCTAssertEqual(slowReport.requests, 12)
        XCTAssertTrue(slowReport.requestMismatches.isEmpty)

        let wrongHost = ReplyingHTTP(inner: StubJudgeHTTP(), delayNs: 0, status: 401,
                                     body: #"{"error":{"code":"incorrect_hostname","message":"Use eu.api.openai.com"}}"#)
        let redirected = await PivotEval.run(PivotEval.cases, http: wrongHost, key: key, config: config)
        XCTAssertEqual(wrongHost.posts, 12, "one request per judged case, none resent on the regional host")
        XCTAssertEqual(redirected.requests, 12)
        XCTAssertTrue(redirected.requestMismatches.isEmpty)
        XCTAssertEqual(redirected.failures.count, 12)
        XCTAssertFalse(redirected.passed)
    }

    /// The bar catches a request the layer never counted (a resend): a case with two requests for one counted
    /// judge call fails the run, and so does a counted call that never reached the wire.
    func testTheBarCatchesARequestTheLayerNeverCounted() {
        let clean = PivotEval.Outcome(name: "x", set: .positive, candidate: true, judged: true, verdict: "none", confidence: 0.9, cue: false,
                                      failure: nil, requests: 1, judgeCalls: 1)
        var resent = clean
        resent.requests = 2
        var unsent = clean
        unsent.requests = 0
        func report(_ o: PivotEval.Outcome) -> PivotEval.Report {
            PivotEval.Report(outcomes: [o], requests: o.requests, storeViolations: 0, otherJudgeRequests: 0, snippetLeaks: [])
        }
        XCTAssertTrue(report(clean).passed)
        XCTAssertFalse(report(resent).passed)
        XCTAssertEqual(report(resent).requestMismatches.map(\.name), ["x"])
        XCTAssertFalse(report(unsent).passed)
    }

    /// A judge that says yes to everything: every candidate positive is a cue, and the bar fails on the one
    /// negative the gate takes.
    func testTheBarCatchesAFalseCueOnANegative() async throws {
        let (r, _) = try await run("self_pivot")
        XCTAssertFalse(r.passed)
        XCTAssertEqual(r.falseCues.map(\.name), ["name-only-redirect"])
        XCTAssertEqual(r.recall, r.shadowRecall, accuracy: 1e-12)
    }

    func testTheTextCheckFlagsCaseWords() throws {
        let line = try XCTUnwrap(PivotEval.negatives.first?.turns.last?.text)
        let words = line.split(separator: " ").prefix(5).joined(separator: " ")
        XCTAssertEqual(PivotEval.snippetLeaks(in: [("clean", "false cues 0 of 15"), ("leaky", "prefix \(words) suffix")]), ["leaky"])
    }

    func testTheKeyIsNeverAnArgument() {
        XCTAssertThrowsError(try Harness.checkArguments(["--out", "x", "sk-abcdefghijklmnop"], environment: [:]))
        XCTAssertThrowsError(try Harness.checkArguments(["OPENAI_API_KEY=abc"], environment: [:]))
        XCTAssertNoThrow(try Harness.checkArguments(["--dry-run", "--stub-answer", "none"], environment: [:]))
    }
}


/// Wraps a judge transport: waits before answering, or answers a canned error instead. Counts what reached it.
final class ReplyingHTTP: HTTPTransport, @unchecked Sendable {
    private let inner: HTTPTransport
    private let delayNs: UInt64
    private let status: Int?
    private let body: String
    private let lock = NSLock()
    private var _posts = 0

    init(inner: HTTPTransport, delayNs: UInt64, status: Int? = nil, body: String = "") {
        self.inner = inner
        self.delayNs = delayNs
        self.status = status
        self.body = body
    }

    var posts: Int { lock.withLock { _posts } }

    func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval) async throws -> (status: Int, body: Data) {
        lock.withLock { _posts += 1 }
        if delayNs > 0 { try await Task.sleep(nanoseconds: delayNs) }
        if let status { return (status, Data(self.body.utf8)) }
        return try await inner.post(url: url, headers: headers, body: body, timeout: timeout)
    }
}
