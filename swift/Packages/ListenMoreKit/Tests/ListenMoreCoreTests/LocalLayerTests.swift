import XCTest
@testable import ListenMoreCore

/// Transcript answers for the local layer, set per test.
final class StubTextContext: LocalTextContext {
    var howWhy = false
    var updateTurn = false
    var isReadback = false

    func howWhyBefore(_ t: TimeInterval) -> Bool { howWhy }
    func updateTurnBefore(_ t: TimeInterval) -> Bool { updateTurn }
    func readback(from t0: TimeInterval, now: TimeInterval) -> Bool { isReadback }
}

/// Each local rule on synthetic two-stream audio (mic = the user, call = everyone else). Thresholds
/// are scaled down where a rule would otherwise need minutes of audio.
final class LocalLayerTests: XCTestCase {
    var config: ListenMoreConfig!
    let meF0 = 120.0, othersF0 = 210.0

    override func setUpWithError() throws {
        config = try TestConfig.load()
    }

    func run(_ total: Double, me: [(Double, Double)], others: [(Double, Double)], participants: Int = 2,
             context: LocalTextContext? = nil) -> [LocalEvent] {
        Synthetic.runLocal(config, mic: Synthetic.track(total, me, f0: meF0), call: Synthetic.track(total, others, f0: othersF0),
                           participants: participants, context: context)
    }

    func kinds(_ evs: [LocalEvent]) -> [LocalEvent.Kind] { evs.map(\.kind) }

    // MARK: cut-in

    /// A pause in the other side's speech during the cut-in's opening overlap: one of
    /// `cut_in_overlap_gap_ms` (0.30 s) keeps the cut-in, one frame more (0.32 s) drops it, at any
    /// point on the clock (absolute times change how frame-time differences round).
    func testCutInSurvivesThemPauseUpToTheTolerance() {
        XCTAssertEqual(config.local.cutInOverlapGapMs, 300)
        for offset in [0.0, 10.0, 100.0] {
            func cut(gap: Double) -> [LocalEvent.Kind] {
                kinds(run(offset + 9, me: [(offset + 3.2, offset + 6.5)],
                          others: [(offset + 1.0, offset + 3.5), (offset + 3.5 + gap, offset + 7.0)]))
            }
            XCTAssertEqual(cut(gap: 0.30), [.interrupt], "a 0.30 s pause at offset \(offset)")
            XCTAssertEqual(cut(gap: 0.32), [], "a 0.32 s pause at offset \(offset)")
        }
    }

    /// The tolerance is the config's: at 160 ms a 0.16 s pause keeps the cut-in and 0.18 s drops it.
    func testCutInPauseToleranceIsConfigurable() throws {
        let tight = try ListenMoreConfig.load(overrides: ["local": ["cut_in_overlap_gap_ms": 160]])
        func cut(gap: Double) -> [LocalEvent.Kind] {
            kinds(Synthetic.runLocal(tight, mic: Synthetic.track(9, [(3.2, 6.5)], f0: meF0),
                                     call: Synthetic.track(9, [(1.0, 3.5), (3.5 + gap, 7.0)], f0: othersF0)))
        }
        XCTAssertEqual(cut(gap: 0.16), [.interrupt])
        XCTAssertEqual(cut(gap: 0.18), [])
    }

    /// The user starting inside a pause of theirs: the pause counts from the user's onset, so 0.30 s
    /// from the onset to their next word keeps the cut-in and 0.32 s drops it, wherever on the clock.
    func testCutInStartingInTheirPauseCountsThePauseFromTheOnset() {
        for offset in [0.0, 10.0, 100.0] {
            func cut(fromOnset: Double) -> [LocalEvent.Kind] {
                kinds(run(offset + 10, me: [(offset + 4.1, offset + 7.4)],
                          others: [(offset + 1.0, offset + 4.0), (offset + 4.1 + fromOnset, offset + 9.0)]))
            }
            XCTAssertEqual(cut(fromOnset: 0.30), [.interrupt], "0.30 s from the onset at offset \(offset)")
            XCTAssertEqual(cut(fromOnset: 0.32), [], "0.32 s from the onset at offset \(offset)")
        }
    }

    /// A pause they ride through adds nothing to the opening overlap: here the overlap before and after
    /// it stays under 0.6 s, so no cut-in fires on it. They stop for good, so it goes to the trailing
    /// rule, with their last words as they ended.
    func testPauseInTheOpeningOverlapIsNotOverlapAndAStopIsTrailing() throws {
        let evs = run(9, me: [(3.2, 6.5)], others: [(1.0, 3.5), (3.8, 3.94)])
        XCTAssertEqual(kinds(evs), [.interrupt])
        let cut = try XCTUnwrap(evs.first)
        XCTAssertTrue(cut.trailing, "0.3 s of overlap, a 0.3 s pause, 0.14 s more: not 0.6 s of overlap")
        XCTAssertEqual(cut.othersLastSpeech ?? 0, 3.94, accuracy: 0.03)
        XCTAssertGreaterThanOrEqual(cut.t - cut.onset, config.local.cutInTrailingYieldS - 1e-9)
        let flicker = try XCTUnwrap(run(9, me: [(3.2, 6.5)], others: [(1.0, 3.5), (3.66, 3.80)]).first)
        XCTAssertTrue(flicker.trailing, "a 0.16 s pause, one stretch, but its 0.1 s past the speaking tail isn't overlap")
    }

    /// The opening overlap builds within one stretch of their speech: 0.3 s of overlap, a pause, and
    /// 0.3 s more make the 0.6 s across a 0.16 s pause (VAD flicker) but not across 0.18 s, which starts
    /// it again; they stop for good after it, so that one is a trailing candidate.
    func testOpeningOverlapBuildsWithinOneStretchOfTheirSpeech() throws {
        XCTAssertEqual(LocalLayer.overlapStretchGapS, 0.16, accuracy: 1e-12)
        func cut(pause: Double) -> [LocalEvent] {
            run(9, me: [(3.2, 6.5)], others: [(1.0, 3.5), (3.5 + pause, 3.8 + pause)])
        }
        let joined = try XCTUnwrap(cut(pause: 0.16).first)
        XCTAssertFalse(joined.trailing, "a 0.16 s pause: one stretch, 0.6 s of overlap")
        let restarted = try XCTUnwrap(cut(pause: 0.18).first)
        XCTAssertTrue(restarted.trailing, "a 0.18 s pause: 0.3 s after it is not 0.6 s")
    }

    /// A lone voiced frame on their side after their VAD has let go (a click) never becomes speech, so it
    /// doesn't end their pause: 0.50 s with the click in it drops the cut-in; without the click's
    /// restart, the 0.22 s after it would be inside the tolerance.
    func testLoneVoicedFrameDoesNotEndTheirPause() {
        let mic = Synthetic.track(9, [(3.2, 6.5)], f0: meF0)
        var call = Synthetic.track(9, [(1.0, 3.5), (4.0, 7.0)], f0: othersF0)
        let click = Synthetic.speechish(0.02, seed: 9, f0: othersF0)
        let at = Int(3.76 * Double(Synthetic.sr))
        for j in click.indices { call[at + j] = click[j] }
        XCTAssertEqual(kinds(Synthetic.runLocal(config, mic: mic, call: call)), [], "0.50 s of pause around the click")
    }

    /// A cut-in fires on the frame its utterance reaches `cut_in_backchannel_max_ms` (1.2 s), wherever
    /// on the clock it starts.
    func testCutInFiresAtTheBackchannelLengthAnywhereOnTheClock() throws {
        XCTAssertEqual(config.local.cutInBackchannelMaxMs, 1200)
        let mic = Synthetic.track(8, [(3.0, 6.0)], f0: meF0)
        let call = Synthetic.track(8, [(1.0, 5.5)], f0: othersF0)
        var off: [Int] = []
        for k in 0..<200 {
            let start = k * 137
            let evs = Synthetic.runLocal(config, mic: mic, call: call, startFrame: start)
            let cut = try XCTUnwrap(evs.first { $0.kind == .interrupt }, "no interrupt from frame \(start)")
            if abs(cut.t - cut.onset - 1.2) > 1e-9 { off.append(start) }
        }
        XCTAssertEqual(off, [], "the interrupt fired a frame off 1.20 s after onset from these start frames")
    }

    /// The user starting exactly `cut_in_others_pause_ms` (0.3 s) after the other side's last voiced
    /// frame, once their VAD hangover has ended, still cuts in on them, wherever on the clock; a frame
    /// later does not. They come back 60 ms after the user's onset, inside the overlap's gap tolerance.
    func testCutInOpensAtTheMidPauseLimitAnywhereOnTheClock() throws {
        XCTAssertEqual(config.local.cutInOthersPauseMs, 300)
        let call = Synthetic.track(6, [(1.0, 3.5), (3.86, 6.0)], f0: othersF0)
        func cutIn(_ mic: [Float], startFrame: Int) -> Bool {
            Synthetic.runLocal(config, mic: mic, call: call, startFrame: startFrame).contains { $0.kind == .interrupt }
        }
        XCTAssertFalse(cutIn(Synthetic.track(6, [(3.82, 6.0)], f0: meF0), startFrame: 0),
                       "control: 0.32 s into their pause is past the limit")
        let mic = Synthetic.track(6, [(3.80, 6.0)], f0: meF0)
        let missed = (0..<100).map { $0 * 137 }.filter { !cutIn(mic, startFrame: $0) }
        XCTAssertEqual(missed, [], "no cut-in 0.30 s into their pause from these start frames")
    }

    func testCutInNeedsTheOverlapAndThemContinuing() throws {
        let evs = run(8, me: [(3.0, 6.0)], others: [(1.0, 5.5)])
        XCTAssertEqual(kinds(evs), [.interrupt])
        let cut = try XCTUnwrap(evs.first)
        XCTAssertEqual(cut.onset, 3.0, accuracy: 0.05)
        XCTAssertGreaterThanOrEqual(cut.t - cut.onset, 0.6 + 0.5 - 0.05, "600 ms overlap, then 500 ms of them continuing")
        XCTAssertEqual(cut.othersActive, true)
        XCTAssertFalse(cut.trailing)
    }

    /// The pause scenario's live miss (judge on, after Resume, box run at e2e6b84): You start 0.24 s
    /// into a 0.46 s pause of theirs and they speak again 0.22 s after You's onset, inside
    /// `cut_in_overlap_gap_ms`, so one long sentence cuts in from its first onset. At 200 ms it can't,
    /// and only a second onset while they talk cuts in.
    func testCutInStartingInTheirPauseRidesThroughIt() throws {
        let them: [(Double, Double)] = [(1.0, 4.2), (4.66, 9.2)]
        let cut = try XCTUnwrap(run(10, me: [(4.44, 7.4)], others: them).first { $0.kind == .interrupt })
        XCTAssertEqual(cut.onset, 4.44, accuracy: 0.05)
        XCTAssertFalse(cut.trailing)
        let tight = try ListenMoreConfig.load(overrides: ["local": ["cut_in_overlap_gap_ms": 200]])
        func runTight(_ me: [(Double, Double)]) -> [LocalEvent] {
            Synthetic.runLocal(tight, mic: Synthetic.track(10, me, f0: meF0), call: Synthetic.track(10, them, f0: othersF0))
        }
        XCTAssertEqual(kinds(runTight([(4.44, 7.4)])), [])
        let second = try XCTUnwrap(runTight([(4.44, 5.4), (5.85, 8.0)]).first { $0.kind == .interrupt })
        XCTAssertEqual(second.onset, 5.85, accuracy: 0.05)
    }

    /// cost-cap's judge-on take at 0390f5e (raw voicing from its shadow trace), which missed its
    /// interrupt after the budget cap: Them's a2 breathes about once a second (quiet 9.64-9.90,
    /// 11.46-11.90, 12.52-12.74, 13.66-14.00 and 14.64-14.86 s, and 0.14 s after 13.08 s). You start at
    /// 11.60 s inside one of those breaths, 0.30 s before they speak again: inside
    /// `cut_in_overlap_gap_ms`, so the first onset cuts in, 1.2 s later. One frame tighter (280 ms) it
    /// can't, nor can the second onset (13.08 s, 0.34 s breath ahead), and the take misses.
    func testCostCapLiveTakeCutsInThroughThemBreaths() throws {
        let breaths: [(Double, Double)] = [(8.3, 9.64), (9.90, 11.46), (11.90, 12.52), (12.74, 13.30), (13.44, 13.66),
                                           (14.00, 14.64), (14.86, 15.6)]
        let you: [(Double, Double)] = [(11.60, 12.72), (13.08, 17.4)]
        let cuts = run(18, me: you, others: breaths).filter { $0.kind == .interrupt }
        XCTAssertEqual(cuts.count, 1)
        let cut = try XCTUnwrap(cuts.first)
        XCTAssertEqual(cut.onset, 11.60, accuracy: 0.03)
        XCTAssertEqual(cut.t, 12.80, accuracy: 0.03)
        XCTAssertFalse(cut.trailing)
        let tight = try ListenMoreConfig.load(overrides: ["local": ["cut_in_overlap_gap_ms": 280]])
        XCTAssertEqual(kinds(Synthetic.runLocal(tight, mic: Synthetic.track(18, you, f0: meF0),
                                                call: Synthetic.track(18, breaths, f0: othersF0))), [])
    }

    func testBackchannelIsNotACutIn() {
        XCTAssertEqual(kinds(run(7, me: [(3.0, 3.6)], others: [(1.0, 6.0)])), [])
    }

    func testThemCuttingInOnTheUserIsNotTheUsersCutIn() {
        XCTAssertFalse(kinds(run(8, me: [(1.0, 5.5)], others: [(3.0, 6.0)])).contains(.interrupt))
    }

    func testShortOverlapAsTheyFinishIsATrailingCandidate() throws {
        let evs = run(8, me: [(3.0, 6.5)], others: [(1.0, 3.45)])
        let cut = try XCTUnwrap(evs.first { $0.kind == .interrupt })
        XCTAssertTrue(cut.trailing, "300-600 ms of overlap that ends with them stopping: needs their words to judge")
        XCTAssertEqual(cut.othersActive, false)
        XCTAssertGreaterThanOrEqual(cut.t - cut.onset, config.local.cutInTrailingYieldS - 1e-9)
        XCTAssertEqual(cut.othersLastSpeech ?? 0, 3.45, accuracy: 0.1)
    }

    func testTinyOverlapAsTheyFinishIsNothing() {
        XCTAssertEqual(kinds(run(8, me: [(3.0, 6.5)], others: [(1.0, 3.15)])), [])
    }

    func testTrailingCandidateDropsWhenTheyComeBackIn() {
        XCTAssertFalse(kinds(run(9, me: [(3.0, 7.0)], others: [(1.0, 3.45), (4.2, 5.0)])).contains(.interrupt))
    }

    // MARK: talk-over

    let talkOverMe: [(Double, Double)] = [(1.0, 2.0), (2.4, 6.0)]
    let talkOverOthers: [(Double, Double)] = [(0.5, 1.4), (1.8, 2.6)]

    func testTalkOverNeedsSwitchesOverlapAndTheUserHoldingTheFloor() throws {
        let evs = run(8, me: talkOverMe, others: talkOverOthers)
        XCTAssertEqual(kinds(evs), [.talkOver])
        let to = try XCTUnwrap(evs.first)
        XCTAssertGreaterThanOrEqual(to.switches ?? 0, config.local.talkOverSwitches)
        XCTAssertGreaterThanOrEqual(to.t - to.onset, config.local.talkOverHoldFloorMs / 1000 - 1e-9)
    }

    func testNumberReadBackIsNotATalkOver() {
        let ctx = StubTextContext()
        ctx.isReadback = true
        XCTAssertEqual(kinds(run(8, me: talkOverMe, others: talkOverOthers, context: ctx)), [])
    }

    func testNoCutInRightAfterATalkOver() {
        let me = talkOverMe + [(10.0, 13.0)], others = talkOverOthers + [(9.0, 13.5)]
        XCTAssertEqual(kinds(run(15, me: me, others: others)), [.talkOver])
        config.local.cutInAfterTalkOverS = 0
        XCTAssertEqual(kinds(run(15, me: me, others: others)), [.talkOver, .interrupt])
    }

    // MARK: monologue

    func scaledMonologue() {
        config.local.monologueSoftS = 4
        config.local.monologueStrongS = 6
        config.local.monologueRelativeMinRuns = 1000
    }

    func testMonologueSoftThenStrong() throws {
        scaledMonologue()
        let evs = run(9, me: [(1.0, 8.5)], others: [])
        XCTAssertEqual(kinds(evs), [.monologue, .monologue])
        XCTAssertEqual(evs.map(\.level), [.soft, .strong])
        XCTAssertEqual(evs[0].onset, 1.0 + 4, accuracy: 0.05)
        XCTAssertEqual(evs[1].onset, 1.0 + 6, accuracy: 0.05)
    }

    /// The soft monologue fires on the frame the run reaches `monologue_soft_s`, wherever on the clock.
    func testMonologueFiresAtTheSoftLimitAnywhereOnTheClock() throws {
        scaledMonologue()
        let mic = Synthetic.track(6, [(1.0, 6.0)], f0: meF0)
        let call = Synthetic.track(6, [], f0: othersF0)
        var off: [Int] = []
        for k in 0..<100 {
            let start = k * 137
            let evs = Synthetic.runLocal(config, mic: mic, call: call, startFrame: start)
            let soft = try XCTUnwrap(evs.first { $0.kind == .monologue }, "no monologue from frame \(start)")
            if abs(soft.t - soft.onset) > 1e-9 { off.append(start) }
        }
        XCTAssertEqual(off, [], "the soft monologue fired a frame off a 4.00 s run from these start frames")
    }

    func testShortPausesDoNotResetTheRunButLongOnesDo() {
        scaledMonologue()
        config.local.monologueStrongS = 100
        // The run counts until the user has been quiet for monologue_me_gap_reset_s.
        XCTAssertEqual(kinds(run(8, me: [(1.0, 2.0), (3.0, 4.5)], others: [])), [.monologue], "a 1 s pause keeps the run going")
        XCTAssertEqual(kinds(run(10, me: [(1.0, 2.0), (5.5, 6.5)], others: [])), [], "a pause past the gap reset starts a new run")
    }

    func testTheOtherSideTakingTheFloorEndsTheRun() {
        scaledMonologue()
        config.local.monologueStrongS = 100
        XCTAssertEqual(kinds(run(10, me: [(1.0, 3.5), (5.0, 6.0)], others: [])), [.monologue])
        XCTAssertEqual(kinds(run(10, me: [(1.0, 3.5), (5.0, 6.0)], others: [(3.6, 4.9)])), [])
    }

    func testRelativeMonologueFiresEarlierThanTheAbsoluteOne() throws {
        config.local.monologueRelativeMinS = 3
        config.local.monologueMeGapResetS = 1.5
        let shortRuns: [(Double, Double)] = [(1.0, 2.2), (5.0, 6.2), (9.0, 10.2), (13.0, 14.2)]
        let evs = run(24, me: shortRuns + [(17.0, 23.0)], others: [])
        let mono = try XCTUnwrap(evs.first { $0.kind == .monologue })
        XCTAssertEqual(mono.level, .soft)
        let into = mono.onset - 17.0
        XCTAssertGreaterThanOrEqual(into, 3 - 0.05, "never under monologue_relative_min_s")
        XCTAssertLessThan(into, 5, "2.5 x the user's median run, far under the absolute threshold")
    }

    func testHowWhyQuestionRaisesBothThresholds() throws {
        scaledMonologue()
        let ctx = StubTextContext()
        ctx.howWhy = true
        let evs = run(11, me: [(1.0, 10.5)], others: [], context: ctx)
        XCTAssertEqual(evs.map(\.level), [.soft])
        XCTAssertEqual(evs.first?.onset ?? 0, 1.0 + 4 * config.local.monologueHowWhyRaise, accuracy: 0.05)
    }

    func testUpdateTurnInARoundIsExempt() {
        scaledMonologue()
        let ctx = StubTextContext()
        ctx.updateTurn = true
        XCTAssertEqual(kinds(run(9, me: [(1.0, 8.5)], others: [], participants: 4, context: ctx)), [])
    }

    func testRunLengthIsExposedForTheJudgeGate() {
        let layer = LocalLayer(config: config)
        let mic = Synthetic.track(3, [(0.5, 3.0)], f0: meF0), call = [Float](repeating: 0, count: mic.count)
        let hop = config.frameSamples
        for i in 0..<(mic.count / hop) {
            _ = layer.step(t: Double(i + 1) * config.frameS, mic: mic[(i * hop)..<((i + 1) * hop)], call: call[(i * hop)..<((i + 1) * hop)])
        }
        XCTAssertEqual(layer.meRunS(at: 3.0), 2.5, accuracy: 0.1)
    }

    // MARK: talk share

    func testTalkShareLimitDependsOnTheCallSize() throws {
        config.local.talkShareMinSpeechS = 3
        config.local.talkShareMaxOneOnOne = 1.0
        config.local.talkShareMaxGroup = 0.6
        config.local.monologueRelativeMinRuns = 1000
        XCTAssertEqual(kinds(run(8, me: [(0.5, 7.5)], others: [], participants: 2)), [])
        let evs = run(8, me: [(0.5, 7.5)], others: [], participants: 3)
        XCTAssertEqual(kinds(evs), [.talkShare])
        XCTAssertGreaterThan(evs.first?.share ?? 0, 0.6)
    }
}
