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

    /// A gap in the other side's speech during the cut-in's opening overlap: one of
    /// `LocalLayer.cutInMaxOthersGapS` (0.16 s) keeps the cut-in, one frame more (0.18 s) drops it, at
    /// any point on the clock (absolute times change how frame-time differences round).
    func testCutInSurvivesThemGapUpToTheTolerance() {
        XCTAssertEqual(LocalLayer.cutInMaxOthersGapS, 0.16, accuracy: 1e-12)
        for offset in [0.0, 10.0, 100.0] {
            func cut(gap: Double) -> [LocalEvent.Kind] {
                kinds(run(offset + 9, me: [(offset + 3.2, offset + 6.5)],
                          others: [(offset + 1.0, offset + 3.5), (offset + 3.5 + gap, offset + 7.0)]))
            }
            XCTAssertEqual(cut(gap: 0.16), [.interrupt], "a 0.16 s gap at offset \(offset)")
            XCTAssertEqual(cut(gap: 0.18), [], "a 0.18 s gap at offset \(offset)")
        }
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

    /// The pause scenario's live miss (judge on, after Resume): You start 0.24 s into a 0.46 s pause of
    /// theirs, so the opening overlap can't build and one long sentence never cuts in. Broken into two
    /// sentences, the second onset lands while they talk and cuts in.
    func testCutInStartingInTheirPauseNeedsASecondOnset() throws {
        let them: [(Double, Double)] = [(1.0, 4.2), (4.66, 9.2)]
        XCTAssertEqual(kinds(run(10, me: [(4.44, 7.4)], others: them)), [])
        let cut = try XCTUnwrap(run(10, me: [(4.44, 5.4), (5.85, 8.0)], others: them).first { $0.kind == .interrupt })
        XCTAssertEqual(cut.onset, 5.85, accuracy: 0.05)
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
