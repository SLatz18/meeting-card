import XCTest
@testable import ListenMoreCore

/// The approved glow: ~3 s full cycle (rise, hold, fade), peak 0.35-0.5, plays once.
let designGlowProfile = GlowProfile(
    width: 32, peakOpacity: 0.45, cornerRadius: 16,
    stops: [.init(0, 1), .init(0.15, 0.78), .init(0.35, 0.42), .init(0.6, 0.16), .init(0.82, 0.05), .init(1, 0)],
    motion: .init(rise: 0.32, hold: 0.8, fade: 1.88, appearFactor: 0, easeRise: true, easeFade: true),
    reduceMotion: .init(rise: 0, hold: 0, fade: 2.0, appearFactor: 0.7, easeRise: false, easeFade: false))

final class GlowProfileTests: XCTestCase {
    let p = designGlowProfile

    func testCycleIsAboutThreeSeconds() {
        XCTAssertEqual(p.motion.total, 3.0, accuracy: 1e-9)
        XCTAssertEqual(p.opacity(at: 0, reduce: false), 0)
        XCTAssertEqual(p.opacity(at: 0.32, reduce: false), 0.45, accuracy: 1e-9)
        XCTAssertEqual(p.opacity(at: 1.0, reduce: false), 0.45, accuracy: 1e-9, "holding")
        XCTAssertLessThan(p.opacity(at: 2.0, reduce: false), 0.45)
        XCTAssertEqual(p.opacity(at: 3.0, reduce: false), 0)
        XCTAssertEqual(p.opacity(at: 10, reduce: false), 0, "plays once, never repeats")
    }

    func testRiseEasesInAndFadeEasesOut() {
        XCTAssertLessThan(p.opacity(at: 0.16, reduce: false), 0.45 / 2, "ease-in is slow at first")
        let mid = 0.32 + 0.8 + 0.94
        XCTAssertLessThan(p.opacity(at: mid, reduce: false), 0.45 / 2, "ease-out drops early")
    }

    func testReduceMotionAppearsAtSeventyPercentAndFadesLinearly() {
        XCTAssertEqual(p.motion(reduce: true).total, 2.0, accuracy: 1e-9)
        XCTAssertEqual(p.opacity(at: 0, reduce: true), 0.45 * 0.7, accuracy: 1e-9)
        XCTAssertEqual(p.opacity(at: 1.0, reduce: true), 0.45 * 0.7 / 2, accuracy: 1e-9)
        XCTAssertEqual(p.opacity(at: 2.0, reduce: true), 0)
    }

    func testStopsFallOffFromTheEdge() {
        XCTAssertEqual(p.factor(at: 0), 1)
        XCTAssertEqual(p.factor(at: 0.15), 0.78, accuracy: 1e-9)
        XCTAssertEqual(p.factor(at: 0.25), 0.6, accuracy: 1e-9)
        XCTAssertEqual(p.factor(at: 1), 0)
        XCTAssertEqual(p.factor(at: 2), 0)
        var last = 2.0
        for i in 0...32 {
            let f = p.factor(at: Double(i) / 32)
            XCTAssertLessThanOrEqual(f, last)
            last = f
        }
    }
}
