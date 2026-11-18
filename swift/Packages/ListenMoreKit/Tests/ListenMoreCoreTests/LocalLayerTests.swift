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

    func gapConfig(_ ms: Double) throws -> ListenMoreConfig {
        try ListenMoreConfig.load(overrides: ["local": ["cut_in_onset_gap_ms": ms]])
    }

    /// The pause scenario's live miss (judge on, after Resume, box run at e2e6b84): You start 0.24 s
    /// into a 0.46 s pause of theirs and they speak again 0.22 s after You's onset, inside
    /// `cut_in_onset_gap_ms`, so one long sentence cuts in from its first onset. At 200 ms it can't, and
    /// only a second onset while they talk cuts in.
    func testCutInStartingInTheirPauseRidesThroughIt() throws {
        let them: [(Double, Double)] = [(1.0, 4.2), (4.66, 9.2)]
        let cut = try XCTUnwrap(run(10, me: [(4.44, 7.4)], others: them).first { $0.kind == .interrupt })
        XCTAssertEqual(cut.onset, 4.44, accuracy: 0.05)
        XCTAssertFalse(cut.trailing)
        let tight = try gapConfig(200)
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
    /// 11.60 s inside one of those breaths, 0.30 s before they speak again: inside `cut_in_onset_gap_ms`
    /// with no margin, so the first onset cuts in, 1.2 s later. One frame tighter (280 ms) it can't, nor
    /// can the second onset (13.08 s, a 0.34 s breath after it), and the take misses.
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
        XCTAssertEqual(kinds(Synthetic.runLocal(try gapConfig(280), mic: Synthetic.track(18, you, f0: meF0),
                                                call: Synthetic.track(18, breaths, f0: othersF0))), [])
    }

    /// Them end at 4.0 s, You start at 4.1 s (`offset` later on the clock) and Them go on `fromOnset`
    /// after You's onset.
    func onsetPauseCut(fromOnset: Double, offset: Double = 0, config: ListenMoreConfig? = nil) -> [LocalEvent.Kind] {
        kinds(Synthetic.runLocal(config ?? self.config, mic: Synthetic.track(offset + 10, [(offset + 4.1, offset + 7.4)], f0: meF0),
                                 call: Synthetic.track(offset + 10, [(offset + 1.0, offset + 4.0), (offset + 4.1 + fromOnset, offset + 9.0)],
                                                       f0: othersF0)))
    }

    /// The pause the user's onset lands in: 0.30 s from the onset to their next word keeps the cut-in
    /// (`cut_in_onset_gap_ms`) and 0.32 s drops it, wherever on the clock; at 200 ms, 0.20 and 0.22 s.
    func testOnsetPauseRunsToTheToleranceFromTheOnset() throws {
        XCTAssertEqual(config.local.cutInOnsetGapMs, 300)
        for offset in [0.0, 10.0, 100.0] {
            XCTAssertEqual(onsetPauseCut(fromOnset: 0.30, offset: offset), [.interrupt], "0.30 s from the onset at offset \(offset)")
            XCTAssertEqual(onsetPauseCut(fromOnset: 0.32, offset: offset), [], "0.32 s from the onset at offset \(offset)")
        }
        let tight = try gapConfig(200)
        XCTAssertEqual(onsetPauseCut(fromOnset: 0.20, config: tight), [.interrupt])
        XCTAssertEqual(onsetPauseCut(fromOnset: 0.22, config: tight), [])
    }

    /// The same boundary with a single-frame VAD (`onset_frames` 1, `onset_window` 1, no onset smoothing):
    /// Them's restart is voiced the frame it starts, and the pause is measured to the start of that frame
    /// (0.30 s keeps the cut-in, 0.32 s drops it), not to the frame before it.
    func testOnsetPauseBoundaryWithASingleFrameVad() throws {
        let single = try ListenMoreConfig.load(overrides: ["vad": ["onset_frames": 1, "onset_window": 1]])
        for offset in [0.0, 10.0, 100.0] {
            XCTAssertEqual(onsetPauseCut(fromOnset: 0.30, offset: offset, config: single), [.interrupt], "0.30 s at offset \(offset)")
            XCTAssertEqual(onsetPauseCut(fromOnset: 0.32, offset: offset, config: single), [], "0.32 s at offset \(offset)")
        }
    }

    /// Them voiced, quiet, then voiced again after You's onset (one speech burst of 0.02 s, 0.02 s of
    /// silence, then their restart 0.04 s after the burst starts): their VAD dates the speech from the
    /// burst, and the pause is measured to it, so 0.30 s from the onset to the burst keeps the cut-in
    /// and 0.32 s drops it. Measured to the frame after the burst, 0.28 and 0.30 s would drop it.
    func testFlickerBeforeTheirRestartGetsTheFullTolerance() {
        func cut(burstAt d: Double) -> [LocalEvent.Kind] {
            let sr = Double(Synthetic.sr)
            func at(_ t: Double) -> Int { Int((t * sr).rounded()) }
            var call = Synthetic.track(10, [(1.0, 4.0)], f0: othersF0)
            let burst = Synthetic.speechish(0.02, seed: 9, f0: othersF0)
            for j in burst.indices { call[at(4.1 + d) + j] = burst[j] }
            let restart = Synthetic.speechish(9.0 - (4.1 + d + 0.04), seed: 3, f0: othersF0)
            for j in restart.indices { call[at(4.1 + d + 0.04) + j] = restart[j] }
            return kinds(Synthetic.runLocal(config, mic: Synthetic.track(10, [(4.1, 7.4)], f0: meF0), call: call))
        }
        XCTAssertEqual(cut(burstAt: 0.28), [.interrupt])
        XCTAssertEqual(cut(burstAt: 0.30), [.interrupt])
        XCTAssertEqual(cut(burstAt: 0.32), [])
        XCTAssertEqual(cut(burstAt: 0.34), [])
    }

    /// You's onset next to Them's last word: they count as speaking for `LocalLayer.speakingTailS` after
    /// their last voiced frame, and the cut-in starts when You's VAD has confirmed the onset. An onset
    /// within 0.02 s of Them's last voiced frame (default 2-of-3 VAD), 0.04 s (single-frame VAD) or
    /// 0.00 s (3-of-3) doesn't land in a pause: Them still count as speaking, no tolerance applies and
    /// Them's next pause gets the 0.16 s of any pause (their restart 0.26 s after You's onset drops the
    /// cut-in). Only an onset further out than that lands in a pause and gets the onset tolerance.
    func testOnsetNextToTheirLastWordGetsNoTolerance() throws {
        func cut(_ vad: [String: Any], d: Double) throws -> [LocalEvent.Kind] {
            let c = try ListenMoreConfig.load(overrides: ["vad": vad])
            let on = 4.0 + d
            return kinds(Synthetic.runLocal(c, mic: Synthetic.track(10, [(on, on + 3.3)], f0: meF0),
                                            call: Synthetic.track(10, [(1.0, 4.0), (on + 0.26, 9.0)], f0: othersF0)))
        }
        let cases: [(String, [String: Any], Double)] = [("2 of 3", [:], 0.02), ("1 of 1", ["onset_frames": 1, "onset_window": 1], 0.04),
                                                         ("3 of 3", ["onset_frames": 3, "onset_window": 3], 0.0)]
        for (name, vad, nearest) in cases {
            XCTAssertEqual(try cut(vad, d: nearest), [], "\(name): onset \(nearest) s after their last voiced frame, no tolerance")
            XCTAssertEqual(try cut(vad, d: nearest + 0.02), [.interrupt], "\(name): one frame further out, tolerance applies")
        }
    }

    /// `pendingOnset` is the earliest voiced frame the VAD is still weighing, not the latest: with
    /// `onset_frames` 3, voiced, quiet, voiced is two of three, still pending from the first frame; one
    /// more voiced frame later it is still the first of the two. Three voiced frames in the window
    /// confirm it, back-dated to the earliest, and nothing is pending any more.
    func testPendingOnsetIsTheEarliestVoicedFrame() throws {
        let vad = StreamVAD(config: try ListenMoreConfig.load(overrides: ["vad": ["onset_frames": 3, "onset_window": 4]]))
        let voiced = Synthetic.speechish(0.02, seed: 5, f0: othersF0)
        let quiet = [Float](repeating: 0, count: voiced.count)
        func feed(_ frame: [Float], _ k: Int) -> VadState { vad.process(tEnd: Double(k + 1) * 0.02, frame: frame[...]) }
        XCTAssertNil(vad.pendingOnset)
        XCTAssertTrue(feed(voiced, 0).raw)
        XCTAssertEqual(try XCTUnwrap(vad.pendingOnset), 0.0, accuracy: 1e-9)
        _ = feed(quiet, 1)
        XCTAssertEqual(try XCTUnwrap(vad.pendingOnset), 0.0, accuracy: 1e-9)
        _ = feed(voiced, 2)
        XCTAssertEqual(try XCTUnwrap(vad.pendingOnset), 0.0, accuracy: 1e-9, "two voiced frames in the window: the first")
        let st = feed(voiced, 3)
        XCTAssertEqual(st.onset ?? -1, 0.0, accuracy: 1e-9, "three confirm it, back-dated to the first")
        XCTAssertNil(vad.pendingOnset)
    }

    /// Only the pause the onset lands in: once they speak again, their next pause gets
    /// `cutInMaxOthersGapS`, so a 0.22 s breath after 0.3 s of words drops the cut-in (a trailing
    /// candidate that their return ends). Talking at the onset, a 0.22 s breath 0.1 s later drops it too.
    func testOnlyThePauseTheOnsetLandsInRunsLong() {
        XCTAssertEqual(kinds(run(10, me: [(4.1, 7.4)], others: [(1.0, 4.0), (4.3, 9.0)])), [.interrupt])
        XCTAssertEqual(kinds(run(10, me: [(4.1, 7.4)], others: [(1.0, 4.0), (4.3, 4.6), (4.82, 9.0)])), [])
        XCTAssertEqual(kinds(run(10, me: [(3.2, 6.5)], others: [(1.0, 3.3), (3.52, 7.0)])), [])
    }

    /// You start at 3.2 s while Them talk, and Them breathe 0.20 s (3.26-3.46 s) with their restart only
    /// 0.26 s from You's onset: inside the onset tolerance's reach, but the onset didn't land in a pause,
    /// so the breath gets `cutInMaxOthersGapS` (0.16 s) and the cut-in drops, tolerance or not.
    func testOnsetTolerancePausesDoNotApplyWhenThemWereTalkingAtTheOnset() throws {
        let them: [(Double, Double)] = [(1.0, 3.26), (3.46, 9.0)]
        XCTAssertEqual(kinds(run(10, me: [(3.2, 6.5)], others: them)), [])
        XCTAssertEqual(kinds(Synthetic.runLocal(try gapConfig(0), mic: Synthetic.track(10, [(3.2, 6.5)], f0: meF0),
                                                call: Synthetic.track(10, them, f0: othersF0))), [])
    }

    /// A lone voiced frame on their side after their VAD has let go (a click) never becomes speech, so it
    /// doesn't end the pause the onset landed in: 0.36 s to their next word drops the cut-in, click or no
    /// click; 0.30 s keeps it.
    func testClickDoesNotEndTheOnsetPause() {
        func cut(fromOnset: Double) -> [LocalEvent.Kind] {
            let mic = Synthetic.track(10, [(4.1, 7.4)], f0: meF0)
            var call = Synthetic.track(10, [(1.0, 4.0), (4.1 + fromOnset, 9.0)], f0: othersF0)
            let click = Synthetic.speechish(0.02, seed: 9, f0: othersF0)
            let at = Int(4.24 * Double(Synthetic.sr))
            for j in click.indices { call[at + j] = click[j] }
            return kinds(Synthetic.runLocal(config, mic: mic, call: call))
        }
        XCTAssertEqual(cut(fromOnset: 0.36), [])
        XCTAssertEqual(cut(fromOnset: 0.30), [.interrupt])
    }

    /// The trailing candidate keeps their last word's end when a click lands 0.24 s after it, past
    /// their VAD's hangover and after the candidate was made.
    func testTrailingCandidateKeepsTheirLastWordPastAClick() throws {
        let mic = Synthetic.track(8, [(3.0, 6.5)], f0: meF0)
        var call = Synthetic.track(8, [(1.0, 3.46)], f0: othersF0)
        let click = Synthetic.speechish(0.02, seed: 9, f0: othersF0)
        let at = Int(3.70 * Double(Synthetic.sr))
        for j in click.indices { call[at + j] = click[j] }
        let cut = try XCTUnwrap(Synthetic.runLocal(config, mic: mic, call: call).first { $0.kind == .interrupt })
        XCTAssertTrue(cut.trailing)
        XCTAssertEqual(cut.othersLastSpeech ?? 0, 3.46, accuracy: 0.03)
    }

    /// Pause time adds nothing to the opening overlap: 0.3 s of overlap, a 0.16 s pause (kept), and
    /// 0.14 s more stay under 0.6 s, and they stop for good, so it is a trailing candidate.
    func testPauseTimeIsNotOverlap() throws {
        let cut = try XCTUnwrap(run(9, me: [(3.2, 6.5)], others: [(1.0, 3.5), (3.66, 3.80)]).first)
        XCTAssertTrue(cut.trailing)
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
