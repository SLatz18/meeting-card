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
        XCTAssertEqual(r.posts, r.outcomes.filter(\.candidate).count, "one post per candidate")
        XCTAssertEqual(r.posts, 12, "12 judged cases, 12 posts")
        XCTAssertEqual(r.judgeCalls, 12, "and 12 judge calls")
        XCTAssertTrue(r.outcomes.allSatisfy { $0.posts == ($0.candidate ? 1 : 0) && $0.posts == $0.countedPosts && $0.judgeCalls == $0.posts })
        XCTAssertTrue(r.postMismatches.isEmpty)
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
        XCTAssertTrue(summary.contains("| reminds-me | 1 | 1 | 400 | 20 | 0.000050 |"), summary)
        XCTAssertTrue(summary.contains("| celebrate-group-plan | 0 | 0 | 0 | 0 | 0.000000 |"), summary)
        XCTAssertTrue(summary.contains("| **total** | 12 | 12 | 4800 | 240 | **0.000600** |"), summary)
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
        XCTAssertEqual(perCase.filter { ($0["self_pivot_calls"] as? Double) == 1 && ($0["self_pivot_judge_calls"] as? Double) == 1 }.count, 12)
        let total = try XCTUnwrap(log.first { $0["kind"] as? String == "judge_total" })
        XCTAssertEqual(try XCTUnwrap(total["self_pivot_usd"] as? Double), 12 * each, accuracy: 1e-12)
        XCTAssertEqual(total["self_pivot_calls"] as? Double, 12, "posts")
        XCTAssertEqual(total["self_pivot_judge_calls"] as? Double, 12, "judge calls, apart")
        XCTAssertEqual(total["calls"] as? Double, 12)
    }

    /// A slow reply (the stub waits before answering): one post per judged case, counted.
    func testSlowRepliesAreOnePostPerCase() async throws {
        let config = try PivotEval.config()
        let slow = ReplyingHTTP(inner: StubJudgeHTTP(selfPivotAnswer: ("none", 0.99)), delayNs: 60_000_000)
        let report = await PivotEval.run(PivotEval.cases, http: slow, key: try XCTUnwrap(APIKey("dry-run-secret-value")), config: config,
                                         hosts: LearnedHosts())
        XCTAssertEqual(slow.posts, 12)
        XCTAssertEqual(report.posts, 12)
        XCTAssertEqual(report.judgeCalls, 12)
        XCTAssertTrue(report.postMismatches.isEmpty)
        XCTAssertTrue(report.passed)
    }

    /// The paid run's shape: the first post goes to a host that answers `401 incorrect_hostname`, the one resend
    /// to the regional host works and is learned, and the other eleven cases post once. 13 posts, 12 judge calls,
    /// every post counted by the layer, and the run passes.
    func testTheRegionalResendIsCountedAndTheRunPasses() async throws {
        let config = try PivotEval.config()
        let routed = HostRoutedHTTP(inner: StubJudgeHTTP(selfPivotAnswer: ("none", 0.99)))
        let report = await PivotEval.run(PivotEval.cases, http: routed, key: try XCTUnwrap(APIKey("dry-run-secret-value")), config: config,
                                         hosts: LearnedHosts())
        XCTAssertEqual(routed.hosts.filter { $0 == "api.openai.com" }.count, 1, "only the first post goes to the configured host")
        XCTAssertEqual(report.posts, 13)
        XCTAssertEqual(report.judgeCalls, 12)
        XCTAssertEqual(report.outcomes.map(\.posts).filter { $0 == 2 }.count, 1)
        XCTAssertTrue(report.postMismatches.isEmpty, "wire posts equal the posts the layer counted")
        XCTAssertEqual(report.selfPivotUsd, 12 * 0.00005, accuracy: 1e-12, "the 401 carried no usage")
        XCTAssertTrue(report.passed)
    }

    /// Every host answers `401 incorrect_hostname`: each judged case makes exactly two posts, never a third, both
    /// counted, and the run fails on the errors.
    func testASecondUnauthorizedIsNeverResent() async throws {
        let config = try PivotEval.config()
        let wrongHost = ReplyingHTTP(inner: StubJudgeHTTP(), delayNs: 0, status: 401,
                                     body: #"{"error":{"code":"incorrect_hostname","message":"Use eu.api.openai.com"}}"#)
        let report = await PivotEval.run(PivotEval.cases, http: wrongHost, key: try XCTUnwrap(APIKey("dry-run-secret-value")), config: config,
                                         hosts: LearnedHosts())
        XCTAssertEqual(wrongHost.posts, 24, "two posts per judged case, never three")
        XCTAssertEqual(report.posts, 24)
        XCTAssertEqual(report.judgeCalls, 12)
        XCTAssertTrue(report.outcomes.allSatisfy { $0.posts == $0.countedPosts })
        XCTAssertTrue(report.postMismatches.isEmpty)
        XCTAssertEqual(report.failures.count, 12)
        XCTAssertFalse(report.passed)
    }

    /// The bar compares posts with posts: a case whose wire posts differ from the posts the layer counted fails
    /// the run, whichever way. Two posts for one judge call is fine when both are counted.
    func testTheBarComparesPostsWithPosts() {
        let clean = PivotEval.Outcome(name: "x", set: .positive, candidate: true, judged: true, verdict: "none", confidence: 0.9, cue: false,
                                      failure: nil, posts: 1, countedPosts: 1, judgeCalls: 1)
        var resent = clean
        resent.posts = 2
        var unsent = clean
        unsent.posts = 0
        var resentAndCounted = clean
        resentAndCounted.posts = 2
        resentAndCounted.countedPosts = 2
        func report(_ o: PivotEval.Outcome) -> PivotEval.Report {
            PivotEval.Report(outcomes: [o], posts: o.posts, storeViolations: 0, otherJudgeRequests: 0, snippetLeaks: [])
        }
        XCTAssertTrue(report(clean).passed)
        XCTAssertTrue(report(resentAndCounted).passed, "one judge call, two counted posts")
        XCTAssertFalse(report(resent).passed)
        XCTAssertEqual(report(resent).postMismatches.map(\.name), ["x"])
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
/// The configured host answers `401 incorrect_hostname` naming the regional one; the regional host answers like the
/// wrapped stub. Records each post's host.
final class HostRoutedHTTP: HTTPTransport, @unchecked Sendable {
    private let inner: HTTPTransport
    private let lock = NSLock()
    private var _hosts: [String] = []

    init(inner: HTTPTransport) { self.inner = inner }

    var hosts: [String] { lock.withLock { _hosts } }

    func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval) async throws -> (status: Int, body: Data) {
        let host = url.host ?? "?"
        lock.withLock { _hosts.append(host) }
        if host == "api.openai.com" {
            return (401, Data(#"{"error":{"code":"incorrect_hostname","message":"Use eu.api.openai.com"}}"#.utf8))
        }
        return try await inner.post(url: url, headers: headers, body: body, timeout: timeout)
    }
}

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
