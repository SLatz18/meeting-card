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
    /// AppKit's systemRed in sRGB; the App uses the live semantic `NSColor.systemRed`.
    public var critical: RGBA { dark ? RGBA(hex: 0xFF453A) : RGBA(hex: 0xFF3B30) }
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

    /// Screen-edge glow for coach cues: calm, peripheral, plays once. Colors are the card's color
    /// roles muted toward neutral gray (rose from `critical`, amber from the dark card's `warning`,
    /// the vivid flag hue, for both appearances), near the design tokens #A65B57/#C47A76 and
    /// #B4843A/#D4A45A. The corner radius is the card's, the band one control height wide.
    public enum Glow {
        /// NSColor.systemRed in sRGB (light / dark): the card style's `critical`.
        public static func systemRed(dark: Bool) -> RGBA { CardStyle.for(dark: dark).critical }

        /// Mix `c` toward a neutral gray: light appearance mutes harder and darker.
        public static func mute(_ c: RGBA, dark: Bool, amount: Double? = nil, gray: Double? = nil) -> RGBA {
            let gray = gray ?? (dark ? 0.6 : 0.5)
            let k = amount ?? (dark ? 0.55 : 0.65)
            return RGBA(c.r * (1 - k) + gray * k, c.g * (1 - k) + gray * k, c.b * (1 - k) + gray * k, 1)
        }

        /// Interrupt, talk-over, aggressive.
        public static func rose(dark: Bool) -> RGBA {
            mute(CardStyle.for(dark: dark).critical, dark: dark)
        }

        /// Monologue, missed question, not listening, talk share.
        public static func amber(dark: Bool) -> RGBA {
            mute(CardStyle.for(dark: true).warning, dark: dark, amount: 0.48, gray: dark ? 0.65 : 0.4)
        }

        public static let width = CardStyle.Size.control
        public static let cornerRadius = CardStyle.Radius.card
        /// Glow behaviour (calibrated, not card tokens): peak opacity, falloff and timing.
        public static let peakOpacity: Double = 0.45
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
        /// SF Symbols for the coach status menu, drawn at the body font size like a native menu.
        public static let menuSymbols = (enable: "power", start: resumeSymbol, skip: "forward.end.fill",
                                         pause: pauseSymbol, resume: resumeSymbol, turnOff: "power",
                                         gptOffNoKey: "key", gptOffRejected: "exclamationmark.triangle",
                                         settings: "gearshape")
        public static let menuSymbolSize = CardStyle.Typography.body.size
        /// The status bar glyph, at the button font size and weight.
        public static let statusSymbolFont = CardStyle.Typography.button
        public static let glyphSize = CardStyle.Size.icon
        public static let glyphFont = CardStyle.Typography.button
        /// Right edge sits one control gap left of the Join button (or of the Join slot if none).
        public static let joinGap = CardStyle.Spacing.control
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

        /// Chip frame in card coordinates: content-hugging width, right-anchored `joinGap` left of
        /// Join. The label is dropped (glyph and control stay) if the chip would reach the Ignore
        /// button, e.g. next to the wide multi-link Join.
        public static func layout(labelWidth: Double, joinX: Double?) -> (x: Double, width: Double, showsLabel: Bool) {
            let m = Metrics.self
            let right = (joinX ?? (m.cardWidth - m.trailingInset)) - joinGap
            let minX = m.leadingInset + m.ignoreWidth + m.controlGap
            func width(_ label: Bool) -> Double {
                paddingLeading + glyphSize + (label ? glyphGap + labelWidth : 0) + controlGap + pauseButtonSize + paddingTrailing
            }
            let full = width(true)
            if right - full >= minX { return (right - full, full, true) }
            let compact = width(false)
            return (right - compact, compact, false)
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
        public static func groupFill(style: CardStyle) -> RGBA { style.surface }
    }
}
