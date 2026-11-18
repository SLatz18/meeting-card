import XCTest
import ListenMoreCore
@testable import ListenMoreHarness

/// The self-pivot cue through the whole offline pipeline (CoachSession, LocalCoachEngine, GptLayer, the
/// scripted transcriber and the stub judge): no candidate, judge call or cue in the 9 shipped scenarios,
/// even with a judge that would confirm every candidate; one judged cue on each of the two pivots (a group
/// call, an acknowledgment then the user's own story) and none on the look-alikes; the per-judge split in
/// the cost log; and no transcript or snippet text in any output file.
@MainActor
final class SelfPivotHarnessTests: XCTestCase {
    static let yes = (cue: "self_pivot", confidence: 0.99)

    func run(_ scenarios: [Scenario], answer: (cue: String, confidence: Double) = ("none", 0.9),
             judge: Bool? = nil, redirects: Int = 0) async throws -> (summary: HarnessSummary, out: URL) {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("lm-harness-test-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: out) }
        let summary = try await Harness.run(HarnessOptions(mode: .offline, scenarios: scenarios, outputDirectory: out, environment: [:],
                                                           judge: judge, offlineSelfPivotAnswer: answer,
                                                           offlineSelfPivotRedirects: redirects))
        return (summary, out)
    }

    func judgeEntry(_ s: HarnessSummary, _ name: String) throws -> CostEntry {
        try XCTUnwrap(s.costEntries.first { $0.kind == "judge" && $0.scenario == name })
    }

    func shown(_ r: ScenarioResult) -> [CueRecord] {
        (r.cues.outcomes.compactMap(\.actual) + r.cues.falseCues + r.cues.tolerated).filter { $0.type == .selfPivot }
    }

    /// Criterion 6: zero new candidates or cues across the 9 scenarios, with a judge that would say
    /// self_pivot to anything it was asked; the cue judge's calls are unchanged (12 offline).
    func testTheNineScenariosRaiseNoSelfPivot() async throws {
        let (summary, _) = try await run(Scenarios.all, answer: Self.yes)
        XCTAssertEqual(summary.results.count, 9)
        for r in summary.results {
            XCTAssertTrue(r.passed, "\(r.scenario): \(r.failures.map { "\($0.name): \($0.detail)" })")
            XCTAssertEqual(shown(r).count, 0, r.scenario)
            let e = try judgeEntry(summary, r.scenario)
            XCTAssertEqual(e.fields["self_pivot_candidates"], 0, r.scenario)
            XCTAssertEqual(e.fields["self_pivot_calls"], 0, r.scenario)
            XCTAssertEqual(e.fields["store_false_violations"], 0, r.scenario)
            XCTAssertTrue(r.checks.contains { $0.name == "self-pivot" && $0.passed }, r.scenario)
        }
        let judged = summary.costEntries.filter { $0.kind == "judge" }
        XCTAssertEqual(judged.compactMap { $0.fields["calls"] }.reduce(0, +), 12)
        XCTAssertEqual(judged.compactMap { $0.fields["other_calls"] }.reduce(0, +), 12)
    }

    /// The group-call pivot and the acknowledge-then-story pivot each give exactly one judged self_pivot
    /// cue after the reply; the moved-on and asked-back look-alikes give no candidate and no call.
    func testGroupCallAndAcknowledgeThenStoryGiveOneCueEach() async throws {
        let (summary, _) = try await run(Scenarios.selfPivot, answer: Self.yes)
        for r in summary.results {
            XCTAssertTrue(r.passed, "\(r.scenario): \(r.failures.map { "\($0.name): \($0.detail)" })")
            let e = try judgeEntry(summary, r.scenario)
            let pivot = ["self-pivot-group", "self-pivot-ack-then-story"].contains(r.scenario)
            XCTAssertEqual(e.fields["self_pivot_candidates"], pivot ? 1 : 0, r.scenario)
            XCTAssertEqual(e.fields["self_pivot_calls"], pivot ? 1 : 0, r.scenario)
            let cues = shown(r)
            XCTAssertEqual(cues.count, pivot ? 1 : 0, r.scenario)
            XCTAssertEqual(cues.first?.source ?? .gpt, .gpt)
            XCTAssertTrue(r.cues.falseCues.isEmpty, "\(r.scenario): \(r.cues.falseCues.map(\.type))")
        }
    }

    /// The judge decides: a no, or a yes under the 0.85 floor, gives a call and no cue.
    func testTheJudgeDecides() async throws {
        for answer in [(cue: "none", confidence: 0.99), (cue: "self_pivot", confidence: 0.84)] {
            let (summary, _) = try await run([Scenarios.selfPivotGroup, Scenarios.selfPivotAckThenStory], answer: answer)
            for r in summary.results {
                XCTAssertTrue(r.passed, "\(answer) \(r.scenario): \(r.failures.map { "\($0.name): \($0.detail)" })")
                XCTAssertEqual(try judgeEntry(summary, r.scenario).fields["self_pivot_calls"], 1)
                XCTAssertEqual(shown(r).count, 0)
            }
        }
    }

    /// Judge off (`Harness.judgeOff`): the candidate is counted, nothing is sent.
    func testJudgeOffSendsNothing() async throws {
        let (summary, _) = try await run([Scenarios.selfPivotGroup], answer: Self.yes, judge: false)
        let r = try XCTUnwrap(summary.results.first)
        XCTAssertTrue(r.passed, "\(r.failures.map { "\($0.name): \($0.detail)" })")
        let e = try judgeEntry(summary, r.scenario)
        XCTAssertEqual(e.fields["calls"], 0)
        XCTAssertEqual(e.fields["self_pivot_candidates"], 1)
        XCTAssertEqual(shown(r).count, 0)
    }

    /// Criterion 5: the cost log counts and prices the self-pivot judge apart from the cue judge.
    func testTheCostLogSplitsTheJudges() async throws {
        let (summary, out) = try await run([Scenarios.selfPivotGroup], answer: Self.yes)
        let e = try judgeEntry(summary, "self-pivot-group")
        let calls = try XCTUnwrap(e.fields["calls"]), sp = try XCTUnwrap(e.fields["self_pivot_calls"])
        XCTAssertEqual(sp, 1)
        XCTAssertEqual(e.fields["other_calls"], calls - sp)
        XCTAssertGreaterThan(calls - sp, 0, "the cue judge answered the reply too")
        XCTAssertEqual(try XCTUnwrap(e.fields["self_pivot_usd"]), 0.00005, accuracy: 1e-12, "the stub's 400 input and 20 output tokens")
        XCTAssertEqual(try XCTUnwrap(e.fields["other_usd"]) + 0.00005, try XCTUnwrap(e.fields["usd"]), accuracy: 1e-12)
        let log = try String(contentsOf: out.appendingPathComponent("cost-log.jsonl"), encoding: .utf8)
        XCTAssertTrue(log.contains(#""self_pivot_calls":1"#))
        XCTAssertTrue(log.contains(#""other_calls":"#))
    }

    /// The stub answers the first self-pivot post `401 incorrect_hostname`: the judge resends once, the cue is
    /// still judged and shown, and the self-pivot check holds: wire posts = engine posts = judge calls + redirects.
    func testOneHostRedirectIsCountedAndPasses() async throws {
        let (summary, _) = try await run([Scenarios.selfPivotGroup], answer: Self.yes, redirects: 1)
        let r = try XCTUnwrap(summary.results.first)
        XCTAssertTrue(r.passed, "\(r.failures.map { "\($0.name): \($0.detail)" })")
        let check = try XCTUnwrap(r.check("self-pivot"))
        XCTAssertTrue(check.passed, check.detail)
        XCTAssertTrue(check.detail.contains("posts 2 (engine 2), judge calls 1, redirects 1"), check.detail)
        let e = try judgeEntry(summary, r.scenario)
        XCTAssertEqual(e.fields["self_pivot_calls"], 2, "every post")
        XCTAssertEqual(e.fields["self_pivot_judge_calls"], 1, "judge calls, apart")
        XCTAssertEqual(e.fields["self_pivot_redirects"], 1)
        XCTAssertEqual(shown(r).count, 1)
    }

    /// Two redirects in a row (the resend is redirected too) is a failed check: more than one redirect, and the
    /// judge made no verdict.
    func testTwoRedirectsFailTheSelfPivotCheck() async throws {
        let (summary, _) = try await run([Scenarios.selfPivotGroup], answer: Self.yes, redirects: 2)
        let r = try XCTUnwrap(summary.results.first)
        XCTAssertEqual(r.check("self-pivot")?.passed, false)
        XCTAssertEqual(try judgeEntry(summary, r.scenario).fields["self_pivot_redirects"], 2)
    }

    /// Criterion 4: no transcript or snippet text in any output: results.md, results.json, cost-log.jsonl.
    func testOutputsCarryNoScriptText() async throws {
        let (summary, out) = try await run(Scenarios.selfPivot, answer: Self.yes)
        XCTAssertFalse(summary.files.isEmpty)
        let outputs = try summary.files.map { try String(contentsOf: $0, encoding: .utf8).lowercased() }
        for s in Scenarios.selfPivot {
            for line in s.lines {
                let words = line.text.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
                guard words.count >= 4 else { continue }
                for i in 0...(words.count - 4) {
                    let phrase = words[i..<(i + 4)].joined(separator: " ")
                    for (k, o) in outputs.enumerated() {
                        XCTAssertFalse(o.contains(phrase), "\(summary.files[k].lastPathComponent) carries \(s.name)/\(line.id)")
                    }
                }
            }
        }
        _ = out
    }
}
