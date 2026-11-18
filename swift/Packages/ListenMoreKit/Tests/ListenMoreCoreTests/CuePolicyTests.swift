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

    /// A host can switch cue types off (MeetingCard: not_listening); the generic config switches none off.
    func testDisabledCueTypesNeverShow() {
        XCTAssertTrue(CuePolicy(config: config.cues).disabled.isEmpty)
        var cues = config.cues
        cues.disabled = ["not_listening"]
        let p = CuePolicy(config: cues)
        XCTAssertNil(p.offer(.notListening, t: 0, onset: 0, source: .gpt, confidence: 0.99))
        XCTAssertEqual(p.suppressed, 0, "not held: never offered")
        XCTAssertNotNil(p.offer(.interrupt, t: 1, onset: 1, source: .local), "other cues are unaffected and no cooldown was used")
    }

    /// self_pivot is a cue type of its own: amber, ranked right after not_listening, off by host choice, and not
    /// something either judge can decide (nothing raises it yet).
    func testSelfPivotCueType() {
        XCTAssertEqual(CueType.selfPivot.rawValue, "self_pivot")
        XCTAssertEqual(CueType(rawValue: "self_pivot"), .selfPivot)
        XCTAssertTrue(CueType.allCases.contains(.selfPivot))
        XCTAssertFalse(CueType.judged.contains(.selfPivot))
        XCTAssertNil(CueType(gptLabel: "self_pivot"))
        for provider in [JudgeProviderKind.gpt, .typesafe] {
            XCTAssertNil(CueType(judgeLabel: "self_pivot", provider: provider), "\(provider)")
            XCTAssertFalse(CueType.decided(by: provider).contains(.selfPivot), "\(provider)")
        }
        XCTAssertEqual(config.cues.colors["self_pivot"], .amber)
        let p = CuePolicy(config: config.cues)
        XCTAssertEqual(p.offer(.selfPivot, t: 0, onset: 0, source: .text)?.color, .amber)

        var cues = config.cues
        cues.disabled = ["self_pivot"]
        let off = CuePolicy(config: cues)
        XCTAssertNil(off.offer(.selfPivot, t: 0, onset: 0, source: .text))
        XCTAssertEqual(off.suppressed, 0, "not held: never offered")
    }

    /// The shipped priority puts self_pivot right after not_listening: of cues raised together it beats
    /// talk_share and loses to not_listening.
    func testSelfPivotRanksRightAfterNotListening() {
        let order = config.cues.priority
        let i = order.firstIndex(of: "not_listening")
        XCTAssertNotNil(i)
        XCTAssertEqual(order.firstIndex(of: "self_pivot"), i.map { $0 + 1 })
        XCTAssertEqual(order.last, "talk_share")
        let both = CuePolicy(config: config.cues).offerMany([CueSuggestion(type: .talkShare, t: 5, onset: 4, source: .local),
                                                             CueSuggestion(type: .selfPivot, t: 5, onset: 4, source: .text)])
        XCTAssertEqual(both.map(\.type), [.selfPivot])
        let pair = CuePolicy(config: config.cues)
        XCTAssertEqual(pair.offerMany([CueSuggestion(type: .selfPivot, t: 5, onset: 4, source: .text),
                                       CueSuggestion(type: .notListening, t: 5, onset: 4, source: .gpt, confidence: 0.9)]).map(\.type),
                       [.notListening])
        XCTAssertEqual(pair.held.map(\.type), [.selfPivot])
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
