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
        XCTAssertEqual(r.storeViolations, 0)
        XCTAssertEqual(r.otherJudgeRequests, 0)
        XCTAssertTrue(r.snippetLeaks.isEmpty)
        XCTAssertEqual(files.map(\.lastPathComponent).sorted(), ["pivot-eval.json", "pivot-eval.md"])
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
