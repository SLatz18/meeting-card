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

    /// Cue times are 20 ms frame times. A cue exactly one cooldown after the previous one is never held,
    /// wherever on the clock (frame-time differences round either way), and one frame earlier always is.
    func testCueOneCooldownLaterShowsAnywhereOnTheClock() {
        let frameS = config.frameS
        let cooldownFrames = Int((config.cues.cooldownS / frameS).rounded())
        XCTAssertEqual(cooldownFrames, 1000)
        var perType = config.cues, global = config.cues
        perType.globalCooldownS = 0
        global.cooldownS = 0
        var held: [String] = []
        for k in stride(from: 0, to: 200_000, by: 997) {
            let first = Double(k) * frameS, due = Double(k + cooldownFrames) * frameS
            let early = Double(k + cooldownFrames - 1) * frameS
            for (name, cues, second) in [("type", perType, CueType.interrupt), ("global", global, CueType.monologue)] {
                let p = CuePolicy(config: cues)
                XCTAssertNotNil(p.offer(.interrupt, t: first, onset: first, source: .local))
                XCTAssertNil(p.offer(second, t: early, onset: early, source: .local), "\(name) one frame early at frame \(k)")
                if p.offer(second, t: due, onset: due, source: .local) == nil { held.append("\(name)@\(k)") }
            }
        }
        XCTAssertEqual(held, [], "a cue exactly one cooldown later was held")
    }

    // MARK: a local interrupt after a judged cue

    func judged(_ p: CuePolicy, _ type: CueType = .notListening, at t: Double) -> Cue? {
        p.offer(type, t: t, onset: t - 1, source: .gpt, confidence: 0.9)
    }

    func testLocalInterruptAfterAJudgedCueSkipsTheGlobalCooldown() {
        let p = CuePolicy(config: config.cues)
        XCTAssertNotNil(judged(p, at: 10))
        XCTAssertEqual(p.offer(.interrupt, t: 15.56, onset: 14.4, source: .local)?.type, .interrupt)
        XCTAssertEqual(p.held, [])
    }

    func testOnlyALocalInterruptSkipsIt() {
        for (type, source) in [(CueType.talkOver, CueSource.local), (.monologue, .local), (.talkShare, .local),
                               (.missedQuestion, .text), (.aggressive, .text), (.interrupt, .text)] {
            let p = CuePolicy(config: config.cues)
            XCTAssertNotNil(judged(p, at: 0))
            XCTAssertNil(p.offer(type, t: 10, onset: 9, source: source, level: type == .monologue ? .soft : nil), "\(type) from \(source)")
            XCTAssertEqual(p.held.last?.why, .global, "\(type) from \(source)")
        }
    }

    func testAfterALocalCueAnInterruptStillWaitsForTheGlobalCooldown() {
        for (type, source) in [(CueType.talkOver, CueSource.local), (.monologue, .local), (.missedQuestion, .text)] {
            let p = CuePolicy(config: config.cues)
            XCTAssertNotNil(p.offer(type, t: 0, onset: 0, source: source))
            XCTAssertNil(p.offer(.interrupt, t: 10, onset: 9, source: .local), "after \(type)")
            XCTAssertEqual(p.held.last?.why, .global, "after \(type)")
        }
    }

    func testTheInterruptKeepsItsOwnCooldownAfterAJudgedCue() {
        var cues = config.cues
        cues.cooldownS = 30
        let p = CuePolicy(config: cues)
        XCTAssertNotNil(p.offer(.interrupt, t: 0, onset: 0, source: .local))
        XCTAssertNotNil(judged(p, at: 21))
        XCTAssertNil(p.offer(.interrupt, t: 27, onset: 26, source: .local))
        XCTAssertEqual(p.held.last, CuePolicy.Hold(type: .interrupt, t: 27, why: .type))
        XCTAssertNotNil(p.offer(.interrupt, t: 30, onset: 29, source: .local))
    }

    /// The global cooldown still runs between judged cues, whichever type the judge decided, and from
    /// an interrupt that showed in between.
    func testJudgedCuesStayAGlobalCooldownApart() {
        let p = CuePolicy(config: config.cues)
        XCTAssertNotNil(judged(p, at: 0))
        XCTAssertNil(judged(p, .aggressive, at: 10))
        XCTAssertEqual(p.held.last, CuePolicy.Hold(type: .aggressive, t: 10, why: .global))
        XCTAssertNil(judged(p, .missedQuestion, at: 19.999))
        XCTAssertEqual(p.held.last?.why, .global)
        XCTAssertNotNil(judged(p, .aggressive, at: 20))

        let q = CuePolicy(config: config.cues)
        XCTAssertNotNil(judged(q, at: 0))
        XCTAssertNotNil(q.offer(.interrupt, t: 6, onset: 5, source: .local))
        XCTAssertNil(judged(q, .aggressive, at: 21), "15 s after the interrupt")
        XCTAssertEqual(q.held.last?.why, .global)
        XCTAssertNil(q.offer(.monologue, t: 21, onset: 21, source: .local, level: .soft))
        XCTAssertEqual(q.held.last?.why, .global)
        XCTAssertNotNil(judged(q, .aggressive, at: 26))
    }

    /// A cue on screen is never replaced: a cut-in inside the judged cue's `on_screen_s` is dropped,
    /// keeps no cooldown, and the next one after it shows.
    func testACueOnScreenIsNeverReplaced() {
        let p = CuePolicy(config: config.cues)
        XCTAssertEqual(p.onScreen, 4.5)
        XCTAssertNotNil(judged(p, at: 10))
        XCTAssertNil(p.offer(.interrupt, t: 10, onset: 9, source: .local))
        XCTAssertNil(p.offer(.interrupt, t: 14.49, onset: 13, source: .local))
        XCTAssertEqual(p.held, [CuePolicy.Hold(type: .interrupt, t: 10, why: .onScreen), CuePolicy.Hold(type: .interrupt, t: 14.49, why: .onScreen)])
        XCTAssertNotNil(p.offer(.interrupt, t: 14.5, onset: 14, source: .local), "dropped, so no cooldown was used")
    }

    /// The on-screen hold is the same for every type and source, with no global cooldown at all.
    func testOnScreenHoldsEveryCueWithoutAGlobalCooldown() {
        var cues = config.cues
        cues.globalCooldownS = 0
        let p = CuePolicy(config: cues)
        XCTAssertNotNil(p.offer(.monologue, t: 0, onset: 0, source: .local, level: .soft))
        XCTAssertNil(p.offer(.talkOver, t: 4, onset: 3, source: .local))
        XCTAssertNil(judged(p, at: 4.2))
        XCTAssertEqual(p.held.map(\.why), [.onScreen, .onScreen])
        XCTAssertNotNil(judged(p, at: 4.5))
    }

    /// A cue exactly `on_screen_s` after the last shows anywhere on the 20 ms frame clock; one frame
    /// earlier is held.
    func testCueOneOnScreenHoldLaterShowsAnywhereOnTheClock() {
        let frameS = config.frameS
        let holdFrames = Int((config.cues.onScreenS / frameS).rounded())
        XCTAssertEqual(holdFrames, 225)
        var held: [Int] = []
        var roundedUnder = 0
        for k in Array(0..<20_000) + Array(stride(from: 20_000, to: 200_000, by: 997)) {
            let first = Double(k) * frameS, due = Double(k + holdFrames) * frameS, early = Double(k + holdFrames - 1) * frameS
            if due - first < config.cues.onScreenS { roundedUnder += 1 }
            let p = CuePolicy(config: config.cues)
            XCTAssertNotNil(judged(p, at: first))
            XCTAssertNil(p.offer(.interrupt, t: early, onset: early, source: .local), "one frame early at frame \(k)")
            if p.offer(.interrupt, t: due, onset: due, source: .local) == nil { held.append(k) }
        }
        XCTAssertGreaterThan(roundedUnder, 0, "some frame differences land a hair under on_screen_s")
        XCTAssertEqual(held, [], "a cut-in exactly on_screen_s after a judged cue was held")
    }

    /// One cue on screen at a time: every pair of types and sources, offered together or apart by up to
    /// 25 s on the frame clock, never shows two cues closer than `on_screen_s`.
    func testNeverTwoCuesOnScreen() {
        let offers: [(CueType, CueSource)] = CueType.allCases.map { ($0, CueSource.local) } + CueType.judged.map { ($0, .gpt) }
            + [(.missedQuestion, .text), (.aggressive, .text)]
        var close: [String] = []
        for (a, sa) in offers {
            for (b, sb) in offers {
                for gapFrames in stride(from: 0, through: 1250, by: 5) {
                    let p = CuePolicy(config: config.cues)
                    let t0 = 100.0, t1 = t0 + Double(gapFrames) * config.frameS
                    var shown: [Cue] = []
                    if gapFrames == 0 {
                        shown = p.offerMany([CueSuggestion(type: a, t: t0, onset: t0, source: sa, confidence: 0.9),
                                             CueSuggestion(type: b, t: t1, onset: t1, source: sb, confidence: 0.9)])
                    } else {
                        shown += [p.offer(a, t: t0, onset: t0, source: sa, confidence: 0.9),
                                  p.offer(b, t: t1, onset: t1, source: sb, confidence: 0.9)].compactMap { $0 }
                    }
                    if shown.count == 2 && shown[1].t - shown[0].t < config.cues.onScreenS {
                        close.append("\(a)/\(sa) then \(b)/\(sb) at +\(gapFrames) frames")
                    }
                }
            }
        }
        XCTAssertEqual(close, [])
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

    /// self_pivot is a cue type of its own: amber, ranked right after not_listening, off by host choice. Only the
    /// GPT provider's self-pivot judge raises it (`SelfPivotLane`); it is never one of the cues the me_reply judge
    /// decides, for either provider, so it can't switch the cue judge on.
    func testSelfPivotCueType() {
        XCTAssertEqual(CueType.selfPivot.rawValue, "self_pivot")
        XCTAssertEqual(CueType(rawValue: "self_pivot"), .selfPivot)
        XCTAssertTrue(CueType.allCases.contains(.selfPivot))
        XCTAssertFalse(CueType.judged.contains(.selfPivot))
        XCTAssertEqual(CueType(gptLabel: "self_pivot"), .selfPivot)
        XCTAssertEqual(CueType(judgeLabel: "self_pivot", provider: .gpt), .selfPivot)
        XCTAssertNil(CueType(judgeLabel: "self_pivot", provider: .typesafe))
        for provider in [JudgeProviderKind.gpt, .typesafe] {
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

    /// A judged self_pivot cue goes through the same policy as every other cue: the 20 s global cooldown, its
    /// own 20 s cooldown, the `on_screen_s` hold, the judge's confidence floor, the closing-phrase quiet and
    /// Pause. A local interrupt right after it skips the global cooldown (it was judged) but not the hold.
    func testSelfPivotWorksWithTheCuePolicy() {
        func p() -> CuePolicy { CuePolicy(config: config.cues) }
        func sp(_ policy: CuePolicy, _ t: Double, _ confidence: Double = 0.9, quiet: Bool = false) -> Cue? {
            policy.offer(.selfPivot, t: t, onset: t - 3, source: .gpt, confidence: confidence, quiet: quiet)
        }
        let global = p()
        XCTAssertNotNil(global.offer(.monologue, t: 0, onset: 0, source: .local))
        XCTAssertNil(sp(global, 19.9))
        XCTAssertEqual(global.held.last, CuePolicy.Hold(type: .selfPivot, t: 19.9, why: .global))
        XCTAssertEqual(sp(global, 20)?.color, .amber)

        var cues = config.cues
        cues.globalCooldownS = 0
        let own = CuePolicy(config: cues)
        XCTAssertNotNil(sp(own, 0))
        XCTAssertNil(sp(own, 10))
        XCTAssertEqual(own.held.last?.why, .type)
        XCTAssertNil(own.offer(.monologue, t: 2, onset: 2, source: .local), "inside the 4.5 s on-screen hold")
        XCTAssertEqual(own.held.last?.why, .onScreen)
        XCTAssertNotNil(sp(own, 20))

        let floor = p()
        XCTAssertNil(sp(floor, 0, 0.69), "under gpt_min_confidence")
        XCTAssertNil(floor.offer(.selfPivot, t: 0, onset: 0, source: .gpt), "a judged cue needs a confidence")
        XCTAssertNil(sp(p(), 0, quiet: true))
        let paused = p()
        paused.paused = true
        XCTAssertNil(sp(paused, 0))

        let cut = p()
        XCTAssertNotNil(sp(cut, 10))
        XCTAssertNil(cut.offer(.interrupt, t: 14, onset: 13.5, source: .local))
        XCTAssertEqual(cut.held.last?.why, .onScreen)
        XCTAssertNotNil(cut.offer(.interrupt, t: 14.6, onset: 14, source: .local), "past the hold, inside the global cooldown")
        XCTAssertNil(sp(cut, 25), "the self-pivot cue is still a global cooldown after the interrupt")
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
