import XCTest
import ListenMoreCore
@testable import ListenMoreHarness

/// Fixes from the third live run (e2e6b84 on the box).
final class LiveRun3Tests: XCTestCase {
    let config = try! ListenMoreConfig.builtIn()

    /// pause: the paused y2 cut-in would fire past the cooldown of the pre-Pause interrupt even at the
    /// late end of that cue's live window, for TTS from the synthetic 2.6 words/s up to a fast 3.4.
    func testPausedCutInIsPastAPrePauseCueCooldown() throws {
        let s = Scenarios.pause
        for wordsPerS in [2.6, 3.0, 3.4] {
            let shapes = Dictionary(uniqueKeysWithValues: s.lines.map { line -> (String, ClipShape) in
                let voiced = line.seconds ?? Double(line.words.count) / wordsPerS
                return (line.id, ClipShape(lead: 0, voiced: voiced, total: voiced))
            })
            let t = try Timeline.realize(s, shapes: shapes)
            let pre = try XCTUnwrap(CueOracle.expected(t, config: config, facts: .init(keyless: false, gptStopT: nil, mode: .live)).cues.first)
            let y2 = try XCTUnwrap(t.line("y2"))
            let y2Fire = y2.start + config.local.cutInBackchannelMaxMs / 1000
            XCTAssertTrue(t.windows(.pause, .resume, end: t.duration).contains { $0.contains(y2Fire) }, "y2 cuts in while paused")
            XCTAssertGreaterThanOrEqual(y2Fire - pre.window.upperBound, config.cues.cooldownS, "at \(wordsPerS) words/s")
        }
    }

    /// The judge-off mute-unmute take around its false interrupt: Them quiet 28.56-29.16 s at a comma,
    /// You's first words back with comma pauses. The diagnostics list both sides' pauses, so a live run
    /// shows what ended the first words back's exemption.
    func testCutInDiagnosticsListBothSidesPauses() {
        func voiced(_ t: Double, _ spans: [(Double, Double)]) -> Bool { spans.contains { t > $0.0 + 1e-9 && t <= $0.1 + 1e-9 } }
        let them: [(Double, Double)] = [(25.98, 28.56), (29.16, 31.9)]
        let you: [(Double, Double)] = [(28.28, 28.80), (29.12, 29.94), (30.38, 32.5)]
        var trace = ShadowTrace()
        for k in 1...1700 {
            let t = Double(k) * config.frameS
            trace.frames.append(.init(t: t, meRaw: voiced(t, you), meActive: false, othersRaw: voiced(t, them), othersActive: false))
        }
        let span = 27.0...33.0
        let themQuiet = trace.quietStretches(in: span, \.othersRaw, frameS: config.frameS)
        XCTAssertEqual(themQuiet.count, 1)
        XCTAssertEqual(themQuiet.first?.from ?? 0, 28.56, accuracy: 1e-9)
        XCTAssertEqual(themQuiet.first?.to ?? 0, 29.16, accuracy: 1e-9)
        XCTAssertEqual(trace.quietStretches(in: span, \.meRaw, frameS: config.frameS).count, 2, "You's comma pauses (0.32 and 0.44 s)")
        let text = trace.explainCutIn(around: 30.0...31.6, config: config)
        XCTAssertTrue(text.contains("Them quiet 28.56-29.16 (0.60 s)"), text)
        XCTAssertTrue(text.contains("You quiet 28.80-29.12 (0.32 s), 29.94-30.38 (0.44 s)"), text)
        let back = trace.explainFirstWordsBack(unmute: 27.98, config: config)
        XCTAssertTrue(back.hasPrefix("first words back after Unmute at 27.98 s, 28.28-32.00 s:"), back)
        XCTAssertTrue(back.contains("You's longest pause 0.44 s (29.94-30.38) (ends the exemption over 0.50 s)"), back)
        XCTAssertTrue(back.contains("Them's longest pause 0.60 s (28.56-29.16) (a new utterance from 1.00 s)"), back)
    }
}
