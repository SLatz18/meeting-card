import Foundation
import XCTest
@testable import ListenMoreCore

/// `cut_in_overlap_gap_ms` against what it can change. Cut-ins replayed from stored live takes (voicing
/// from each take's shadow-trace diagnostics) must cut in, in the oracle's window. Backchannels from the
/// other side while the user talks, the other side yielding the floor, and short overlaps must raise no
/// cut-in; a trailing candidate is allowed there, since the engine fires one only on unfinished last words.
/// The committed tests hold the built-in value; `LM_OVERLAP_GAP_SWEEP=1` prints the cases across values
/// (160-600 ms, or the comma-separated list in `LM_OVERLAP_GAP_SWEEP_MS`).
final class OverlapGapTests: XCTestCase {
    typealias Spans = [(Double, Double)]

    struct Case {
        var group: String
        var name: String
        var total: Double
        var me: Spans
        var others: Spans
        /// Mic off at the first time, back on at the second.
        var mute: (Double, Double)? = nil
        /// A cut-in must fire inside this window (scenario seconds); nil: no cut-in may fire.
        var window: ClosedRange<Double>? = nil
    }

    struct Outcome {
        var cutIns: [LocalEvent]
        var trailing: [LocalEvent]
    }

    static let meF0 = 120.0, othersF0 = 210.0

    nonisolated(unsafe) static var audio: [String: ([Float], [Float])] = [:]

    static func run(_ c: Case, config: ListenMoreConfig) -> Outcome {
        let key = "\(c.group)|\(c.name)"
        let (mic, call) = audio[key] ?? (Synthetic.track(c.total, c.me, f0: meF0), Synthetic.track(c.total, c.others, f0: othersF0))
        audio[key] = (mic, call)
        let layer = LocalLayer(config: config)
        let hop = config.frameSamples
        var interrupts: [LocalEvent] = []
        for i in 0..<(min(mic.count, call.count) / hop) {
            let tStart = Double(i) * config.frameS
            if let m = c.mute {
                if abs(tStart - m.0) < config.frameS / 2 { layer.setMicMuted(true) }
                if abs(tStart - m.1) < config.frameS / 2 { layer.setMicMuted(false) }
            }
            let r = layer.step(t: tStart + config.frameS, mic: mic[(i * hop)..<((i + 1) * hop)], call: call[(i * hop)..<((i + 1) * hop)])
            interrupts += r.events.filter { $0.kind == .interrupt }
        }
        return Outcome(cutIns: interrupts.filter { !$0.trailing }, trailing: interrupts.filter(\.trailing))
    }

    /// A replayed take's verdict: its first cut-in is in the window (later ones fall in the interrupt's
    /// cooldown), and nothing cuts in before it.
    static func onTime(_ o: Outcome, _ w: ClosedRange<Double>) -> Bool {
        o.cutIns.first.map { w.contains($0.t) } ?? false
    }

    /// Stored live takes that could be replayed: the voicing the diagnostics give (You's onsets, Them's
    /// longest gap in the 0.6 s after each, and at 0390f5e every pause of 0.2 s or more). Times are the
    /// takes' own scenario seconds; windows are the oracle's.
    static let liveTakes: [Case] = [
        // 05:08 run (0390f5e), judge on: Them's breaths from the shadow trace's quiet stretches, exact to the
        // frame for pauses of 0.2 s or more; 0.14 s after 13.08 s from the gap note. Missed at 01809d9.
        Case(group: "live", name: "05:08 judge-on cost-cap y2 (missed)", total: 18,
             me: [(11.60, 12.72), (13.08, 17.4)],
             others: [(8.3, 9.64), (9.90, 11.46), (11.90, 12.52), (12.74, 13.30), (13.44, 13.66), (14.00, 14.64), (14.86, 15.6)],
             window: 12.21...14.81),
        // 03:41 run (e2e6b84), judge on: You onset 1.74 s (no Them gap in 0.6 s) and 2.60 s (Them gap 0.20 s);
        // the oracle measured a 0.36 s Them pause, which places it at 2.44-2.80 s. You's first words end
        // and pause past 0.5 s before 2.60 s (the first onset raised nothing). Reconstructed; missed.
        Case(group: "live", name: "03:41 judge-on pause y1 (missed)", total: 6,
             me: [(1.74, 2.00), (2.60, 3.90)], others: [(0.4, 2.44), (2.80, 5.2)], window: 2.29...4.89),
        // 03:41 run, judge on, after Resume: You onset 34.44 s with Them quiet (VAD let go), back 0.22 s
        // later, the same take `testCutInStartingInTheirPauseRidesThroughIt` replays. Missed.
        Case(group: "live", name: "03:41 judge-on pause y3 (missed)", total: 39,
             me: [(34.44, 38.6)], others: [(31.0, 34.20), (34.66, 38.44)], window: 35.04...37.64),
        // 05:08 run, judge on, mute-unmute y5: every pause of 0.2 s or more from the shadow trace. The shadow
        // cut in at 39.20 s (the engine's cue policy held it): it must not move.
        Case(group: "live", name: "05:08 judge-on mute-unmute y5 (shadow fired)", total: 43,
             me: [(38.00, 38.24), (38.62, 39.64), (40.02, 42.0)],
             others: [(33.0, 35.86), (36.26, 36.94), (37.14, 40.02), (40.36, 42.6)], window: 38.61...41.21),
        // 03:41 run, mute-unmute first words back after Unmute (the takes MicMuteTests replays): You's
        // comma onsets over Them's comma pause raised false interrupts at e2e6b84. Nothing may cut in.
        Case(group: "live", name: "03:41 judge-off first words back (false at e2e6b84)", total: 34,
             me: [(28.28, 28.80), (29.12, 29.94), (30.38, 32.5)], others: [(25.98, 28.56), (29.16, 31.9)], mute: (0, 27.98)),
        Case(group: "live", name: "03:41 judge-on first words back (false at e2e6b84)", total: 34,
             me: [(28.36, 29.70), (30.12, 32.3)], others: [(26.04, 28.50), (29.06, 31.9)], mute: (0, 28.06)),
    ]

    /// 22:45 run (1b435dc), judge on, interruption and no-key (the same audio), before the oracle flagged
    /// pauses: You onsets 10.66 s (Them gap 0.02 s in the next 0.6 s), 11.60 s (0.26 s) and 12.90 s
    /// (0.24 s), missed. Where in each 0.6 s the gaps fell isn't stored, so this can't be replayed: the
    /// sweep shows the two ends, each gap right after its onset and as late as it can be.
    static let unplacedTake: [Case] = [(11.62, 12.92, "right after"), (11.94, 13.24, "as late as possible")].map { g1, g2, where_ in
        Case(group: "live (unplaced)", name: "22:45 judge-on interruption y3, gaps \(where_) the onsets", total: 16,
             me: [(10.66, 10.96), (11.60, 12.62), (12.90, 14.4)],
             others: [(6.0, g1), (g1 + 0.26, g2), (g2 + 0.24, 14.16)], window: 11.26...13.86)
    }

    static let tokens: [(name: String, spans: Spans)] = [
        ("mm-hm", [(0, 0.18), (0.26, 0.48)]), ("yeah", [(0, 0.30)]), ("right", [(0, 0.34)]),
    ]

    static func at(_ t: Double, _ token: Spans) -> Spans { token.map { (t + $0.0, t + $0.1) } }
    static func f(_ x: Double) -> String { String(format: "%.2f", x) }

    /// Them say "mm-hm", "yeah" or "right" while You hold the floor: over You's words, in You's breath with
    /// You resuming over it, and two in a row with a pause between them.
    static var backchannels: [Case] {
        var out: [Case] = []
        for tok in tokens {
            for t0 in [3.0, 5.0] {
                out.append(Case(group: "backchannel", name: "\(tok.name) at \(f(t0)) over You's words", total: 10,
                                me: [(1.0, 9.0)], others: at(t0, tok.spans)))
            }
            for breath in [0.3, 0.5] {
                let resume = 4.0 + breath
                for into in [-0.1, 0.0, 0.1, 0.2, 0.3] {
                    out.append(Case(group: "backchannel", name: "\(tok.name) in a \(f(breath)) s breath, You back \(f(into)) s into it",
                                    total: 10, me: [(1.0, 4.0), (resume, 9.0)], others: at(resume - into, tok.spans)))
                }
            }
        }
        let pairs = [("yeah", "yeah"), ("mm-hm", "right"), ("right", "yeah"), ("yeah", "mm-hm")]
        for (a, b) in pairs {
            let first = tokens.first { $0.name == a }!.spans, second = tokens.first { $0.name == b }!.spans
            for gap in [0.1, 0.2, 0.3, 0.4, 0.5] {
                for into in [0.0, 0.1] {
                    let start = 4.4 - into
                    let secondAt = start + first.last!.1 + gap
                    out.append(Case(group: "backchannel", name: "\(a), \(f(gap)) s, \(b); You back \(f(into)) s into it",
                                    total: 10, me: [(1.0, 4.0), (4.4, 9.0)], others: at(start, first) + at(secondAt, second)))
                }
            }
        }
        return out
    }

    /// Them finish their turn and You take the floor: You start up to `cut_in_others_pause_ms` after their
    /// last word, and they add nothing, or one acknowledgment ("mm-hm", "yeah", "right") or two, after
    /// another pause.
    static var yields: [Case] {
        var out: [Case] = []
        for d in [0.02, 0.10, 0.20, 0.28] {
            out.append(Case(group: "yield", name: "You start \(f(d)) s after their last word", total: 10,
                            me: [(4.0 + d, 9.0)], others: [(1.0, 4.0)]))
            for tok in tokens {
                for p in [0.2, 0.3, 0.4, 0.5, 0.6] where p > d {
                    out.append(Case(group: "yield", name: "You start \(f(d)) s after; \(tok.name) \(f(p)) s after their last word",
                                    total: 10, me: [(4.0 + d, 9.0)], others: [(1.0, 4.0)] + at(4.0 + p, tok.spans)))
                }
            }
            for p in [0.3, 0.5] where p > d {
                let yeah = tokens[1].spans, right = tokens[2].spans
                out.append(Case(group: "yield", name: "You start \(f(d)) s after; yeah, right \(f(p)) s after their last word",
                                total: 10, me: [(4.0 + d, 9.0)], others: [(1.0, 4.0)] + at(4.0 + p, yeah) + at(4.0 + p + 0.5, right)))
            }
        }
        return out
    }

    /// Not scored: Them finish, You start in the gap, and Them start a new sentence anyway. To the audio
    /// this is the breath the tolerance rides through (Them pause, You start inside it, Them go on), so it
    /// cuts in once their restart is within the tolerance of You's onset, whichever of them took the floor.
    static var reclaims: [Case] {
        var out: [Case] = []
        for d in [0.02, 0.10, 0.20, 0.28] {
            for p in [0.3, 0.4, 0.5, 0.6, 0.7] where p > d {
                out.append(Case(group: "reclaim", name: "You start \(f(d)) s after their last word, they go on \(f(p)) s after it",
                                total: 10, me: [(4.0 + d, 9.0)], others: [(1.0, 4.0), (4.0 + p, 7.0)]))
            }
        }
        return out
    }

    /// Overlaps that aren't cut-ins: You's own backchannel over their words (under
    /// `cut_in_backchannel_max_ms`), including across a breath of theirs, and You starting as they finish.
    static var shortOverlaps: [Case] {
        var out: [Case] = []
        let mine: [(String, Spans)] = [("yeah", [(0, 0.30)]), ("mm-hm", [(0, 0.18), (0.26, 0.48)]),
                                        ("right, right", [(0, 0.34), (0.5, 0.84)]), ("yeah, that's fair", [(0, 1.0)])]
        for (name, spans) in mine {
            out.append(Case(group: "short overlap", name: "You say \(name) over their words", total: 10,
                            me: at(3.0, spans), others: [(1.0, 8.0)]))
            out.append(Case(group: "short overlap", name: "You say \(name) across a 0.26 s breath of theirs", total: 10,
                            me: at(3.0, spans), others: [(1.0, 3.2), (3.46, 8.0)]))
        }
        for o in [0.1, 0.2, 0.3, 0.45] {
            out.append(Case(group: "short overlap", name: "You start \(f(o)) s before their last word ends", total: 10,
                            me: [(4.0 - o, 9.0)], others: [(1.0, 4.0)]))
        }
        return out
    }

    func config(gapMs: Double? = nil) throws -> ListenMoreConfig {
        try ListenMoreConfig.load(overrides: gapMs.map { ["local": ["cut_in_overlap_gap_ms": $0]] } ?? [:])
    }

    func testReplayedLiveTakesCutInInTheirWindows() throws {
        let c = try config()
        for take in Self.liveTakes {
            let o = Self.run(take, config: c)
            if let w = take.window {
                XCTAssertTrue(Self.onTime(o, w), "\(take.name): \(o.cutIns.map { Self.f($0.t) }) against \(w)")
            } else {
                XCTAssertEqual(o.cutIns.count + o.trailing.count, 0, take.name)
            }
        }
    }

    /// At 160 ms (01809d9's tolerance) the missed takes miss again, and the shadow's fire stays put.
    func testReplayedLiveTakesAtTheOldTolerance() throws {
        let old = try config(gapMs: 160)
        let fired = Self.liveTakes.filter { !Self.run($0, config: old).cutIns.isEmpty }.map(\.name)
        XCTAssertEqual(fired, ["05:08 judge-on mute-unmute y5 (shadow fired)"])
        let shadow = try XCTUnwrap(Self.liveTakes.last { $0.name.hasPrefix("05:08 judge-on mute-unmute") })
        XCTAssertEqual(Self.run(shadow, config: try config()).cutIns.first?.t ?? 0, 39.20, accuracy: 0.03)
    }

    /// Only two backchannels 0.10 s apart cut in: their VAD hears one stretch of speech (under
    /// `overlapStretchGapS`), as 01809d9's 0.16 s tolerance did. Nothing else here does.
    func testBackchannelsYieldsAndShortOverlapsRaiseNoNewCutIn() throws {
        let c = try config()
        XCTAssertEqual([Self.backchannels.count, Self.yields.count, Self.shortOverlaps.count], [76, 66, 12])
        let cases = Self.backchannels + Self.yields + Self.shortOverlaps
        let cutIns = cases.filter { !Self.run($0, config: c).cutIns.isEmpty }.map(\.name)
        let pairs = [("yeah", "yeah"), ("mm-hm", "right"), ("right", "yeah"), ("yeah", "mm-hm")]
        XCTAssertEqual(cutIns, pairs.flatMap { a, b in [0.0, 0.1].map { "\(a), 0.10 s, \(b); You back \(Self.f($0)) s into it" } })
    }

    /// 06:29 run (01809d9), judge on, interruption and no-key, from the shadow trace: You's own comma
    /// pauses (0.56 s and 0.52 s, past `cut_in_utterance_gap_ms`) end the cut-ins from 10.68 s and 11.96 s
    /// before the backchannel length; Them's 0.22 s quiet is beside the point. Their pause tolerance
    /// leaves the miss as it was: the third onset cuts in at 14.66 s, after the 11.28-13.88 s window.
    func testYouSideCommaPausesAreNotTheirPauses() throws {
        let take = Case(group: "live", name: "06:29 judge-on interruption y3", total: 16,
                        me: [(10.68, 11.40), (11.96, 12.94), (13.46, 15.0)],
                        others: [(6.0, 9.98), (10.40, 12.94), (13.16, 14.18)], window: 11.28...13.88)
        for c in [try config(), try config(gapMs: 160)] {
            let cut = try XCTUnwrap(Self.run(take, config: c).cutIns.first)
            XCTAssertEqual(cut.onset, 13.46, accuracy: 0.03)
            XCTAssertEqual(cut.t, 14.66, accuracy: 0.03)
        }
    }

    /// The table behind the chosen value: per value, the replayed takes that cut in on time, the
    /// cut-ins raised on cases that must have none, and the unscored groups.
    func testSweep() throws {
        guard ProcessInfo.processInfo.environment["LM_OVERLAP_GAP_SWEEP"] == "1" else {
            throw XCTSkip("set LM_OVERLAP_GAP_SWEEP=1 to print the sweep")
        }
        let scored = Self.liveTakes.filter { $0.window != nil }
        let quiet = Self.backchannels + Self.yields + Self.shortOverlaps
        var lines = ["| cut_in_overlap_gap_ms | live takes on time | live early cut-ins | live false cut-ins | backchannel cut-ins | yield cut-ins | short-overlap cut-ins | trailing candidates (quiet set) | 22:45 unplaced on time | reclaim cut-ins (unscored) |",
                     "|---|---|---|---|---|---|---|---|---|---|"]
        var detail: [String] = []
        let values = ProcessInfo.processInfo.environment["LM_OVERLAP_GAP_SWEEP_MS"].map { $0.split(separator: ",").compactMap { Double($0) } }
            ?? Array(stride(from: 160.0, through: 600.0, by: 20.0))
        for ms in values {
            let c = try config(gapMs: ms)
            var onTime = 0, misses: [String] = [], early: [String] = [], falseCuts: [String] = []
            for take in Self.liveTakes {
                let o = Self.run(take, config: c)
                guard let w = take.window else {
                    if !(o.cutIns + o.trailing).isEmpty { falseCuts.append(take.name) }
                    continue
                }
                if Self.onTime(o, w) { onTime += 1 } else { misses.append(take.name) }
                early += o.cutIns.filter { $0.t < w.lowerBound }.map { "\(take.name) @\(Self.f($0.t))" }
            }
            var byGroup: [String: [String]] = [:]
            var trailing = 0
            for q in quiet {
                let o = Self.run(q, config: c)
                trailing += o.trailing.count
                if !o.cutIns.isEmpty { byGroup[q.group, default: []].append(q.name) }
            }
            let unplaced = Self.unplacedTake.filter { Self.onTime(Self.run($0, config: c), $0.window!) }.count
            let reclaimed = Self.reclaims.filter { !Self.run($0, config: c).cutIns.isEmpty }
            let n = { (g: String) in byGroup[g]?.count ?? 0 }
            lines.append("| \(Int(ms)) | \(onTime)/\(scored.count) | \(early.count) | \(falseCuts.count) | \(n("backchannel")) | \(n("yield")) | \(n("short overlap")) | \(trailing) | \(unplaced)/\(Self.unplacedTake.count) | \(reclaimed.count)/\(Self.reclaims.count) |")
            detail.append("\(Int(ms)) ms: misses \(misses); early \(early); false \(falseCuts); cut-ins \(byGroup.sorted { $0.key < $1.key }); reclaims \(reclaimed.map(\.name))")
        }
        let text = (lines + [""] + detail).joined(separator: "\n")
        print(text)
        if let path = ProcessInfo.processInfo.environment["LM_OVERLAP_GAP_SWEEP_OUT"] {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
