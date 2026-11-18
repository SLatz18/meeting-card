import XCTest
import ListenMoreCore
@testable import ListenMoreHarness

/// Fixes from the third live run (e2e6b84 on the box).
final class LiveRun3Tests: XCTestCase {
    let config = try! ListenMoreConfig.builtIn()

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
    }
}
