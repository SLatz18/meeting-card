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

    /// The fixed collapse rule: full only with >= 8 pt to Ignore and to the primary button, else
    /// icon-only (glyph, 4 pt gap, 25 pt Pause), which always fits; the primary button is untouched.
    func testChipCollapseRule() {
        let m = Theme.Metrics.self, c = Theme.Coach.self
        let ignoreRight = m.leadingInset + m.ignoreWidth
        XCTAssertEqual(c.iconOnlyWidth, 8 + 20 + 4 + 25 + 4, accuracy: 1e-9)
        XCTAssertEqual(c.pauseButtonSize, 25)
        XCTAssertEqual(c.glyphGap, 4)
        let joins: [Double?] = [m.joinWidth, m.joinWidthMeet, m.joinWidthCalendar, nil]
        for jw in joins {
            let joinX = jw.map { m.cardWidth - m.trailingInset - $0 }
            let primaryLeft = joinX ?? (m.cardWidth - m.trailingInset)
            for label in stride(from: 0.0, through: 220, by: 2) {
                let l = c.layout(labelWidth: label, joinX: joinX)
                let gapIgnore = l.x - ignoreRight, gapPrimary = primaryLeft - (l.x + l.width)
                XCTAssertGreaterThanOrEqual(gapIgnore, 8 - 1e-9, "join \(String(describing: jw)) label \(label)")
                XCTAssertEqual(gapPrimary, 8, accuracy: 1e-9)
                let fullFits = primaryLeft - 8 - c.fullWidth(labelWidth: label) >= ignoreRight + 8
                XCTAssertEqual(l.showsLabel, fullFits, "join \(String(describing: jw)) label \(label)")
                XCTAssertEqual(l.width, fullFits ? c.fullWidth(labelWidth: label) : c.iconOnlyWidth, accuracy: 1e-9)
            }
        }
        let calendarX = m.cardWidth - m.trailingInset - m.joinWidthCalendar
        XCTAssertTrue(c.layout(labelWidth: 60, joinX: calendarX).showsLabel, "Listening fits beside Open in Calendar")
        XCTAssertFalse(c.layout(labelWidth: 120, joinX: calendarX).showsLabel)
    }

    /// Settings stays card-width and inside the visible frame: taller groups scroll.
    func testSettingsWindowStaysInsideTheVisibleFrame() {
        let st = Theme.Settings.self
        XCTAssertEqual(st.contentHeight(fitting: 600, visibleHeight: 875, chrome: 28).height, 600)
        XCTAssertFalse(st.contentHeight(fitting: 600, visibleHeight: 875, chrome: 28).scrolls)
        let tall = st.contentHeight(fitting: 1200, visibleHeight: 875, chrome: 28)
        XCTAssertEqual(tall.height, 847)
        XCTAssertTrue(tall.scrolls)
        let visible = (x: 0.0, y: 25.0, w: 1440.0, h: 875.0)
        let o = st.clamp(origin: (500, -40), size: (440, 875), visible: visible)
        XCTAssertEqual(o.x, 500); XCTAssertEqual(o.y, 25, "pulled up off the Dock")
        let top = st.clamp(origin: (1200, 600), size: (440, 400), visible: visible)
        XCTAssertEqual(top.x, 1000); XCTAssertEqual(top.y, 500, "pulled in from the right and the top")
        XCTAssertEqual(st.groupRadius, 20)
        XCTAssertEqual(st.groupWidth, Theme.Metrics.cardWidth)
    }

    /// Onboarding: "Meet Call Coach", and the primary button is the card's button.
    func testOnboardingUsesTheCardButtonAndTitleCase() throws {
        let st = Theme.Settings.self
        XCTAssertEqual(st.buttonHeight, 33)
        XCTAssertEqual(st.buttonRadius, 9)
        XCTAssertEqual(st.buttonFont, Theme.FontSpec(13.5, .medium))
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App")
        let copy = try String(contentsOf: app.appendingPathComponent("CoachCopy.swift"), encoding: .utf8)
        XCTAssertTrue(copy.contains("\"Meet Call Coach\""))
        // Approved copy: the toggle help and onboarding screen 1 describe the card nudge, not the glow.
        XCTAssertTrue(copy.contains("static let toggleHelp = \"A small card turns red when you interrupt or talk over someone, and amber when you miss a question. Only you see it. Off by default.\""))
        XCTAssertTrue(copy.contains("body: \"A quiet nudge on your calls. A small card shows a short tip. It turns red if you interrupt or talk over someone, and amber if you miss a question. Only you see it.\""))
        XCTAssertFalse(copy.contains("screen-edge glow") || copy.contains("edge of your screen glows"))
        XCTAssertFalse(copy.contains("\"Meet Call coach\""))
        let window = try String(contentsOf: app.appendingPathComponent("CoachSettingsWindow.swift"), encoding: .utf8)
        XCTAssertTrue(window.contains("let primary = Self.cardButton(s.primary"))
        XCTAssertTrue(window.contains("b.role = .ignore"))
    }

    /// Onboarding is the card itself: a borderless, clear, shadowless window with no plate (no
    /// window inset around the group), and the snapshot draws no backing for a clear window.
    func testOnboardingWindowHasNoBackingPlate() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App")
        let window = try String(contentsOf: app.appendingPathComponent("CoachSettingsWindow.swift"), encoding: .utf8)
        for needle in ["CardWindow(contentRect: rect, styleMask: [.borderless]", "w.isOpaque = false", "w.backgroundColor = .clear",
                       "w.hasShadow = CardStyle.Material.shadow", "let inset = showingOnboarding ? 0 :",
                       "showingOnboarding ? Theme.Settings.groupWidth : Theme.Settings.width",
                       "override var canBecomeKey: Bool { true }", "override func cancelOperation"] {
            XCTAssertTrue(window.contains(needle), needle)
        }
        let snapshots = try String(contentsOf: app.appendingPathComponent("UISnapshots.swift"), encoding: .utf8)
        XCTAssertTrue(snapshots.contains("if window.isOpaque {"))
        XCTAssertFalse(CardStyle.Material.shadow)
    }

    /// Every coach surface value is a CardStyle token or derived from one.
    func testCoachSurfacesDeriveFromCardStyle() {
        let c = Theme.Coach.self
        XCTAssertEqual(c.height, CardStyle.Size.control)
        XCTAssertEqual(c.radius, CardStyle.Radius.control)
        XCTAssertEqual(c.labelFont, CardStyle.Typography.button)
        XCTAssertEqual(c.glyphSize, CardStyle.Size.icon)
        XCTAssertEqual(c.clearance, CardStyle.Spacing.control)
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

    /// "Use Zoom/Meet controls" and the Muted state are Settings and chip tokens, so CardStyle's.
    func testCallControlsDeriveFromCardStyle() {
        let cc = Theme.CallControls.self
        XCTAssertEqual(cc.rowFont, CardStyle.Typography.button)
        XCTAssertEqual(cc.helperFont, CardStyle.Typography.caption)
        XCTAssertEqual(cc.explainerFont, CardStyle.Typography.caption)
        XCTAssertEqual(cc.helperText, .secondary)
        XCTAssertEqual(cc.explainerText, .secondary, "informational, not critical")
        XCTAssertEqual(cc.mutedText, Theme.Coach.heldText, "Muted reads like Paused")
        XCTAssertEqual(Theme.Coach.heldText, .secondary)
        XCTAssertEqual(Theme.Coach.text, .primary)
        XCTAssertEqual(cc.mutedSymbol, Theme.Coach.symbol)
    }

    /// The coach UI files carry no literal sizes, radii or colors of their own, and the Zoom/Meet
    /// controls UI reads its tokens (not inline text roles).
    func testCallControlsUIReadsItsTokens() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App")
        let settings = try String(contentsOf: app.appendingPathComponent("CoachSettingsWindow.swift"), encoding: .utf8)
        for line in settings.components(separatedBy: "\n") where line.contains("callControls") && line.contains("Self.text(") {
            XCTAssertTrue(line.contains("Theme.CallControls."), line)
        }
        XCTAssertTrue(settings.contains("color(Theme.CallControls.explainerText)"))
        XCTAssertTrue(settings.contains("color: Self.color(Theme.CallControls.helperText)"))
        let chip = try String(contentsOf: app.appendingPathComponent("CoachChip.swift"), encoding: .utf8)
        XCTAssertTrue(chip.contains("Theme.text(paused ? c.heldText : c.text, style)"))
        XCTAssertTrue(chip.contains("let paused = chip.held"), "Muted is drawn like Paused")
        let controller = try String(contentsOf: app.appendingPathComponent("CoachController.swift"), encoding: .utf8)
        XCTAssertTrue(controller.contains("note(CoachCopy.coachMuted, Theme.CallControls.mutedSymbol)"))
    }

    /// The caption strip reads as a sibling of the card: same surface, radius, width, insets and type
    /// scale; the saving indicator is the card's secondary control shape; the notice is card-shaped.
    func testCaptionsAndNoticeDeriveFromCardStyle() {
        let c = Theme.Captions.self
        XCTAssertEqual(c.width, Theme.Metrics.cardWidth)
        XCTAssertEqual(c.radius, Theme.Metrics.cardRadius)
        XCTAssertEqual(c.padding.h, Theme.Metrics.leadingInset)
        XCTAssertEqual(c.padding.v, Theme.Metrics.buttonBottom)
        XCTAssertEqual(c.textFont, Theme.Fonts.body)
        XCTAssertEqual(c.speakerFont, Theme.Fonts.button)
        XCTAssertEqual(c.noteFont, Theme.Fonts.caption)
        XCTAssertEqual(c.margin, Theme.Metrics.cardMargin)
        XCTAssertEqual(c.indicatorHeight, Theme.Coach.height)
        XCTAssertEqual(c.indicatorRadius, Theme.Coach.radius)
        XCTAssertEqual(c.hairlineWidth, Theme.Metrics.buttonHairline)
        XCTAssertEqual(c.lineGap, CardStyle.Spacing.control / 2)
        XCTAssertEqual(c.trailingReserve, Theme.Metrics.cardWidth + Theme.Metrics.cardMargin)
        XCTAssertEqual(c.ownSpeaker, .accent)
        let n = Theme.Notice.self
        XCTAssertEqual(n.width, Theme.Metrics.cardWidth)
        XCTAssertEqual(n.titleFont, Theme.Fonts.title)
        XCTAssertEqual(n.bodyFont, Theme.Fonts.body)
        XCTAssertEqual(n.buttonFont, Theme.Fonts.button)
        XCTAssertEqual(n.buttonHeight, Theme.Metrics.buttonHeight)
        XCTAssertEqual(n.buttonRadius, Theme.Metrics.buttonRadius)
        for dark in [false, true] {
            let t = CardStyle.for(dark: dark)
            XCTAssertEqual(c.surface(style: t), Theme.palette(dark: dark).cardFill, "the card's own fill")
            XCTAssertEqual(c.hairline(style: t), t.hairline)
            XCTAssertEqual(c.dot(style: t), t.critical)
            XCTAssertEqual(n.surface(style: t), t.surface)
        }
    }

    /// The coach UI files carry no literal sizes, radii or colors of their own.
    func testCoachUIHasNoOneOffValues() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App")
        for file in ["CoachChip.swift", "CoachSettingsWindow.swift", "CoachController.swift", "CoachCardView.swift",
                     "CoachCardPanel.swift", "CoachCaptions.swift", "CoachTranscript.swift", "CoachNotice.swift"] {
            let src = try String(contentsOf: app.appendingPathComponent(file), encoding: .utf8)
            for bad in ["pointSize: 1", "pointSize: 2", "cornerRadius = 1", "spacing = 1", "spacing = 8", "constant: 1",
                        "srgbRed:", "white: 0.", ".systemRed", ".secondaryLabelColor", ".tertiaryLabelColor",
                        "quaternarySystemFill", "NSSize(width: 1"] {
                XCTAssertFalse(src.contains(bad), "\(file): \(bad)")
            }
        }
    }

    /// The coach card and pill take every size, radius, inset, alpha and duration from a token: no
    /// number in their code but 0, 1 and 2 (halves, and the backing-scale fallback), and no color.
    func testCoachCardHasNoLiteralValues() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App")
        let number = try NSRegularExpression(pattern: #"(?<![A-Za-z0-9_.])\d+(\.\d+)?(?![A-Za-z0-9_])"#)
        for file in ["CoachCardView.swift", "CoachCardPanel.swift", "CoachCaptions.swift"] {
            let src = try String(contentsOf: app.appendingPathComponent(file), encoding: .utf8)
            let code = src.components(separatedBy: "\n")
                .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
                .map { $0.replacingOccurrences(of: #""(?:[^"\\]|\\.)*""#, with: "\"\"", options: .regularExpression) }
                .joined(separator: "\n")
            for m in number.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                let n = (code as NSString).substring(with: m.range)
                XCTAssertTrue(["0", "1", "2"].contains(n), "\(file): literal \(n)")
            }
            for bad in ["NSColor(", "CGColor(", "srgbRed", "white:", ".systemOrange", ".systemRed", ".labelColor", "LabelColor",
                        "systemFont("] {
                XCTAssertFalse(code.contains(bad), "\(file): \(bad)")
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
