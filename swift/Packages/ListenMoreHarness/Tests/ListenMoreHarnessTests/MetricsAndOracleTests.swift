import XCTest
import ListenMoreCore
@testable import ListenMoreHarness

final class WordErrorTests: XCTestCase {
    func words(_ s: String) -> [String] { ScriptText.tokens(s) }

    func testIdenticalIsZero() {
        let e = WordErrors.compute(reference: words("the plan is ready"), hypothesis: words("The plan is ready."))
        XCTAssertEqual(e.errors, 0)
        XCTAssertEqual(e.rate, 0)
    }

    func testCountsEachKind() {
        let ref = words("move the demo to next week")
        let sub = WordErrors.compute(reference: ref, hypothesis: words("move a demo to next week"))
        XCTAssertEqual([sub.substitutions, sub.deletions, sub.insertions], [1, 0, 0])
        let del = WordErrors.compute(reference: ref, hypothesis: words("move the demo to week"))
        XCTAssertEqual([del.substitutions, del.deletions, del.insertions], [0, 1, 0])
        let ins = WordErrors.compute(reference: ref, hypothesis: words("move the demo to next week please"))
        XCTAssertEqual([ins.substitutions, ins.deletions, ins.insertions], [0, 0, 1])
        let all = WordErrors.compute(reference: ref, hypothesis: words("move a demo to week please"))
        XCTAssertEqual(all.errors, 3)
        XCTAssertEqual(all.referenceWords, 6)
        XCTAssertEqual(all.rate!, 0.5, accuracy: 1e-9)
    }

    func testEmptySides() {
        XCTAssertNil(WordErrors.compute(reference: [], hypothesis: []).rate)
        XCTAssertEqual(WordErrors.compute(reference: [], hypothesis: ["extra"]).insertions, 1)
        XCTAssertEqual(WordErrors.compute(reference: ["missing", "words"], hypothesis: []).rate, 1)
    }
}

/// The oracle on hand-placed timelines (synthetic shapes, no engine).
final class CueOracleTests: XCTestCase {
    let config = try! ListenMoreConfig.builtIn()

    func expected(_ s: Scenario, keyless: Bool = false) throws -> [ExpectedCue] {
        let t = try Timeline.realize(s, shapes: SyntheticVoice.shapes(s))
        return CueOracle.expected(t, config: config, facts: .init(keyless: keyless, gptStopT: nil, mode: .offline)).cues
    }

    func testBackchannelIsNotACutIn() throws {
        let s = Scenario(name: "t", summary: "", lines: [
            Line("a", .themA, "one two three four five six seven eight nine ten eleven twelve", .at(0)),
            Line("y", .you, "Yeah.", .into("a", offset: 1.5), seconds: 0.4),
        ])
        XCTAssertTrue(try expected(s).isEmpty)
    }

    func testCutInFiresAfterTheBackchannelLength() throws {
        let s = Scenario(name: "t", summary: "", lines: [
            Line("a", .themA, "one two three four five six seven eight nine ten eleven twelve", .at(0)),
            Line("y", .you, "hold on that is not right at all", .beforeEnd("a", lead: 2.0)),
        ])
        let e = try expected(s)
        XCTAssertEqual(e.map(\.type), [.interrupt])
        let start = try Timeline.realize(s, shapes: SyntheticVoice.shapes(s)).line("y")!.start
        XCTAssertEqual(e[0].window.lowerBound, start + 1.2 - 0.25, accuracy: 1e-9)
    }

    func testQuestionJustBeforeTheCutInDropsIt() throws {
        let s = Scenario(name: "t", summary: "", lines: [
            Line("q", .themA, "Is the plan ready?", .at(0)),
            Line("a", .themA, "one two three four five six seven eight nine ten eleven twelve", .after("q", gap: 0.2)),
            Line("y", .you, "yes it is ready and here is the summary", .into("a", offset: 0.5)),
        ])
        XCTAssertFalse(try expected(s).contains { $0.type == .interrupt })
        XCTAssertTrue(try expected(s, keyless: true).contains { $0.type == .interrupt }, "without transcripts the question is unknown")
    }

    func testUnmuteGraceSkipsTheCutIn() throws {
        let lines = [
            Line("a", .themA, "one two three four five six seven eight nine ten eleven twelve thirteen fourteen", .at(0)),
            Line("y", .you, "hold on that is not right at all", .into("a", offset: 2.3)),
        ]
        let graced = Scenario(name: "t", summary: "", lines: lines,
                              controls: [Control(.mute, .at(0.1)), Control(.unmute, .into("a", offset: 2.0))])
        XCTAssertTrue(try expected(graced).isEmpty)
        let late = Scenario(name: "t", summary: "", lines: lines,
                            controls: [Control(.mute, .at(0.1)), Control(.unmute, .into("a", offset: 1.0))])
        XCTAssertEqual(try expected(late).map(\.type), [.interrupt])
    }

    func testMonologueSoftAndStrong() throws {
        let s = Scenario(name: "t", summary: "", lines: [Line("y", .you, "words", .at(1), seconds: 95)])
        let e = try expected(s)
        XCTAssertEqual(e.map(\.level), [.soft, .strong])
        XCTAssertEqual(e[0].window.lowerBound, 1 + 60 - 0.3, accuracy: 1e-9)
    }

    func testMissedQuestionRules() throws {
        func cues(_ reply: String) throws -> [CueType] {
            try expected(Scenario(name: "t", summary: "", lines: [
                Line("q", .themA, "What date should we pick for the customer pilot?", .at(0)),
                Line("y", .you, reply, .after("q", gap: 1)),
            ])).map(\.type)
        }
        XCTAssertEqual(try cues("Yes, the first week works."), [])
        XCTAssertEqual(try cues("The pilot date for that customer is fine by me."), [], "two shared content words clear it")
        XCTAssertEqual(try cues("I was thinking we should also tidy up the onboarding emails first."), [.missedQuestion])
    }

    func testCooldownKeepsOneCue() throws {
        let s = Scenario(name: "t", summary: "", lines: [
            Line("a", .themA, "one two three four five six seven eight nine ten eleven twelve", .at(0)),
            Line("y", .you, "hold on that is not right at all", .beforeEnd("a", lead: 2.0)),
            Line("b", .themA, "one two three four five six seven eight nine ten eleven twelve", .after("y", gap: 2)),
            Line("z", .you, "hold on that is not right at all", .beforeEnd("b", lead: 2.0)),
        ])
        XCTAssertEqual(try expected(s).count, 1, "the second cut-in is within the 20 s cooldown")
    }

    func testMatchFlagsFalseAndMissed() {
        let e = [ExpectedCue(type: .interrupt, level: nil, window: 10...11, optional: false, reason: "")]
        let actual = [CueRecord(t: 12, engineT: 12, type: .interrupt, level: nil, source: .local, latencyMs: 0)]
        let m = CueOracle.match(expected: e, tolerated: [], actual: actual)
        XCTAssertEqual(m.missed.count, 1)
        XCTAssertEqual(m.falseCues.count, 1)
        XCTAssertFalse(m.passed)
    }

    func testEveryScenarioRealizes() throws {
        for s in Scenarios.all {
            let t = try Timeline.realize(s, shapes: SyntheticVoice.shapes(s))
            XCTAssertGreaterThan(t.duration, 5, s.name)
        }
    }
}
