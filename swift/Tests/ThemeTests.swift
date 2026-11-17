import XCTest
@testable import MeetingCardCore

/// The shared theme keeps the cards' original values, and the coach's glow and chip draw from it.
final class ThemeTests: XCTestCase {
    func testThemeKeepsCardValues() {
        XCTAssertEqual(Theme.Metrics.cardRadius, 20)
        XCTAssertEqual(Theme.Metrics.cardWidth, 400)
        XCTAssertEqual(Theme.Metrics.cardHeight, 126)
        XCTAssertEqual(Theme.Metrics.borderWidth, 1.3)
        XCTAssertEqual(Theme.Metrics.buttonRadius, 9)
        XCTAssertEqual(Theme.Metrics.buttonHeight, 33)
        XCTAssertEqual(Theme.Fonts.title, Theme.FontSpec(17, .semibold))
        XCTAssertEqual(Theme.Fonts.body, Theme.FontSpec(13.5))
        XCTAssertEqual(Theme.Fonts.caption, Theme.FontSpec(12.5))
        XCTAssertEqual(Theme.Fonts.button, Theme.FontSpec(14, .medium))
        XCTAssertEqual(Theme.palette(dark: true).cardFill, CardPalette.for(dark: true).cardFill)
    }

    func testGlowCycleIsThreeSecondsAndCalm() {
        XCTAssertEqual(Theme.Glow.cycle, 3.0, accuracy: 1e-9, "rise + hold + fade")
        XCTAssertEqual(Theme.Glow.rise, 0.32)
        XCTAssertEqual(Theme.Glow.hold, 0.8)
        XCTAssertEqual(Theme.Glow.fade, 1.88)
        XCTAssertEqual(Theme.Glow.peakOpacity, 0.45)
        XCTAssertGreaterThanOrEqual(Theme.Glow.peakOpacity, 0.35)
        XCTAssertLessThanOrEqual(Theme.Glow.peakOpacity, 0.5)
        XCTAssertEqual(Theme.Glow.width, 32)
        XCTAssertEqual(Theme.Glow.stops.first?.factor, 1)
        XCTAssertEqual(Theme.Glow.stops.last?.factor, 0)
    }

    /// Derived colors land near the design tokens (approximations, not hard-coded truths).
    func testRoseAndAmberAreMutedAndNearTheDesign() {
        func near(_ c: RGBA, _ hex: UInt32, _ tol: Double = 0.07) {
            let t = RGBA(hex: hex)
            XCTAssertEqual(c.r, t.r, accuracy: tol); XCTAssertEqual(c.g, t.g, accuracy: tol); XCTAssertEqual(c.b, t.b, accuracy: tol)
        }
        near(Theme.Glow.rose(dark: false), 0xA65B57)
        near(Theme.Glow.rose(dark: true), 0xC47A76)
        near(Theme.Glow.amber(dark: false), 0xB4843A)
        near(Theme.Glow.amber(dark: true), 0xD4A45A)
        for dark in [false, true] {
            let rose = Theme.Glow.rose(dark: dark), amber = Theme.Glow.amber(dark: dark)
            XCTAssertGreaterThan(rose.r, rose.g + 0.2, "reads as rose")
            XCTAssertGreaterThan(amber.r, amber.b + 0.3, "reads as amber")
            XCTAssertGreaterThan(amber.g, rose.g, "distinct hues")
            let sys = Theme.Glow.systemRed(dark: dark)
            XCTAssertLessThan(rose.r - rose.b, sys.r - sys.b, "less saturated than system red")
        }
    }

    func testChipIsRightAnchoredTenPointsLeftOfJoin() {
        let joinX = Theme.Metrics.cardWidth - Theme.Metrics.trailingInset - Theme.Metrics.joinWidthMeet
        let l = Theme.Coach.layout(labelWidth: 60, live: true, joinX: joinX)
        XCTAssertTrue(l.showsLabel)
        XCTAssertEqual(l.x + l.width, joinX - 10, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(l.x, Theme.Metrics.leadingInset + Theme.Metrics.ignoreWidth + Theme.Metrics.controlGap)
        XCTAssertGreaterThanOrEqual(l.width, 108)
        XCTAssertLessThanOrEqual(l.width, 156)
    }

    func testChipDropsLabelNextToTheWideJoinAndNeverOverlapsIgnore() {
        let m = Theme.Metrics.self
        let minX = m.leadingInset + m.ignoreWidth + m.controlGap
        for jw in [m.joinWidth, m.joinWidthMeet, m.joinWidthCalendar] {
            let l = Theme.Coach.layout(labelWidth: 64, live: true, joinX: m.cardWidth - m.trailingInset - jw)
            XCTAssertGreaterThanOrEqual(l.x, minX, "join \(jw)")
        }
        XCTAssertFalse(Theme.Coach.layout(labelWidth: 64, live: true, joinX: m.cardWidth - m.trailingInset - m.joinWidthCalendar).showsLabel)
        let noJoin = Theme.Coach.layout(labelWidth: 64, live: false, joinX: nil)
        XCTAssertEqual(noJoin.x + noJoin.width, m.cardWidth - m.trailingInset - 10, accuracy: 1e-9)
    }

    func testChipFillsAndDot() {
        XCTAssertEqual(Theme.Coach.fill(dark: false, paused: false), CardPalette.for(dark: false).ignoreFill(.normal))
        XCTAssertLessThan(Theme.Coach.fill(dark: false, paused: true).a, Theme.Coach.fill(dark: false, paused: false).a)
        XCTAssertEqual(Theme.Coach.dot(dark: true), CardPalette.for(dark: true).nextUp)
        XCTAssertEqual(Theme.Coach.symbol, "ear.badge.waveform")
    }

    /// The App draws the card from Theme, not from literals (so the coach can't drift from it).
    func testCardPanelReadsTheTheme() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("App/CardPanel.swift"), encoding: .utf8)
        for literal in [".systemFont(ofSize: 17", ".systemFont(ofSize: 13.5", ".systemFont(ofSize: 14", "cornerRadius = 9",
                        "width: 67, height: 33"] {
            XCTAssertFalse(src.contains(literal), literal)
        }
        XCTAssertTrue(src.contains("Theme.Fonts.title"))
        XCTAssertTrue(src.contains("Theme.Metrics.buttonRadius"))
    }
}
