import AppKit
import ListenMoreCore
import MeetingCardCore

/// The coach chip on the live card's button row. Shown only while the coach is pre-warmed or
/// running; the card without a chip is the unchanged reminder card.
struct CoachChip: Equatable {
    enum Mode: Equatable { case on, listening, paused, muted, micOff }
    var mode: Mode
    /// Fixture runs only: a longer label, to show the collapse rule (`Theme.Coach.layout`).
    var labelOverride: String?

    init(mode: Mode, labelOverride: String? = nil) { self.mode = mode; self.labelOverride = labelOverride }

    init?(_ indicator: CoachIndicator) {
        switch indicator {
        case .hidden: return nil
        case .on: mode = .on
        case .listening: mode = .listening
        case .paused: mode = .paused
        case .muted: mode = .muted
        case .micOff: mode = .micOff
        }
    }

    var label: String {
        if let labelOverride { return labelOverride }
        return switch mode {
        case .on: "On"
        case .listening: "Listening"
        case .paused: "Paused"
        case .muted: CoachCopy.chipMuted
        case .micOff: CoachCopy.chipMicOff
        }
    }

    var accessibilityLabel: String {
        switch mode {
        case .on: CoachCopy.coachOn
        case .listening: CoachCopy.coachListening
        case .paused: CoachCopy.coachPaused
        case .muted: CoachCopy.coachMuted
        case .micOff: CoachCopy.coachMicOff
        }
    }

    /// Pause (On: skip this call; Listening: pause) or Resume.
    var controlSymbol: String { mode == .paused ? Theme.Coach.resumeSymbol : Theme.Coach.pauseSymbol }

    var controlLabel: String { mode == .paused ? "Resume" : "Pause" }

    var live: Bool { mode == .listening }

    /// Not capturing (the user's pause, or muted in the call app), or not hearing the user (the coach's
    /// own Mute): drawn like the paused chip.
    var held: Bool { mode == .paused || mode == .muted || mode == .micOff }

    /// The coach glyph, or the mic-off glyph while the coach's own Mute is on.
    var symbol: String { mode == .micOff ? Theme.Coach.micOffSymbol : Theme.Coach.symbol }
}

/// The chip's inner Start/Pause/Resume control (first click works on the non-activating card).
final class CoachChipControl: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

/// Ignore-styled container: same radius, height, hairline and fill as the card's Ignore button.
final class CoachChipView: NSView {
    let chip: CoachChip
    let control = CoachChipControl(frame: .zero)
    private(set) var showsLabel = true

    static func symbol(_ name: String, size: Double, weight: NSFont.Weight, label: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: CGFloat(size), weight: weight))
    }

    static func makeLabel(_ chip: CoachChip, color: NSColor = .labelColor) -> NSTextField {
        let f = NSTextField(labelWithString: chip.label)
        f.font = Theme.font(Theme.Coach.labelFont)
        f.textColor = color
        return f
    }

    /// Includes the text field's cell padding, so the label never clips.
    static func labelWidth(_ chip: CoachChip) -> Double {
        Double(makeLabel(chip).intrinsicContentSize.width.rounded(.up))
    }

    /// Frame (card coordinates) right-anchored `Theme.Coach.clearance` left of `joinX`.
    static func frame(_ chip: CoachChip, joinX: Double?) -> (NSRect, Bool) {
        let l = Theme.Coach.layout(labelWidth: labelWidth(chip), joinX: joinX)
        let m = Theme.Metrics.self
        return (NSRect(x: l.x, y: m.buttonBottom, width: l.width, height: Theme.Coach.height), l.showsLabel)
    }

    init(chip: CoachChip, joinX: Double?, style: CardStyle, target: AnyObject?, action: Selector?) {
        self.chip = chip
        let (frame, showsLabel) = Self.frame(chip, joinX: joinX)
        self.showsLabel = showsLabel
        super.init(frame: frame)
        let c = Theme.Coach.self
        let paused = chip.held
        let weight = Theme.weight(c.glyphFont)
        wantsLayer = true
        layer?.cornerRadius = Theme.cg(c.radius)
        layer?.cornerCurve = .continuous
        layer?.backgroundColor = Theme.ns(c.fill(style: style)).cgColor
        layer?.borderWidth = Theme.cg(CardStyle.Stroke.hairline)
        layer?.borderColor = Theme.ns(style.hairline).cgColor
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(showsLabel ? chip.accessibilityLabel : "\(chip.accessibilityLabel): \(chip.label)")
        if !showsLabel { toolTip = chip.label }

        let fg = Theme.text(paused ? c.heldText : c.text, style)
        var x = c.paddingLeading
        let midY = frame.height / 2
        let glyph = NSImageView(image: Self.symbol(chip.symbol, size: c.glyphSize, weight: weight, label: chip.accessibilityLabel) ?? NSImage())
        glyph.contentTintColor = chip.live ? Theme.ns(c.live(style: style)) : fg
        glyph.frame = NSRect(x: x, y: Double(midY) - c.glyphSize / 2, width: c.glyphSize, height: c.glyphSize)
        addSubview(glyph)
        x += c.glyphSize

        if showsLabel {
            x += c.glyphGap
            let w = Self.labelWidth(chip)
            let label = Self.makeLabel(chip, color: fg)
            let h = Double(label.intrinsicContentSize.height)
            label.frame = NSRect(x: x, y: Double(midY) - h / 2, width: w, height: h)
            label.setAccessibilityElement(false)
            addSubview(label)
        }

        let size = c.pauseButtonSize
        control.frame = NSRect(x: Double(frame.width) - c.paddingTrailing - size, y: Double(midY) - size / 2, width: size, height: size)
        control.isBordered = false
        control.title = ""
        control.image = Self.symbol(chip.controlSymbol, size: c.pauseGlyphSize, weight: weight, label: chip.controlLabel)
        control.imagePosition = .imageOnly
        control.contentTintColor = fg
        control.wantsLayer = true
        control.layer?.cornerRadius = Theme.cg(c.pauseButtonRadius)
        control.layer?.cornerCurve = .continuous
        control.layer?.backgroundColor = Theme.ns(c.pauseButtonFill(style: style)).cgColor
        control.setAccessibilityLabel(chip.controlLabel)
        control.toolTip = chip.controlLabel
        control.target = target
        control.action = action
        addSubview(control)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}
