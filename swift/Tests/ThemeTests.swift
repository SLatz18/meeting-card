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

    /// CardStyle carries the card's tokens per appearance; Theme's card layout reads the same values.
    func testCardStyleIsTheCardsTokens() {
        for dark in [false, true] {
            let t = CardStyle.for(dark: dark), p = CardPalette.for(dark: dark)
            XCTAssertEqual(t.surface, p.cardFill)
            XCTAssertEqual(t.hairline, p.hairline)
            XCTAssertEqual(t.accent, p.nextUp)
            XCTAssertEqual(t.warning, p.flag)
            XCTAssertEqual(t.primaryText, p.joinText)
            for s in [ButtonState.normal, .hover, .pressed] {
                XCTAssertEqual(t.controlFill(s), p.ignoreFill(s))
                XCTAssertEqual(t.primaryFill(s), p.joinFillState(s))
            }
        }
        XCTAssertEqual(CardStyle.Radius.card, 20)
        XCTAssertEqual(CardStyle.Radius.control, 9)
        XCTAssertEqual(CardStyle.Radius.concentric(outer: 9, inset: 5.5), 3.5)
        XCTAssertEqual(CardStyle.Spacing.control, 8)
        XCTAssertEqual(CardStyle.Spacing.leading, 17)
        XCTAssertEqual(CardStyle.Stroke.hairline, 0.5)
        XCTAssertEqual(CardStyle.Stroke.border, 1.3)
        XCTAssertEqual(CardStyle.Size.control, 33)
        XCTAssertEqual(CardStyle.Size.icon, 20)
        XCTAssertTrue(CardStyle.Material.opaque)
        XCTAssertFalse(CardStyle.Material.shadow)
        XCTAssertEqual(Theme.Metrics.buttonRadius, CardStyle.Radius.control)
        XCTAssertEqual(Theme.Fonts.button, CardStyle.Typography.button)
    }

    func testGlowCycleIsThreeSecondsAndCalm() {
        XCTAssertEqual(Theme.Glow.cycle, 3.0, accuracy: 1e-9, "rise + hold + fade")
        XCTAssertEqual(Theme.Glow.rise, 0.32)
        XCTAssertEqual(Theme.Glow.hold, 0.8)
        XCTAssertEqual(Theme.Glow.fade, 1.88)
        XCTAssertEqual(Theme.Glow.peakOpacity, 0.45)
        XCTAssertGreaterThanOrEqual(Theme.Glow.peakOpacity, 0.35)
        XCTAssertLessThanOrEqual(Theme.Glow.peakOpacity, 0.5)
        XCTAssertEqual(Theme.Glow.width, CardStyle.Size.control)
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

    func testChipIsRightAnchoredOneControlGapLeftOfJoin() {
        let joinX = Theme.Metrics.cardWidth - Theme.Metrics.trailingInset - Theme.Metrics.joinWidthMeet
        let l = Theme.Coach.layout(labelWidth: 60, joinX: joinX)
        XCTAssertTrue(l.showsLabel)
        XCTAssertEqual(l.x + l.width, joinX - CardStyle.Spacing.control, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(l.x, Theme.Metrics.leadingInset + Theme.Metrics.ignoreWidth + Theme.Metrics.controlGap)
        XCTAssertEqual(l.width, 8 + 20 + 4 + 60 + 8 + 25 + 4, accuracy: 1e-9)
    }

    func testChipDropsLabelNextToTheWideJoinAndNeverOverlapsIgnore() {
        let m = Theme.Metrics.self
        let minX = m.leadingInset + m.ignoreWidth + m.controlGap
        for jw in [m.joinWidth, m.joinWidthMeet, m.joinWidthCalendar] {
            for label in [20.0, 64, 90] {
                let l = Theme.Coach.layout(labelWidth: label, joinX: m.cardWidth - m.trailingInset - jw)
                XCTAssertGreaterThanOrEqual(l.x, minX, "join \(jw) label \(label)")
            }
        }
        XCTAssertFalse(Theme.Coach.layout(labelWidth: 90, joinX: m.cardWidth - m.trailingInset - m.joinWidthCalendar).showsLabel)
        let noJoin = Theme.Coach.layout(labelWidth: 64, joinX: nil)
        XCTAssertEqual(noJoin.x + noJoin.width, m.cardWidth - m.trailingInset - CardStyle.Spacing.control, accuracy: 1e-9)
    }

    /// Every coach surface value is a CardStyle token or derived from one.
    func testCoachSurfacesDeriveFromCardStyle() {
        let c = Theme.Coach.self
        XCTAssertEqual(c.height, CardStyle.Size.control)
        XCTAssertEqual(c.radius, CardStyle.Radius.control)
        XCTAssertEqual(c.labelFont, CardStyle.Typography.button)
        XCTAssertEqual(c.glyphSize, CardStyle.Size.icon)
        XCTAssertEqual(c.joinGap, CardStyle.Spacing.control)
        XCTAssertEqual(c.paddingLeading, CardStyle.Spacing.control)
        XCTAssertEqual(c.glyphGap, CardStyle.Spacing.control / 2)
        XCTAssertEqual(c.pauseButtonSize + 2 * c.controlInset, c.height)
        XCTAssertEqual(c.pauseButtonRadius, c.radius - c.controlInset, "concentric")
        XCTAssertEqual(c.pauseGlyphSize, CardStyle.Typography.caption.size)
        XCTAssertEqual(c.menuSymbolSize, CardStyle.Typography.body.size)
        for dark in [false, true] {
            let t = CardStyle.for(dark: dark)
            XCTAssertEqual(c.fill(style: t), t.controlFill(.normal))
            XCTAssertEqual(c.pauseButtonFill(style: t), t.controlFill(.normal))
            XCTAssertEqual(c.live(style: t), t.accent)
            XCTAssertEqual(Theme.Settings.groupFill(style: t), t.surface)
            XCTAssertEqual(Theme.Glow.systemRed(dark: dark), t.critical)
        }
        XCTAssertEqual(Theme.Glow.cornerRadius, CardStyle.Radius.card)
        XCTAssertEqual(Theme.Glow.width, CardStyle.Size.control)
        let st = Theme.Settings.self
        XCTAssertEqual(st.groupWidth, Theme.Metrics.cardWidth)
        XCTAssertEqual(st.groupRadius, CardStyle.Radius.card)
        XCTAssertEqual(st.groupPadding.h, CardStyle.Spacing.leading)
        XCTAssertEqual(st.groupPadding.v, CardStyle.Spacing.controlBottom)
        XCTAssertEqual(st.inset, CardStyle.Spacing.stack)
        XCTAssertEqual(st.width, Theme.Metrics.cardWidth + 2 * CardStyle.Spacing.stack)
        XCTAssertEqual(st.headingFont, CardStyle.Typography.title)
        XCTAssertEqual(st.rowFont, CardStyle.Typography.button)
        XCTAssertEqual(st.itemFont, CardStyle.Typography.body)
        XCTAssertEqual(st.helperFont, CardStyle.Typography.caption)
    }

    /// The coach UI files carry no literal sizes, radii or colors of their own.
    func testCoachUIHasNoOneOffValues() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App")
        for file in ["CoachChip.swift", "CoachSettingsWindow.swift", "CoachController.swift"] {
            let src = try String(contentsOf: app.appendingPathComponent(file), encoding: .utf8)
            for bad in ["pointSize: 1", "pointSize: 2", "cornerRadius = 1", "spacing = 1", "spacing = 8", "constant: 1",
                        "srgbRed:", "white: 0.", ".systemRed", ".secondaryLabelColor", ".tertiaryLabelColor",
                        "quaternarySystemFill", "NSSize(width: 1"] {
                XCTAssertFalse(src.contains(bad), "\(file): \(bad)")
            }
        }
    }

    /// The App draws the card from Theme, not from literals (so the coach can't drift from it).
    func testCardPanelReadsTheTheme() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("App/CardPanel.swift"), encoding: .utf8)
        for literal in [".systemFont(ofSize: 17", ".systemFont(ofSize: 13.5", ".systemFont(ofSize: 14", "cornerRadius = 9",
                        "width: 67, height: 33"] {
            XCTAssertFalse(src.contains(literal), literal)
        }
        XCTAssertTrue(src.contains("CardStyle.Typography.title"))
        XCTAssertTrue(src.contains("CardStyle.Radius.control"))
        XCTAssertFalse(src.contains("Theme.Fonts."), "the card reads CardStyle directly")
        XCTAssertFalse(src.contains("cornerRadius: 20") || src.contains("CGFloat = 20") || src.contains("CGFloat = 1.3"))
    }
}
