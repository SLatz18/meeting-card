import Foundation

/// MeetingCard's design language, taken from the reminder card: typography, color roles, corner
/// radii, spacing, strokes, surface material and light/dark values. The card reads it and every
/// coach surface derives from it; a surface that needs a value not here derives it from these.
/// Values are the card's original literals (pixel-identical, checked by the CI snapshot job).
public struct CardStyle: Sendable {
    public let dark: Bool
    public let palette: CardPalette

    public static func `for`(dark: Bool) -> CardStyle { CardStyle(dark: dark, palette: .for(dark: dark)) }

    // MARK: color roles (per appearance)

    /// The card's opaque fill.
    public var surface: RGBA { palette.cardFill }
    /// Control outlines (the Ignore button's 0.5 pt edge).
    public var hairline: RGBA { palette.hairline }
    /// The Next up blue: live / informational.
    public var accent: RGBA { palette.nextUp }
    /// The flag amber: attention.
    public var warning: RGBA { palette.flag }
    /// AppKit system colors by meaning. The App draws the live semantic NSColor (it follows dark
    /// mode and Increase Contrast); `srgb` is its standard-contrast value on macOS 26, for math and tests.
    public enum SystemColor: Sendable { case red, orange }
    public static func srgb(_ c: SystemColor, dark: Bool) -> RGBA {
        switch c {
        case .red: dark ? RGBA(hex: 0xFF453A) : RGBA(hex: 0xFF3B30)
        case .orange: dark ? RGBA(hex: 0xFF9230) : RGBA(hex: 0xFF8D28)
        }
    }
    /// Alerts and errors: systemRed.
    public static let criticalColor = SystemColor.red
    /// Caution: systemOrange.
    public static let cautionColor = SystemColor.orange
    /// `labelColor` in sRGB on macOS 26 (85% black or white; opaque under Increase Contrast), for
    /// contrast math and tests. The App draws the live semantic color.
    public static func primaryTextSRGB(dark: Bool, increasedContrast: Bool = false) -> RGBA {
        let a = increasedContrast ? 1 : 0.85
        return dark ? .white(a) : .black(a)
    }
    public var critical: RGBA { CardStyle.srgb(CardStyle.criticalColor, dark: dark) }
    public var caution: RGBA { CardStyle.srgb(CardStyle.cautionColor, dark: dark) }
    /// Secondary control fill (Ignore) per state.
    public func controlFill(_ s: ButtonState) -> RGBA { palette.ignoreFill(s) }
    /// Primary control fill (Join) per state, and its text.
    public func primaryFill(_ s: ButtonState) -> RGBA { palette.joinFillState(s) }
    public var primaryText: RGBA { palette.joinText }

    /// Text colors. Primary, secondary and tertiary are AppKit semantic label colors (they follow
    /// the system, including Increase Contrast); the rest are the color roles above.
    public enum Text: Sendable { case primary, secondary, tertiary, accent, warning, critical }

    // MARK: scales (same in light and dark)

    /// System font, from the card's lines and buttons.
    public enum Typography {
        /// Card title line ("Standup in 2 min").
        public static let title = Theme.FontSpec(17, .semibold)
        /// Placeholder title font before the countdown is applied.
        public static let titlePlaceholder = Theme.FontSpec(17)
        /// "Ends 10:30 AM" and flags.
        public static let body = Theme.FontSpec(13.5)
        /// "Next up" line.
        public static let caption = Theme.FontSpec(12.5)
        /// Ignore / Join.
        public static let button = Theme.FontSpec(14, .medium)
    }

    /// Corner radii, always with continuous (squircle) corners.
    public enum Radius {
        public static let card = CardLayout.radius
        public static let control: Double = 9
        /// A shape inset `inset` inside one with radius `outer` keeps the corners concentric.
        public static func concentric(outer: Double, inset: Double) -> Double { max(0, outer - inset) }
    }

    public enum Spacing {
        /// Card to screen edge.
        public static let margin = CardLayout.margin
        /// Card to card in the stack.
        public static let stack = CardLayout.gap
        /// Left edge of the title line and the Ignore button.
        public static let leading: Double = 17
        /// Left edge of the Ends / Next up lines.
        public static let text: Double = 18
        /// Right edge of the Join button.
        public static let trailing: Double = 16
        /// Between controls in the button row.
        public static let control: Double = 8
        /// Button row to the card's bottom edge.
        public static let controlBottom: Double = 15
    }

    public enum Stroke {
        /// Control outline.
        public static let hairline: Double = 0.5
        /// Provider outline on the card edge.
        public static let border = CardBorder.width
    }

    public enum Size {
        /// Button height.
        public static let control: Double = 33
        /// Provider icon in the Join button.
        public static let icon: Double = 20
    }

    /// How surfaces are drawn: an opaque fill (no blur or vibrancy, so text contrast is fixed and
    /// measured), no window shadow, continuous corners, and no show/hide animation.
    public enum Material {
        public static let opaque = true
        public static let shadow = false
        public static let animates = false
    }

    /// Coach surface motion. Windows still appear and leave without AppKit's animation
    /// (`Material.animates`); these time the coach card's own morph, glide and pill changes.
    public enum Motion {
        /// The morph's keyframes, from its start: the card's content has faded by the second, the
        /// new surface is in and at its size by the third.
        public static let morphKeyframes: [TimeInterval] = [0, 0.120, 0.280]
        public static var morph: TimeInterval { morphKeyframes[morphKeyframes.count - 1] }
        /// Reduce Motion: no frame animation; the surface fades out and back in.
        public static let reduceMotionCrossfade: TimeInterval = 0.200
        /// Glide to the placement spot, and the pill widening for a nudge.
        public static let move: TimeInterval = 0.240
    }

    /// The call coach card, its pill, and their nudges.
    public enum Coach {
        /// How long a nudge tints the card or pill.
        public static let nudgeHold: TimeInterval = 4.5
        public static let pill = (width: 200.0, height: 45.0, radius: 15.0)
        /// Nudge tint: the rose or amber tone at this alpha over the card's surface.
        public static let nudgeTint = (light: 0.12, dark: 0.16)
        public static let nudgeTintIncreasedContrast = (light: 0.20, dark: 0.26)
        /// The tone's leading bar and outline: the card border's alpha, full under Increase Contrast.
        public static let nudgeEdgeAlpha = (light: CardBorder.alphaLight, dark: CardBorder.alphaDark)
        public static let nudgeEdgeAlphaIncreasedContrast = 1.0
        public static let nudgeBar: Double = 5
        public static let nudgeBorder = CardStyle.Stroke.border
        /// Nudge words on the tint keep at least this contrast.
        public static let nudgeMinContrast = 4.5
        /// The pill's drag handle.
        public static let grabber = (width: 28.0, height: 3.5)
        /// Room for the call app's own top bar (Zoom's floating meeting controls) above the card.
        /// UNVERIFIED: an estimate, to be measured on the Mac hand check (MAC_DEMO_CHECKS CC3).
        public static let callBarClearance: Double = 52
        /// Below the call bar.
        public static let topGap: Double = 12

        /// Menu bar height, or the notch's safe-area inset where that is taller.
        public static func screenMetric(safeAreaTop: Double, menuBarHeight: Double) -> Double {
            max(safeAreaTop, menuBarHeight)
        }

        /// Screen top edge to the card's top edge.
        public static func topOffset(screenMetric: Double) -> Double { screenMetric + callBarClearance + topGap }

        public static func nudgeTint(dark: Bool, increasedContrast: Bool) -> Double {
            let t = increasedContrast ? nudgeTintIncreasedContrast : nudgeTint
            return dark ? t.dark : t.light
        }

        public static func nudgeEdgeAlpha(dark: Bool, increasedContrast: Bool) -> Double {
            increasedContrast ? nudgeEdgeAlphaIncreasedContrast : dark ? nudgeEdgeAlpha.dark : nudgeEdgeAlpha.light
        }
    }
}

/// The one source of MeetingCard's look, shared by the reminder cards and the call coach so the
/// two can't drift. Design tokens are `CardStyle`; this adds card layout and the coach surfaces
/// derived from them.
public enum Theme {
    public static func palette(dark: Bool) -> CardPalette { CardPalette.for(dark: dark) }
    public static func style(dark: Bool) -> CardStyle { CardStyle.for(dark: dark) }

    /// System font specs (the App maps them to NSFont.systemFont).
    public struct FontSpec: Equatable, Sendable {
        public enum Weight: Sendable { case regular, medium, semibold }
        public let size: Double
        public let weight: Weight
        public init(_ size: Double, _ weight: Weight = .regular) { self.size = size; self.weight = weight }
    }

    public enum Fonts {
        public static let title = CardStyle.Typography.title
        public static let titlePlaceholder = CardStyle.Typography.titlePlaceholder
        public static let body = CardStyle.Typography.body
        public static let caption = CardStyle.Typography.caption
        public static let button = CardStyle.Typography.button
    }

    /// Card layout (positions specific to the reminder card), on the `CardStyle` scales.
    public enum Metrics {
        public static let cardWidth = CardLayout.W
        public static let cardHeight = CardLayout.H
        public static let cardRadius = CardStyle.Radius.card
        public static let cardMargin = CardStyle.Spacing.margin
        public static let stackGap = CardStyle.Spacing.stack
        public static let borderWidth = CardStyle.Stroke.border
        public static let buttonRadius = CardStyle.Radius.control
        public static let buttonHeight = CardStyle.Size.control
        public static let buttonBottom = CardStyle.Spacing.controlBottom
        public static let buttonHairline = CardStyle.Stroke.hairline
        public static let leadingInset = CardStyle.Spacing.leading
        public static let textInset = CardStyle.Spacing.text
        public static let trailingInset = CardStyle.Spacing.trailing
        public static let titleTop: Double = 40, titleHeight: Double = 24
        public static let bodyTop: Double = 67, bodyHeight: Double = 20
        public static let captionTop: Double = 90, captionHeight: Double = 18
        public static let ignoreWidth: Double = 67
        public static let joinWidth: Double = 114, joinWidthMeet: Double = 110, joinWidthCalendar: Double = 142
        public static let providerIconSize = CardStyle.Size.icon
        public static let controlGap = CardStyle.Spacing.control
    }

    /// Card show/hide motion: the cards appear and leave instantly (no AppKit window animation);
    /// coach surfaces do the same.
    public enum Motion {
        public static let windowAnimation = CardStyle.Material.animates
    }

    /// Screen-edge glow for coach cues: calm, peripheral, plays once. Rose and amber are the live
    /// semantic system colors of the card style's `critical` and `caution` roles (systemRed and
    /// systemOrange, so they follow dark mode and Increase Contrast), muted toward neutral gray;
    /// at standard contrast they land near the design tokens #A65B57/#C47A76 and #B4843A/#D4A45A.
    /// The corner radius is the card's, the band one control height wide.
    public enum Glow {
        public static let roseSource = CardStyle.criticalColor
        public static let amberSource = CardStyle.cautionColor

        /// NSColor.systemRed in sRGB (light / dark): the card style's `critical`.
        public static func systemRed(dark: Bool) -> RGBA { CardStyle.for(dark: dark).critical }

        /// Mix `c` toward a neutral gray: light appearance mutes harder and darker.
        public static func mute(_ c: RGBA, dark: Bool, amount: Double? = nil, gray: Double? = nil) -> RGBA {
            let gray = gray ?? (dark ? 0.6 : 0.5)
            let k = amount ?? (dark ? 0.55 : 0.65)
            return RGBA(c.r * (1 - k) + gray * k, c.g * (1 - k) + gray * k, c.b * (1 - k) + gray * k, 1)
        }

        /// Interrupt, talk-over, aggressive: `base` is the resolved systemRed.
        public static func rose(base: RGBA, dark: Bool) -> RGBA { mute(base, dark: dark) }

        /// Monologue, missed question, not listening, talk share: `base` is the resolved systemOrange.
        public static func amber(base: RGBA, dark: Bool) -> RGBA {
            mute(base, dark: dark, amount: 0.48, gray: dark ? 0.65 : 0.4)
        }

        /// Standard-contrast values.
        public static func rose(dark: Bool) -> RGBA { rose(base: CardStyle.srgb(roseSource, dark: dark), dark: dark) }
        public static func amber(dark: Bool) -> RGBA { amber(base: CardStyle.srgb(amberSource, dark: dark), dark: dark) }

        public static let width = CardStyle.Size.control
        public static let cornerRadius = CardStyle.Radius.card
        /// Glow behaviour (calibrated, not card tokens): peak opacity, falloff and timing.
        public static let peakOpacity: Double = 0.45
        /// Increase Contrast: a stronger peak, same timing.
        public static let increasedContrastPeakOpacity: Double = 0.60
        /// (fraction of width from the outer edge, opacity factor)
        public static let stops: [(at: Double, factor: Double)] = [
            (0, 1), (0.15, 0.78), (0.35, 0.42), (0.6, 0.16), (0.82, 0.05), (1, 0)]
        /// One cycle, ~3 s in total: rise (ease-in), hold, fade (ease-out). Never repeats.
        public static let rise: TimeInterval = 0.32
        public static let hold: TimeInterval = 0.8
        public static let fade: TimeInterval = 1.88
        public static var cycle: TimeInterval { rise + hold + fade }
        /// Reduce Motion: appear at 70% of peak, 2 s linear fade.
        public static let reduceMotionAppear: Double = 0.7
        public static let reduceMotionFade: TimeInterval = 2.0
    }

    /// The coach chip on the live card's button row, styled as the card's secondary control
    /// (Ignore): its height, radius, hairline, fill and button font. Its inner Pause/Resume control
    /// is inset by half a control gap with concentric corners.
    public enum Coach {
        public static let symbol = "ear.badge.waveform"
        public static let pauseSymbol = "pause.fill"
        public static let resumeSymbol = "play.fill"
        /// The coach's own Mute: the glyph on the chip, the card's status line and the menu.
        public static let micOffSymbol = "mic.slash"
        /// SF Symbols for the coach status menu, drawn at the body font size like a native menu.
        public static let menuSymbols = (start: resumeSymbol, stop: CoachCard.Symbols.stop,
                                         pause: pauseSymbol, resume: resumeSymbol,
                                         gptOffNoKey: "key", gptOffRejected: "exclamationmark.triangle",
                                         settings: "gearshape", feedback: "bubble.left",
                                         mute: micOffSymbol, unmute: "mic")
        public static let menuSymbolSize = CardStyle.Typography.body.size
        /// The status bar glyph, at the button font size and weight.
        public static let statusSymbolFont = CardStyle.Typography.button
        public static let glyphSize = CardStyle.Size.icon
        public static let glyphFont = CardStyle.Typography.button
        public static let height = CardStyle.Size.control
        public static let radius = CardStyle.Radius.control
        public static let labelFont = CardStyle.Typography.button
        public static let paddingLeading = CardStyle.Spacing.control
        public static let glyphGap = CardStyle.Spacing.control / 2
        public static let controlGap = CardStyle.Spacing.control
        /// The inner control's inset from the chip edge (also the trailing padding).
        public static let controlInset = CardStyle.Spacing.control / 2
        public static let paddingTrailing = controlInset
        public static let pauseButtonSize = height - 2 * controlInset
        public static let pauseButtonRadius = CardStyle.Radius.concentric(outer: radius, inset: controlInset)
        public static let pauseGlyphSize = CardStyle.Typography.caption.size
        /// Chip fill: the Ignore fill (paused reads from the secondary text and the Resume glyph).
        public static func fill(style: CardStyle) -> RGBA { style.controlFill(.normal) }
        /// The inner control: the Ignore fill again, layered on the chip.
        public static func pauseButtonFill(style: CardStyle) -> RGBA { style.controlFill(.normal) }
        /// Live tint = the card's accent (Next up blue).
        public static func live(style: CardStyle) -> RGBA { style.accent }
        /// Chip text and control tint: primary while on or listening, secondary while held (paused
        /// by the user, or muted in the call app).
        public static let text = CardStyle.Text.primary
        public static let heldText = CardStyle.Text.secondary

        /// Fixed collapse rule. The full chip (glyph, label, Pause) shows only if it keeps at least
        /// `clearance` to Ignore and to the primary button (Join / Open in Calendar); otherwise it is
        /// icon-only: glyph, `glyphGap`, Pause. The label then moves to the tooltip and the
        /// accessibility label. The primary button is never moved, narrowed or truncated.
        public static let clearance = CardStyle.Spacing.control

        public static func fullWidth(labelWidth: Double) -> Double {
            paddingLeading + glyphSize + glyphGap + labelWidth + controlGap + pauseButtonSize + paddingTrailing
        }

        public static var iconOnlyWidth: Double { paddingLeading + glyphSize + glyphGap + pauseButtonSize + paddingTrailing }

        /// Chip frame in card coordinates, right-anchored `clearance` left of the primary button
        /// at `joinX` (or of its slot if there is none).
        public static func layout(labelWidth: Double, joinX: Double?) -> (x: Double, width: Double, showsLabel: Bool) {
            let m = Metrics.self
            let right = (joinX ?? (m.cardWidth - m.trailingInset)) - clearance
            let minX = m.leadingInset + m.ignoreWidth + clearance
            let full = fullWidth(labelWidth: labelWidth)
            if right - full >= minX { return (right - full, full, true) }
            return (right - iconOnlyWidth, iconOnlyWidth, false)
        }
    }

    /// Settings window: a standard titled window (native controls and window background) whose
    /// groups are card-shaped: card width, card radius, card fill, and the card's text insets.
    public enum Settings {
        public static let groupWidth = CardLayout.W
        public static let groupRadius = CardStyle.Radius.card
        public static let groupPadding = (h: CardStyle.Spacing.leading, v: CardStyle.Spacing.controlBottom)
        public static let groupSpacing = CardStyle.Spacing.control
        /// Window edge to groups, and between groups: the card stack gap.
        public static let inset = CardStyle.Spacing.stack
        public static let width = groupWidth + 2 * inset
        public static let headingFont = CardStyle.Typography.title
        public static let rowFont = CardStyle.Typography.button
        public static let itemFont = CardStyle.Typography.body
        public static let helperFont = CardStyle.Typography.caption
        public static let glyphSize = CardStyle.Size.icon
        /// Onboarding's primary button: the card's button (control height and radius, Ignore fill
        /// and hairline) with a body-size label in the button weight, padded like the card's text.
        public static let buttonFont = Theme.FontSpec(CardStyle.Typography.body.size, CardStyle.Typography.button.weight)
        public static let buttonHeight = CardStyle.Size.control
        public static let buttonRadius = CardStyle.Radius.control
        public static let buttonPadding = CardStyle.Spacing.leading
        public static func groupFill(style: CardStyle) -> RGBA { style.surface }

        /// Content height for a window whose title bar etc. take `chrome`: the groups' fitting
        /// height, capped so the window stays inside the screen's visible frame (the groups scroll).
        public static func contentHeight(fitting: Double, visibleHeight: Double, chrome: Double) -> (height: Double, scrolls: Bool) {
            let cap = max(0, visibleHeight - chrome)
            return fitting > cap ? (cap, true) : (fitting, false)
        }

        /// Window origin moved the least to put `frame` inside `visible` (both bottom-left origin).
        public static func clamp(origin: (x: Double, y: Double), size: (w: Double, h: Double),
                                 visible: (x: Double, y: Double, w: Double, h: Double)) -> (x: Double, y: Double) {
            (min(max(origin.x, visible.x), visible.x + max(0, visible.w - size.w)),
             min(max(origin.y, visible.y), visible.y + max(0, visible.h - size.h)))
        }

        /// Helper lines under a row (the card's Next up line role).
        public static let helperText = CardStyle.Text.secondary
    }

    /// "Use Zoom/Meet controls": a card-shaped Settings group like the others (toggle row, help,
    /// permission explainer, Request access), and the Muted state of the chip and status menu.
    public enum CallControls {
        public static let rowFont = Settings.rowFont
        public static let helperFont = Settings.helperFont
        public static let helperText = Settings.helperText
        /// What is still missing (Accessibility, Automation, an unsupported Dia): informational, so the
        /// helper role, not `critical`.
        public static let explainerFont = Settings.helperFont
        public static let explainerText = Settings.helperText
        /// Muted reads like Paused: the held text role, the coach glyph on its status line.
        public static let mutedText = Coach.heldText
        public static let mutedSymbol = Coach.symbol
    }

    /// The call coach card the reminder card morphs into: card width, radius, fill and insets; a
    /// status row (the nudge band while a nudge holds) with Minimize, the captions area, and a
    /// button row with Stop Coach in the Ignore slot and Mute and Pause/Resume where Join sits.
    public enum CoachCard {
        public static let width = CardLayout.W
        public static let radius = CardStyle.Radius.card
        public static let leading = CardStyle.Spacing.leading
        public static let trailing = CardStyle.Spacing.trailing
        public static let vertical = CardStyle.Spacing.controlBottom
        public static let rowHeight = CardStyle.Size.control
        public static let rowGap = CardStyle.Spacing.control
        /// Three caption lines.
        public static let captionsHeight = 3 * Metrics.captionHeight
        public static var height: Double { 2 * vertical + 2 * rowHeight + 2 * rowGap + captionsHeight }

        /// The call-mode tip: its text wraps over up to this many lines, in the captions' font and role.
        public static let tipLines = 3
        public static let tipFont = captionsFont
        public static let tipTextColor = captionsText
        /// The borderless Dismiss under the tip text.
        public static let tipButtonFont = CardStyle.Typography.caption
        public static let tipButtonTextColor = CardStyle.Text.primary
        public static var tipTextHeight: Double { Double(tipLines) * Metrics.captionHeight }
        public static var tipButtonHeight: Double { Coach.pauseButtonSize }
        /// What the tip adds below the card's usual content: Dismiss on the card's bottom inset, a gap,
        /// then the text. (The usual bottom inset stays between the button row and the text.)
        public static var tipExtra: Double { vertical + tipButtonHeight + rowGap + tipTextHeight }
        /// The card's height, with the tip row when it shows.
        public static func cardHeight(callModeTip: Bool) -> Double { callModeTip ? height + tipExtra : height }

        public static let statusFont = CardStyle.Typography.body
        /// The status line reads like the chip: primary, held (paused or muted) secondary.
        public static let statusText = Coach.text
        public static let heldText = Coach.heldText
        public static let nudgeFont = Theme.FontSpec(CardStyle.Typography.body.size, .semibold)
        /// Nudge words on the tint (contrast checked against it).
        public static let nudgeText = CardStyle.Text.primary
        public static let captionsFont = CardStyle.Typography.caption
        public static let captionsText = CardStyle.Text.secondary
        public static let buttonFont = CardStyle.Typography.button
        public static let glyphSize = Coach.glyphSize
        public static let glyphGap = Coach.glyphGap
        /// Icon buttons (Mute, Pause/Resume, Minimize): one control height square, the control radius.
        public static let iconButton = CardStyle.Size.control
        public static let iconButtonRadius = CardStyle.Radius.control
        public static let iconGlyph = CardStyle.Typography.button
        /// Stop Coach: the Ignore button, as wide as its label plus the card's text inset each side.
        public static let textButtonPadding = CardStyle.Spacing.leading
        public static let bandRadius = CardStyle.Radius.control
        /// Status text and glyph inset inside the band, clear of the nudge bar.
        public static let bandInset = CardStyle.Coach.nudgeBar + CardStyle.Spacing.control
        /// Pointer travel before a press on the background becomes a drag.
        public static let dragSlop = Coach.controlInset

        public enum Symbols {
            public static let status = Coach.symbol
            public static let mute = "mic.fill"
            public static let unmute = "mic.slash.fill"
            public static let micOff = Coach.micOffSymbol
            public static let pause = Coach.pauseSymbol
            public static let resume = Coach.resumeSymbol
            public static let stop = "stop.fill"
            public static let minimize = "arrow.down.right.and.arrow.up.left"
            public static let expand = "arrow.up.left.and.arrow.down.right"
        }

        public struct Frame: Equatable, Sendable {
            public var x: Double, y: Double, width: Double, height: Double
            public init(x: Double, y: Double, width: Double, height: Double) {
                self.x = x; self.y = y; self.width = width; self.height = height
            }
            public var maxX: Double { x + width }
            public var maxY: Double { y + height }
        }

        /// Card coordinates, bottom-left origin.
        public static var statusRow: Frame {
            Frame(x: leading, y: height - vertical - rowHeight, width: width - leading - trailing - iconButton - rowGap,
                  height: rowHeight)
        }
        public static var minimizeButton: Frame {
            Frame(x: width - trailing - iconButton, y: height - vertical - rowHeight, width: iconButton, height: iconButton)
        }
        /// The saving badge (#13c) at the right end of the status band, in band coordinates: the
        /// chip's inner control height and radius, inset like it; the caption indicator's padding,
        /// dot and gap around the label's own width, so the label never clips (the status text
        /// gives way instead).
        public static func savingBadge(labelWidth: Double) -> Frame {
            let c = Captions.self
            let h = Coach.pauseButtonSize
            let w = c.indicatorPadding + c.dotDiameter + c.indicatorGap + labelWidth + c.indicatorPadding
            return Frame(x: statusRow.width - Coach.controlInset - w, y: (rowHeight - h) / 2, width: w, height: h)
        }
        public static var savingBadgeRadius: Double { Coach.pauseButtonRadius }
        public static var captions: Frame {
            Frame(x: leading, y: vertical + rowHeight + rowGap, width: width - leading - trailing, height: captionsHeight)
        }
        public static var pauseButton: Frame {
            Frame(x: width - trailing - iconButton, y: vertical, width: iconButton, height: iconButton)
        }
        public static var muteButton: Frame {
            Frame(x: pauseButton.x - CardStyle.Spacing.control - iconButton, y: vertical, width: iconButton, height: iconButton)
        }
        public static func stopButton(labelWidth: Double) -> Frame {
            Frame(x: leading, y: vertical, width: labelWidth + 2 * textButtonPadding, height: rowHeight)
        }
        /// The tip row's frames, in card coordinates of a card `cardHeight(callModeTip: true)` tall: the
        /// usual content sits `tipExtra` higher than in a card without the tip.
        public static func tipDismissButton(labelWidth: Double) -> Frame {
            Frame(x: leading, y: vertical, width: labelWidth + 2 * Coach.controlInset, height: tipButtonHeight)
        }
        public static var tipText: Frame {
            Frame(x: leading, y: vertical + tipButtonHeight + rowGap, width: width - leading - trailing, height: tipTextHeight)
        }
    }

    /// The minimized coach: a pill with a grabber, the coach glyph, and Mute, Pause/Resume and Stop.
    /// While a nudge holds it tints, shows the nudge's leading bar, and widens for the nudge words.
    public enum CoachPill {
        public static let width = CardStyle.Coach.pill.width
        public static let height = CardStyle.Coach.pill.height
        public static let radius = CardStyle.Coach.pill.radius
        public static let grabber = CardStyle.Coach.grabber
        public static let grabberTop = Coach.controlInset
        public static let grabberColor = CardStyle.Text.tertiary
        public static let padding = Coach.paddingLeading
        public static let glyphSize = Coach.glyphSize
        public static let glyphGap = Coach.glyphGap
        public static let button = Coach.pauseButtonSize
        public static let buttonRadius = Coach.pauseButtonRadius
        public static let buttonGlyph = CardStyle.Typography.caption
        public static let buttonGap = Coach.controlInset
        public static let wordsFont = CoachCard.nudgeFont
        /// Room each side of the nudge words for the text field's own inset.
        public static let wordsInset = Coach.glyphGap
        public static let maxWidth = CardLayout.W
        public static var glyphX: Double { CardStyle.Coach.nudgeBar + padding }
        /// The coach's Mute, Mute in Zoom (only while it can act), Pause/Resume and Stop.
        public static func buttonsWidth(_ n: Int = 3) -> Double { Double(n) * button + Double(max(0, n - 1)) * buttonGap }
        /// The row's vertical center, under the grabber.
        public static var rowMidY: Double { (height - grabberTop - grabber.height) / 2 }

        /// Pill width for nudge words `wordsWidth` wide (nil: no nudge), between the pill and card widths.
        public static func width(wordsWidth: Double?, buttons n: Int = 3) -> Double {
            guard let w = wordsWidth else { return width }
            let need = glyphX + glyphSize + glyphGap + w + CardStyle.Spacing.control + buttonsWidth(n) + padding
            return min(maxWidth, max(width, need))
        }

        /// The words' room in a pill `pillWidth` wide.
        public static func wordsRoom(pillWidth: Double, buttons n: Int = 3) -> Double {
            max(0, pillWidth - glyphX - glyphSize - glyphGap - CardStyle.Spacing.control - buttonsWidth(n) - padding)
        }

        /// The buttons' x positions (pill coordinates), right-aligned.
        public static func buttonXs(pillWidth: Double, buttons n: Int = 3) -> [Double] {
            let first = pillWidth - padding - buttonsWidth(n)
            return (0..<n).map { first + Double($0) * (button + buttonGap) }
        }
    }

    /// Live captions, drawn inside the reminder card by `CaptionFeedView` (no surface or window of
    /// their own; the card supplies both). Lines use the card's text inset and type scale: speaker
    /// labels in the button font (the user's own in the accent), words in the body font. The saving
    /// indicator is the card's secondary control (control height, radius, Ignore fill and hairline)
    /// with a critical-red dot one control gap wide.
    public enum Captions {
        /// The width a card gives its content (snapshots render the feed at this width).
        public static let cardWidth = CardLayout.W
        /// Leading and trailing inset, like the card's Ends and Next up lines.
        public static let inset = CardStyle.Spacing.text
        public static let lineGap = CardStyle.Spacing.control / 2
        public static let speakerGap = CardStyle.Spacing.control
        public static let speakerFont = CardStyle.Typography.button
        public static let textFont = CardStyle.Typography.body
        public static let noteFont = CardStyle.Typography.caption
        /// "Live captions": the card's button type in the primary role.
        public static let headerFont = CardStyle.Typography.button
        public static let header = CardStyle.Text.primary
        /// The memory-only / saving line under the captions: caption type, tertiary role.
        public static let footnoteFont = CardStyle.Typography.caption
        public static let footnote = CardStyle.Text.tertiary
        /// Caption lines shown at once (the in-memory buffer holds no more).
        public static let visibleLines = 3
        public static let indicatorHeight = CardStyle.Size.control
        public static let indicatorRadius = CardStyle.Radius.control
        public static let indicatorPadding = CardStyle.Spacing.control
        public static let indicatorFont = CardStyle.Typography.caption
        /// Dot to label, like the chip's glyph gap.
        public static let indicatorGap = CardStyle.Spacing.control / 2
        public static let dotDiameter = CardStyle.Spacing.control
        public static let hairlineWidth = CardStyle.Stroke.hairline
        /// Indicator to the first caption line.
        public static let stackGap = CardStyle.Spacing.control
        /// The cost meter's line in Settings: caption type in the secondary text role.
        public static let costFont = CardStyle.Typography.caption
        public static let cost = CardStyle.Text.secondary
        public static func indicatorFill(style: CardStyle) -> RGBA { style.controlFill(.normal) }
        public static func hairline(style: CardStyle) -> RGBA { style.hairline }
        public static func dot(style: CardStyle) -> RGBA { style.critical }
        /// The dot's live system color (AppKit surfaces draw it dynamically, like the glow).
        public static let dotColor = CardStyle.criticalColor
        public static let text = CardStyle.Text.primary
        public static let speaker = CardStyle.Text.secondary
        /// The user's own label: the card's accent (Next up blue).
        public static let ownSpeaker = CardStyle.Text.accent
        public static let note = CardStyle.Text.secondary
        public static let savingLabel = CardStyle.Text.primary
        /// Status menu entries for the saved transcript.
        public static let menuSymbols = (saving: "record.circle", delete: "trash")

        /// In the coach card's captions area (`CoachCard.captions`): one row per caption line of the
        /// reminder card, caption type, no header or indicator (the card has its own status row); the
        /// footnote takes the last row when set.
        public static var cardArea: CoachCard.Frame { CoachCard.captions }
        public static let cardRowHeight = Metrics.captionHeight
        public static let cardRows = Int(CoachCard.captionsHeight / Metrics.captionHeight)
        /// Rows are spaced by their height (the card's caption line), not by a gap.
        public static let cardLineGap: Double = 0
        public static let cardTextFont = CoachCard.captionsFont
        public static let cardSpeakerFont = Theme.FontSpec(CardStyle.Typography.caption.size, CardStyle.Typography.button.weight)
    }

    /// The one-time transcription notice: a card-shaped sheet (card width, surface, text insets) with
    /// the card's title and body type and its two buttons (secondary = Ignore, primary = Join).
    public enum Notice {
        public static let width = CardLayout.W
        public static let padding = (h: CardStyle.Spacing.leading, v: CardStyle.Spacing.stack)
        public static let spacing = CardStyle.Spacing.control
        public static let titleFont = CardStyle.Typography.title
        public static let bodyFont = CardStyle.Typography.body
        public static let draftFont = CardStyle.Typography.caption
        public static let buttonFont = CardStyle.Typography.button
        public static let buttonHeight = CardStyle.Size.control
        public static let buttonRadius = CardStyle.Radius.control
        public static let buttonGap = CardStyle.Spacing.control
        public static let buttonPadding = CardStyle.Spacing.leading
        public static func surface(style: CardStyle) -> RGBA { style.surface }
        public static let body = CardStyle.Text.secondary
        public static let draft = CardStyle.Text.warning
    }
}
