import XCTest
@testable import ListenMoreCore

/// Cue policy: colours, fade, one cue at a time, priority, global and per-type cooldowns, quiet holds.
final class CuePolicyTests: XCTestCase {
    var config: ListenMoreConfig!

    override func setUpWithError() throws {
        config = try TestConfig.load()
    }

    func testOneCueAtATimeWithGlobalAndPerTypeCooldowns() {
        let p = CuePolicy(config: config.cues)
        XCTAssertEqual(p.offer(.interrupt, t: 1, onset: 0.8, source: .local)?.color, .red)
        XCTAssertNil(p.offer(.talkOver, t: 10, onset: 9, source: .local), "any cue holds every type for 20 s")
        XCTAssertEqual(p.held.last, CuePolicy.Hold(type: .talkOver, t: 10, why: .global))
        XCTAssertEqual(p.offer(.monologue, t: 21, onset: 21, source: .local)?.fadeS, 3)
        XCTAssertNil(p.offer(.talkShare, t: 30, onset: 29, source: .local))
        XCTAssertNotNil(p.offer(.interrupt, t: 41.5, onset: 41, source: .local))
        XCTAssertEqual(p.suppressed, 2)
    }

    func testPerTypeCooldownOutlastsTheGlobalOne() {
        var cues = config.cues
        cues.globalCooldownS = 5
        cues.cooldownS = 30
        let p = CuePolicy(config: cues)
        XCTAssertNotNil(p.offer(.interrupt, t: 0, onset: 0, source: .local))
        XCTAssertNotNil(p.offer(.talkOver, t: 6, onset: 6, source: .local))
        XCTAssertNil(p.offer(.interrupt, t: 12, onset: 12, source: .local))
        XCTAssertEqual(p.held.last?.why, .type)
        XCTAssertNotNil(p.offer(.interrupt, t: 30, onset: 30, source: .local))
    }

    func testCooldownBoundaryIsTwentySeconds() {
        let p = CuePolicy(config: config.cues)
        XCTAssertEqual(p.cooldown, 20)
        XCTAssertEqual(p.globalCooldown, 20)
        XCTAssertNotNil(p.offer(.aggressive, t: 0, onset: 0, source: .local))
        XCTAssertNil(p.offer(.aggressive, t: 19.999, onset: 19.9, source: .local))
        XCTAssertNotNil(p.offer(.aggressive, t: 20, onset: 19.9, source: .local))
    }

    func testSimultaneousCandidatesGoInPriorityOrder() {
        var cues = config.cues
        cues.priority = ["interrupt", "talk_over", "missed_question", "not_listening", "monologue", "talk_share", "aggressive"]
        let p = CuePolicy(config: cues)
        let shown = p.offerMany([CueSuggestion(type: .talkShare, t: 5, onset: 4, source: .local),
                                 CueSuggestion(type: .missedQuestion, t: 5, onset: 3, source: .text, level: .strong),
                                 CueSuggestion(type: .talkOver, t: 5, onset: 4.5, source: .local)])
        XCTAssertEqual(shown.map(\.type), [.talkOver])
        XCTAssertEqual(p.held.map(\.type), [.missedQuestion, .talkShare])
        XCTAssertTrue(p.held.allSatisfy { $0.why == .global })
    }

    func testEqualPriorityKeepsArrivalOrder() {
        var cues = config.cues
        cues.priority = []
        let p = CuePolicy(config: cues)
        let shown = p.offerMany([CueSuggestion(type: .monologue, t: 1, onset: 0, source: .local, level: .soft),
                                 CueSuggestion(type: .interrupt, t: 1, onset: 0, source: .local)])
        XCTAssertEqual(shown.first?.type, .interrupt, "an empty priority list falls back to declaration order")
        XCTAssertEqual(shown.first?.level, nil)
    }

    func testQuietAfterAClosingPhraseHoldsWithoutConsumingCooldown() {
        let p = CuePolicy(config: config.cues)
        XCTAssertEqual(p.offerMany([CueSuggestion(type: .monologue, t: 1, onset: 0, source: .local, level: .strong)], quiet: true), [])
        XCTAssertEqual(p.held, [CuePolicy.Hold(type: .monologue, t: 1, why: .closing)])
        XCTAssertEqual(p.offer(.monologue, t: 2, onset: 0, source: .local, level: .strong)?.level, .strong)
    }

    func testGptNeedsConfidence() {
        let p = CuePolicy(config: config.cues)
        XCTAssertNil(p.offer(.notListening, t: 0, onset: 0, source: .gpt))
        XCTAssertNil(p.offer(.notListening, t: 0, onset: 0, source: .gpt, confidence: 0.5))
        XCTAssertNotNil(p.offer(.notListening, t: 0, onset: 0, source: .gpt, confidence: 0.7))
    }

    func testJudgeOnlyDecidesNotListening() {
        XCTAssertEqual(CueType(gptLabel: "not_listening"), .notListening)
        for label in ["none", "interrupting", "aggressive", "missed_question"] {
            XCTAssertNil(CueType(gptLabel: label), label)
        }
    }

    func testColorsMatchReadme() {
        let p = CuePolicy(config: config.cues)
        let red: [CueType] = [.interrupt, .talkOver, .aggressive]
        for (i, type) in CueType.allCases.enumerated() {
            let cue = p.offer(type, t: Double(i) * 20, onset: Double(i) * 20, source: .local)
            XCTAssertEqual(cue?.color, red.contains(type) ? .red : .amber, type.rawValue)
        }
    }

    func testLatency() {
        let p = CuePolicy(config: config.cues)
        XCTAssertEqual(p.offer(.interrupt, t: 3.301, onset: 3.0, source: .local)?.latencyMs, 301)
    }

    func testPausedSuppressesWithoutConsumingCooldown() {
        let p = CuePolicy(config: config.cues)
        p.paused = true
        XCTAssertNil(p.offer(.interrupt, t: 0, onset: 0, source: .local))
        p.paused = false
        XCTAssertNotNil(p.offer(.interrupt, t: 1, onset: 1, source: .local))
    }

    func testReset() {
        let p = CuePolicy(config: config.cues)
        XCTAssertNotNil(p.offer(.interrupt, t: 0, onset: 0, source: .local))
        XCTAssertNil(p.offer(.talkOver, t: 1, onset: 1, source: .local))
        p.reset()
        XCTAssertEqual(p.held, [])
        XCTAssertNotNil(p.offer(.interrupt, t: 1, onset: 1, source: .local))
    }
}
