import Foundation
import XCTest
@testable import ListenMoreCore

/// `cut_in_onset_gap_ms` against what it can change. Cut-ins replayed from stored live takes (voicing
/// from each take's shadow-trace diagnostics) must cut in, in the oracle's window. On the sets that must
/// stay quiet (backchannels from the other side while the user talks, backchannel chains, the other side
/// yielding the floor, acknowledging and then taking it back, clicks in their pauses, short overlaps),
/// the built-in value may raise no cut-in that 01809d9 didn't (`OverlapGapGolden`); a trailing candidate
/// is allowed, since the engine fires one only on unfinished last words. At 0 the rule is 01809d9's on
/// every case. `LM_OVERLAP_GAP_SWEEP=1` prints the curve (or the values in `LM_OVERLAP_GAP_SWEEP_MS`);
/// `LM_OVERLAP_GAP_GOLDEN_OUT=path` writes every case's signature (run at 01809d9 to rebuild the golden).
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
        /// One-frame clicks on their side at these times.
        var clicks: [Double] = []

        var key: String { "\(group)|\(name)" }
    }

    struct Outcome {
        var cutIns: [LocalEvent]
        var trailing: [LocalEvent]

        /// "C@t" per cut-in, "T@t" per trailing candidate, "-" for none.
        var signature: String {
            let all = (cutIns + trailing).sorted { $0.t < $1.t }
            return all.isEmpty ? "-" : all.map { ($0.trailing ? "T@" : "C@") + String(format: "%.2f", $0.t) }.joined(separator: ",")
        }
    }

    static let meF0 = 120.0, othersF0 = 210.0

    nonisolated(unsafe) static var audio: [String: ([Float], [Float])] = [:]

    static func run(_ c: Case, config: ListenMoreConfig) -> Outcome {
        let (mic, call) = audio[c.key] ?? {
            var call = Synthetic.track(c.total, c.others, f0: othersF0)
            for (k, at) in c.clicks.enumerated() {
                let click = Synthetic.speechish(0.02, seed: 9 + k, f0: othersF0)
                let i0 = Int(at * Double(Synthetic.sr))
                for j in click.indices where i0 + j < call.count { call[i0 + j] = click[j] }
            }
            return (Synthetic.track(c.total, c.me, f0: meF0), call)
        }()
        audio[c.key] = (mic, call)
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
    /// (0.24 s), missed. Where in each 0.6 s the gaps fell isn't stored: here at the two ends, right after
    /// each onset and as late as it can be. Them were talking at each onset, so these are breaths after
    /// the onset, which `cut_in_onset_gap_ms` doesn't cover: a known limit.
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
    /// this is the breath the onset tolerance rides through (Them pause, You start inside it, Them go on),
    /// so it cuts in once their restart is within the tolerance of You's onset, whoever took the floor.
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

    static let reviewTokens: [String: Spans] = ["yeah": [(0, 0.30)], "right": [(0, 0.34)], "okay": [(0, 0.32)],
                                                "mm-hm": [(0, 0.18), (0.26, 0.48)], "uh-huh": [(0, 0.14), (0.22, 0.40)]]

    /// Backchannel chains of 3-4 words from Them over You's speech, gaps uniform or mixed, with You talking
    /// straight through or coming back from a breath into the first word.
    static var chains: [Case] {
        var out: [Case] = []
        let chains: [[String]] = [["yeah", "right", "okay"], ["mm-hm", "yeah", "right"], ["okay", "okay", "okay", "okay"],
                                  ["uh-huh", "uh-huh", "yeah"], ["right", "mm-hm", "yeah", "okay"]]
        for ch in chains {
            for gaps in [[0.18], [0.22], [0.26], [0.30], [0.14, 0.26], [0.26, 0.14], [0.16, 0.18, 0.16]] {
                var t = 3.0, spans: Spans = []
                for (k, w) in ch.enumerated() {
                    spans += at(t, reviewTokens[w]!)
                    t += reviewTokens[w]!.last!.1 + gaps[k % gaps.count]
                }
                let name = "\(ch.joined(separator: "/")) gaps \(gaps.map(f).joined(separator: "/"))"
                out.append(Case(group: "chain", name: name, total: 10, me: [(1.0, 9.0)], others: spans))
                out.append(Case(group: "chain", name: name + ", You back into it", total: 10, me: [(1.0, 2.9), (3.2, 9.0)], others: spans))
            }
        }
        return out
    }

    /// Them's long sentence with breaths after phrase `L`; You cut in 0.1 or 0.3 s into a phrase, or mid-breath,
    /// and keep going 4 s. Reported, not scored: these are the cut-ins a breath tolerance is for.
    static var breathy: [Case] {
        var out: [Case] = []
        for L in [0.40, 0.50, 0.56, 0.62, 0.70, 0.90] {
            for b in [0.18, 0.22, 0.26, 0.30, 0.34] {
                var spans: Spans = [(0.5, 3.0)]
                var t = 3.0 + b
                while t < 9 { spans.append((t, min(9, t + L))); t += L + b }
                for into in [0.1, 0.3] {
                    let on = spans[1].0 + into
                    out.append(Case(group: "breathy", name: "phrases \(f(L)) breaths \(f(b)), You \(f(into)) into a phrase", total: 10,
                                    me: [(on, on + 4)], others: spans))
                }
                let on = 3.0 + b / 2
                out.append(Case(group: "breathy", name: "phrases \(f(L)) breaths \(f(b)), You mid-breath", total: 10, me: [(on, on + 4)], others: spans))
            }
        }
        return out
    }

    /// Them end at 4.0, You start `d` later, Them go on `r` after You's onset. Reported, not scored.
    static var reclaimGrid: [Case] {
        var out: [Case] = []
        for d in stride(from: 0.02, through: 0.30, by: 0.04) {
            for r in stride(from: 0.06, through: 0.46, by: 0.02) {
                out.append(Case(group: "reclaim grid", name: "d \(f(d)) r \(f(r))", total: 10, me: [(4.0 + d, 9.0)],
                                others: [(1.0, 4.0), (4.0 + d + r, 7.5)]))
            }
        }
        return out
    }

    /// Clicks in their pause: a train through a 0.8 s silence they come back from or not, and a two-frame
    /// click in a 0.5 s breath.
    static var clickTrains: [Case] {
        var out: [Case] = []
        for sp in [0.16, 0.18, 0.20, 0.24] {
            let clicks = Array(stride(from: 3.5 + sp, to: 4.3, by: sp))
            out.append(Case(group: "click", name: "breath 0.80 with clicks every \(f(sp))", total: 10, me: [(3.2, 6.5)],
                            others: [(1.0, 3.5), (4.3, 7.0)], clicks: clicks))
            out.append(Case(group: "click", name: "Them yield, clicks every \(f(sp)), You talk on", total: 10, me: [(3.2, 6.5)],
                            others: [(1.0, 3.5)], clicks: clicks))
        }
        out.append(Case(group: "click", name: "two-frame click mid 0.5 breath", total: 10, me: [(3.2, 6.5)],
                        others: [(1.0, 3.5), (3.74, 3.78), (4.0, 7.0)]))
        return out
    }

    /// Them stop for good after short words over You.
    static var trailingStops: [Case] {
        var out: [Case] = []
        for g in [0.18, 0.24, 0.30] {
            out.append(Case(group: "trailing stop", name: "phrase then yeah after \(f(g)) then stop", total: 10, me: [(3.2, 8.0)],
                            others: [(1.0, 3.5)] + at(3.5 + g, reviewTokens["yeah"]!)))
            out.append(Case(group: "trailing stop", name: "yeah, \(f(g)), right over You then stop", total: 10, me: [(1.0, 8.0)],
                            others: at(3.0, reviewTokens["yeah"]!) + at(3.3 + g, reviewTokens["right"]!)))
        }
        return out
    }

    /// Them end at 4.0, You start `d` later, Them say "yeah" `a` after that and go on `g` after it.
    static var ackReclaims: [Case] {
        var out: [Case] = []
        for d in [0.05, 0.15, 0.25] {
            for a in [0.15, 0.25] {
                for g in [0.18, 0.24, 0.30] {
                    let y = 4.0 + d + a
                    out.append(Case(group: "ack then reclaim", name: "d \(f(d)) yeah +\(f(a)) go on +\(f(g))", total: 10,
                                    me: [(4.0 + d, 9.0)], others: [(1.0, 4.0)] + at(y, reviewTokens["yeah"]!) + [(y + 0.30 + g, 7.5)]))
                }
            }
        }
        return out
    }

    /// Sets on which the built-in value may add no cut-in to 01809d9's.
    static var zeroBar: [(String, [Case])] {
        [("backchannel", backchannels), ("yield", yields), ("short overlap", shortOverlaps), ("chain", chains),
         ("ack then reclaim", ackReclaims), ("click", clickTrains), ("trailing stop", trailingStops)]
    }

    static var allCases: [Case] {
        liveTakes + unplacedTake + backchannels + yields + shortOverlaps + reclaims + chains + breathy + reclaimGrid
            + clickTrains + trailingStops + ackReclaims
    }

    /// Cases that cut in (not trailing) here and not at 01809d9.
    static func added(_ cases: [Case], config: ListenMoreConfig) -> [String] {
        cases.filter { c in
            !run(c, config: config).cutIns.isEmpty && !(OverlapGapGolden.base[c.key] ?? "").contains("C@")
        }.map(\.name)
    }

    func config(gapMs: Double? = nil) throws -> ListenMoreConfig {
        try ListenMoreConfig.load(overrides: gapMs.map { ["local": ["cut_in_onset_gap_ms": $0]] } ?? [:])
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

    func testCaseSetSizes() {
        XCTAssertEqual([Self.backchannels.count, Self.yields.count, Self.shortOverlaps.count, Self.chains.count,
                        Self.ackReclaims.count, Self.clickTrains.count, Self.trailingStops.count, Self.breathy.count,
                        Self.reclaimGrid.count, Self.reclaims.count], [76, 66, 12, 70, 18, 9, 6, 90, 168, 20])
        XCTAssertEqual(Set(Self.allCases.map(\.key)).count, Self.allCases.count, "case keys are unique")
        XCTAssertEqual(OverlapGapGolden.base.count, Self.allCases.count, "the golden has every case")
    }

    /// At 0 ms the rule is 01809d9's: every case, cut-ins and trailing candidates, frame for frame.
    func testZeroReproduces01809d9OnEveryCase() throws {
        let c = try config(gapMs: 0)
        let differ = Self.allCases.compactMap { k -> String? in
            let got = Self.run(k, config: c).signature
            return got == OverlapGapGolden.base[k.key] ? nil : "\(k.key): \(got) vs \(OverlapGapGolden.base[k.key] ?? "missing")"
        }
        XCTAssertEqual(differ, [])
    }

    func testBuiltInValueAddsNoCutInOnTheQuietSets() throws {
        let c = try config()
        for (name, cases) in Self.zeroBar {
            XCTAssertEqual(Self.added(cases, config: c), [], name)
        }
    }

    /// 22:45 judge-on interruption: Them were talking at each of You's onsets and breathed after them, so
    /// the onset tolerance doesn't apply and the take still misses wherever its gaps fell. A known limit.
    func testBreathsAfterTheOnsetStillMissThe2245Take() throws {
        let c = try config()
        for take in Self.unplacedTake {
            XCTAssertFalse(Self.onTime(Self.run(take, config: c), take.window!), take.name)
        }
    }

    /// Them's "uh-huh" and a joined pair of them (0.10-0.14 s between the words, 0.90-0.94 s in all).
    static let uhHuh: Spans = [(0, 0.14), (0.22, 0.40)]
    static func joinedPair(at t: Double, gap: Double) -> Spans { at(t, uhHuh) + at(t + 0.40 + gap, uhHuh) }

    /// A joined backchannel pair is the one shape the onset tolerance turns into a cut-in with nothing
    /// else behind it, so it is pinned as a known limit. Them finish at 4.0 s; You start `d` later and
    /// talk 5 s (well past the backchannel length); Them's pair starts `p` after You's onset, inside the
    /// onset pause. At 01809d9 the pause before the pair is past 0.16 s and drops the cut-in; at 300 ms
    /// the pair rides through it (it builds the 0.6 s opening overlap on its own) and You's cut-in fires
    /// at 1.2 s from the onset. The same You over unbroken Them speech through the end of the pair cuts
    /// in at 01809d9, at the same time: the tolerance makes the pause behave as if Them hadn't paused,
    /// and adds no cut-in that continuous speech wouldn't already have had.
    func testJoinedBackchannelPairInTheOnsetPauseIsAKnownLimit() throws {
        let off = try config(gapMs: 0), on = try config()
        func cuts(_ c: ListenMoreConfig, _ them: Spans, _ me: Spans) -> [LocalEvent] {
            Synthetic.runLocal(c, mic: Synthetic.track(10, me, f0: Self.meF0), call: Synthetic.track(10, them, f0: Self.othersF0))
                .filter { $0.kind == .interrupt }
        }
        for (d, p, g) in [(0.10, 0.12, 0.10), (0.10, 0.30, 0.14), (0.20, 0.24, 0.12), (0.28, 0.20, 0.10)] {
            let pair = Self.joinedPair(at: 4.0 + d + p, gap: g)
            let me: Spans = [(4.0 + d, 9.0)]
            let label = "d \(Self.f(d)) pair +\(Self.f(p)) gap \(Self.f(g))"
            XCTAssertEqual(cuts(off, [(1.0, 4.0)] + pair, me).count, 0, "\(label): no cut-in at 0")
            let cut = try XCTUnwrap(cuts(on, [(1.0, 4.0)] + pair, me).first, "\(label): cut-in at 300")
            XCTAssertEqual(cut.onset, 4.0 + d, accuracy: 0.03, label)
            XCTAssertEqual(cut.t, 4.0 + d + 1.2, accuracy: 0.03, label)
            let unbroken: Spans = [(1.0, pair.last!.1)]
            for c in [off, on] {
                let twin = try XCTUnwrap(cuts(c, unbroken, me).first, "\(label): unbroken Them speech cuts in at 01809d9 and at 300")
                XCTAssertEqual(twin.t, cut.t, accuracy: 0.03, label)
            }
        }
    }

    /// The pair as You's own utterance (0.90-0.94 s, under the 1.2 s backchannel length) cuts in nowhere:
    /// over unbroken Them speech, or starting in the pause their words leave, at 0 and at 300 ms.
    func testJoinedBackchannelPairFromYouNeverCutsIn() throws {
        for c in [try config(gapMs: 0), try config()] {
            for (start, gap) in [(4.1, 0.10), (4.2, 0.12), (4.28, 0.14)] {
                let me = Self.joinedPair(at: start, gap: gap)
                for them: Spans in [[(1.0, 9.0)], [(1.0, 4.0), (start + 0.12, 9.0)], [(1.0, 4.0), (start + 0.26, 9.0)]] {
                    let evs = Synthetic.runLocal(c, mic: Synthetic.track(10, me, f0: Self.meF0), call: Synthetic.track(10, them, f0: Self.othersF0))
                    XCTAssertEqual(evs.filter { $0.kind == .interrupt }.count, 0, "pair at \(start) gap \(gap), Them \(them)")
                }
            }
        }
    }

    /// 06:29 run (01809d9), judge on, interruption and no-key, from the shadow trace: You's own comma
    /// pauses (0.56 s and 0.52 s, past `cut_in_utterance_gap_ms`) end the cut-ins from 10.68 s and 11.96 s
    /// before the backchannel length; Them's 0.22 s quiet is beside the point. Their pause tolerance
    /// leaves the miss as it was: the third onset cuts in at 14.66 s, after the 11.28-13.88 s window.
    func testYouSideCommaPausesAreNotTheirPauses() throws {
        let take = Case(group: "live", name: "06:29 judge-on interruption y3", total: 16,
                        me: [(10.68, 11.40), (11.96, 12.94), (13.46, 15.0)],
                        others: [(6.0, 9.98), (10.40, 12.94), (13.16, 14.18)], window: 11.28...13.88)
        for c in [try config(), try config(gapMs: 0)] {
            let cut = try XCTUnwrap(Self.run(take, config: c).cutIns.first)
            XCTAssertEqual(cut.onset, 13.46, accuracy: 0.03)
            XCTAssertEqual(cut.t, 14.66, accuracy: 0.03)
        }
    }

    func testGoldenSignatures() throws {
        guard let path = ProcessInfo.processInfo.environment["LM_OVERLAP_GAP_GOLDEN_OUT"] else {
            throw XCTSkip("set LM_OVERLAP_GAP_GOLDEN_OUT to write every case's signature")
        }
        let c = try config()
        let lines = Self.allCases.map { "        \"\($0.key)\": \"\(Self.run($0, config: c).signature)\"," }
        try lines.joined(separator: "\n").write(toFile: path, atomically: true, encoding: .utf8)
    }

    /// The curve: per value, the flagged live misses that cut in on time, cut-ins added to 01809d9's on
    /// each quiet set, and the reported sets (breathy cut-ins caught, the reclaim grid, the reclaims).
    func testSweep() throws {
        guard ProcessInfo.processInfo.environment["LM_OVERLAP_GAP_SWEEP"] == "1" else {
            throw XCTSkip("set LM_OVERLAP_GAP_SWEEP=1 to print the sweep")
        }
        let values = ProcessInfo.processInfo.environment["LM_OVERLAP_GAP_SWEEP_MS"].map { $0.split(separator: ",").compactMap { Double($0) } }
            ?? [0, 160, 200, 220, 240, 260, 280, 300, 320, 340, 360, 400, 500, 600]
        let flagged = Self.liveTakes.filter { $0.name.hasSuffix("(missed)") }
        let baseCount = { (cases: [Case]) in cases.filter { (OverlapGapGolden.base[$0.key] ?? "").contains("C@") }.count }
        var lines = ["| cut_in_onset_gap_ms | flagged misses on time | " + Self.zeroBar.map { "added: \($0.0) (n=\($0.1.count))" }.joined(separator: " | ")
                     + " | breathy cut-ins (base \(baseCount(Self.breathy))/90) | reclaim grid (base \(baseCount(Self.reclaimGrid))/168) | reclaims (base \(baseCount(Self.reclaims))/20) |",
                     "|" + String(repeating: "---|", count: 5 + Self.zeroBar.count)]
        var detail: [String] = []
        for ms in values {
            let c = try config(gapMs: ms)
            let onTime = flagged.filter { Self.onTime(Self.run($0, config: c), $0.window!) }.count
            let added = Self.zeroBar.map { ($0.0, Self.added($0.1, config: c)) }
            let fired = { (cases: [Case]) in cases.filter { !Self.run($0, config: c).cutIns.isEmpty }.count }
            lines.append("| \(Int(ms)) | \(onTime)/\(flagged.count) | " + added.map { "\($0.1.count)" }.joined(separator: " | ")
                         + " | \(fired(Self.breathy)) | \(fired(Self.reclaimGrid)) | \(fired(Self.reclaims)) |")
            detail.append("\(Int(ms)) ms added: \(added.filter { !$0.1.isEmpty })")
        }
        let text = (lines + [""] + detail).joined(separator: "\n")
        print(text)
        if let path = ProcessInfo.processInfo.environment["LM_OVERLAP_GAP_SWEEP_OUT"] {
            try text.write(toFile: path, atomically: true, encoding: .utf8)
        }
    }
}
