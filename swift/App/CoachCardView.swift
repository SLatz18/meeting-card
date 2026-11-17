import AppKit
import ListenMoreCore
import MeetingCardCore

/// What the coach card's controls do.
@MainActor
struct CoachCardActions {
    var stop: () -> Void = {}
    var mute: () -> Void = {}
    var pause: () -> Void = {}
    /// Minimize on the card, Expand on the pill.
    var resize: () -> Void = {}
}

extension CoachCardState.Status {
    init?(_ indicator: CoachIndicator) {
        switch indicator {
        case .hidden: return nil
        case .on: self = .idle
        case .listening: self = .listening
        case .paused: self = .paused
        case .muted: self = .muted
        }
    }

    /// The status line; Muted is folded in as the held line, not a separate chip.
    var text: String {
        switch self {
        case .idle: CoachCopy.coachOn
        case .listening: CoachCopy.coachListening
        case .paused: CoachCopy.coachPaused
        case .muted: CoachCopy.coachMuted
        }
    }
}

extension CoachNudge {
    init?(_ cue: Cue) {
        guard let kind = Kind(rawValue: cue.type.rawValue) else { return nil }
        let tone: Tone = switch cue.color {
        case .red: .rose
        case .amber: .amber
        }
        self.init(kind: kind, tone: tone)
    }

    /// The glow's live rose or amber (system colors, so dark mode and Increase Contrast flow through).
    var color: NSColor {
        let g = Theme.Glow.self
        switch tone {
        case .rose: return CardStyle.dynamic(g.roseSource) { g.rose(base: $0, dark: $1) }
        case .amber: return CardStyle.dynamic(g.amberSource) { g.amber(base: $0, dark: $1) }
        }
    }
}

/// One coach layout (the full card or the pill), laid out for its own size and updated in place.
/// A press anywhere but a control drags the panel (kept on screen by `clamp`); a press that
/// doesn't move is a click.
class CoachSurfaceView: NSView {
    var actions: CoachCardActions
    private(set) var state: CoachCardState
    var onClick: (() -> Void)?
    var onDragged: (() -> Void)?
    var clamp: ((NSPoint) -> NSPoint)?
    /// Views that get their own pointer events (the captions).
    var passthrough: NSView?
    fileprivate var built = false

    init(state: CoachCardState, actions: CoachCardActions, size: NSSize) {
        self.state = state
        self.actions = actions
        super.init(frame: NSRect(origin: .zero, size: size))
        wantsLayer = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    var surfaceRadius: Double { Theme.CoachCard.radius }
    var dark: Bool { effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
    var style: CardStyle { Theme.style(dark: dark) }

    func apply(_ s: CoachCardState) { state = s }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if built { apply(state) }
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let v = super.hitTest(point) else { return nil }
        if v is NSButton { return v }
        if let p = passthrough, v === p || v.isDescendant(of: p) { return v }
        return self
    }

    override func mouseDown(with event: NSEvent) {
        guard let w = window else { return }
        let start = NSEvent.mouseLocation, origin = w.frame.origin
        var dragging = false
        while let e = w.nextEvent(matching: [.leftMouseDragged, .leftMouseUp]), e.type == .leftMouseDragged {
            let p = NSEvent.mouseLocation
            let dx = p.x - start.x, dy = p.y - start.y
            if !dragging, hypot(dx, dy) < Theme.cg(Theme.CoachCard.dragSlop) { continue }
            dragging = true
            let o = NSPoint(x: origin.x + dx, y: origin.y + dy)
            w.setFrameOrigin(clamp?(o) ?? o)
        }
        if dragging { onDragged?() } else { onClick?() }
    }

    /// A layer color for this view's appearance.
    func cg(_ c: NSColor, alpha: Double? = nil) -> CGColor {
        var out = c.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { out = c.cgColor }
        return alpha.map { out.copy(alpha: CGFloat($0)) ?? out } ?? out
    }

    /// The nudge's tint, outline and bar on `box` (cleared without a nudge).
    func applyNudge(_ nudge: CoachNudge?, box: NSView, bar: NSView) {
        guard let nudge else {
            box.layer?.backgroundColor = NSColor.clear.cgColor
            box.layer?.borderWidth = 0
            bar.isHidden = true
            return
        }
        let ic = state.increasedContrast
        let edge = cg(nudge.color, alpha: CardStyle.Coach.nudgeEdgeAlpha(dark: dark, increasedContrast: ic))
        box.layer?.backgroundColor = cg(nudge.color, alpha: CardStyle.Coach.nudgeTint(dark: dark, increasedContrast: ic))
        box.layer?.borderWidth = Theme.cg(CardStyle.Coach.nudgeBorder)
        box.layer?.borderColor = edge
        bar.isHidden = false
        bar.layer?.backgroundColor = edge
    }

    @objc func stopPressed(_ sender: Any?) { actions.stop() }
    @objc func mutePressed(_ sender: Any?) { actions.mute() }
    @objc func pausePressed(_ sender: Any?) { actions.pause() }
    @objc func resizePressed(_ sender: Any?) { actions.resize() }

    /// The card's secondary button (Ignore's fill, hairline, hover and pressed states).
    func button(radius: Double, action: Selector) -> CardButton {
        let b = CardButton(frame: .zero)
        b.role = .ignore
        b.style = { [weak self] in self?.style ?? .for(dark: false) }
        b.isBordered = false
        b.title = ""
        b.wantsLayer = true
        b.layer?.cornerRadius = Theme.cg(radius)
        b.layer?.cornerCurve = .continuous
        b.target = self
        b.action = action
        return b
    }

    func set(_ b: CardButton, _ c: CoachControl, glyph: Theme.FontSpec) {
        b.image = Theme.symbol(c.symbol, glyph, label: c.accessibilityLabel)
        b.imagePosition = .imageOnly
        b.contentTintColor = Theme.text(.primary, style)
        b.toolTip = c.tooltip
        b.setAccessibilityLabel(c.accessibilityLabel)
        b.setAccessibilityHelp(c.accessibilityHelp)
        b.isEnabled = c.enabled
        b.applyFill()
    }

    static func label() -> NSTextField {
        let f = NSTextField(labelWithString: "")
        f.cell?.lineBreakMode = .byTruncatingTail
        f.maximumNumberOfLines = 1
        f.usesSingleLineMode = true
        f.setAccessibilityElement(false)
        return f
    }

    static func layerView() -> NSView {
        let v = NSView()
        v.wantsLayer = true
        return v
    }

    static func glyphImage(_ label: String) -> NSImage? {
        CoachChipView.symbol(Theme.CoachCard.Symbols.status, size: Theme.CoachCard.glyphSize,
                             weight: Theme.weight(Theme.CoachCard.iconGlyph), label: label)
    }

    /// The coach glyph's tint: live while listening, otherwise the line's own color.
    func glyphTint(_ line: NSColor) -> NSColor {
        state.live && state.nudge == nil ? Theme.ns(Theme.Coach.live(style: style)) : line
    }

    /// Status line (or nudge words) color.
    var lineColor: NSColor {
        let k = Theme.CoachCard.self
        return Theme.text(state.nudge != nil ? k.nudgeText : state.held ? k.heldText : k.statusText, style)
    }
}

/// The full coach card: status line (the nudge band while a nudge holds) with Minimize, the
/// captions area, and Stop coach, Mute and Pause/Resume on the button row.
final class CoachFullCardView: CoachSurfaceView {
    private let band = CoachSurfaceView.layerView()
    private let bar = CoachSurfaceView.layerView()
    private let glyph = NSImageView()
    private let line = CoachSurfaceView.label()
    private let captionsBox = NSView()
    /// The saving badge on the status line (Save transcripts on): dot and label in a chip-shaped pill.
    private let badge = CoachSurfaceView.layerView()
    private let badgeDot = CoachSurfaceView.layerView()
    /// A plain label (not the truncating status label): sized to its text, it never cuts it.
    private let badgeLabel = NSTextField(labelWithString: "")
    private var lineWidth: CGFloat = 0
    private(set) var minimize: CardButton!
    private(set) var stop: CardButton!
    private(set) var mute: CardButton!
    private(set) var pause: CardButton!

    static var size: NSSize { NSSize(width: Theme.CoachCard.width, height: Theme.CoachCard.height) }

    static func stopLabelWidth() -> Double {
        let f = CoachSurfaceView.label()
        f.font = Theme.font(Theme.CoachCard.buttonFont)
        f.stringValue = CoachCardCopy.Button.stop
        return Double(f.intrinsicContentSize.width.rounded(.up))
    }

    init(state: CoachCardState, actions: CoachCardActions, captions: NSView) {
        super.init(state: state, actions: actions, size: Self.size)
        let k = Theme.CoachCard.self
        func rect(_ f: Theme.CoachCard.Frame) -> NSRect { NSRect(x: f.x, y: f.y, width: f.width, height: f.height) }

        let row = k.statusRow
        band.frame = rect(row)
        band.layer?.cornerRadius = Theme.cg(k.bandRadius)
        band.layer?.cornerCurve = .continuous
        band.layer?.masksToBounds = true
        band.setAccessibilityElement(true)
        band.setAccessibilityRole(.staticText)
        addSubview(band)
        bar.frame = NSRect(x: 0, y: 0, width: CardStyle.Coach.nudgeBar, height: row.height)
        band.addSubview(bar)
        glyph.frame = NSRect(x: k.bandInset, y: (row.height - k.glyphSize) / 2, width: k.glyphSize, height: k.glyphSize)
        glyph.setAccessibilityElement(false)
        band.addSubview(glyph)
        line.frame = NSRect(x: k.bandInset + k.glyphSize + k.glyphGap, y: 0,
                            width: row.width - k.bandInset - k.glyphSize - k.glyphGap - CardStyle.Spacing.control, height: row.height)
        lineWidth = line.frame.width
        band.addSubview(line)
        badge.layer?.cornerRadius = Theme.cg(k.savingBadgeRadius)
        badge.layer?.cornerCurve = .continuous
        badge.layer?.borderWidth = Theme.cg(Theme.Captions.hairlineWidth)
        badgeDot.layer?.cornerRadius = Theme.cg(Theme.Captions.dotDiameter / 2)
        badge.addSubview(badgeDot)
        badgeLabel.setAccessibilityElement(false)
        badge.addSubview(badgeLabel)
        badge.isHidden = true
        band.addSubview(badge)

        minimize = button(radius: k.iconButtonRadius, action: #selector(resizePressed(_:)))
        minimize.frame = rect(k.minimizeButton)
        addSubview(minimize)

        captionsBox.frame = rect(k.captions)
        captions.frame = captionsBox.bounds
        captions.autoresizingMask = [.width, .height]
        captionsBox.addSubview(captions)
        addSubview(captionsBox)
        passthrough = captionsBox

        stop = button(radius: CardStyle.Radius.control, action: #selector(stopPressed(_:)))
        stop.frame = rect(k.stopButton(labelWidth: Self.stopLabelWidth()))
        addSubview(stop)
        mute = button(radius: k.iconButtonRadius, action: #selector(mutePressed(_:)))
        mute.frame = rect(k.muteButton)
        addSubview(mute)
        pause = button(radius: k.iconButtonRadius, action: #selector(pausePressed(_:)))
        pause.frame = rect(k.pauseButton)
        addSubview(pause)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel(CoachCopy.toggle)
        built = true
        apply(state)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func apply(_ s: CoachCardState) {
        super.apply(s)
        let k = Theme.CoachCard.self
        let fg = lineColor
        let text = s.nudge?.words ?? s.status.text
        line.font = Theme.font(s.nudge != nil ? k.nudgeFont : k.statusFont)
        line.textColor = fg
        line.stringValue = text
        let h = line.intrinsicContentSize.height
        line.frame.origin.y = (band.frame.height - h) / 2
        line.frame.size.height = h
        glyph.image = Self.glyphImage(text)
        glyph.contentTintColor = glyphTint(fg)
        band.setAccessibilityLabel([text, s.savingBadge].compactMap { $0 }.joined(separator: ", "))
        applyNudge(s.nudge, box: band, bar: bar)
        applyBadge(s.savingBadge)

        let icon = k.iconGlyph
        set(minimize, s.sizeControl, glyph: icon)
        set(mute, s.muteControl, glyph: icon)
        mute.isHidden = !s.showsMute
        set(pause, s.pauseControl, glyph: icon)
        let stopControl = s.stopControl
        stop.attributedTitle = Card.attr(CoachCardCopy.Button.stop, Theme.font(k.buttonFont), Theme.text(.primary, style))
        stop.toolTip = stopControl.tooltip
        stop.setAccessibilityLabel(stopControl.accessibilityLabel)
        stop.applyFill()
    }

    /// The saving badge at the band's right end, sized to its label (measured as a plain label, so
    /// it never clips); the status text ends before it and truncates if it must.
    private func applyBadge(_ label: String?) {
        guard let label else {
            badge.isHidden = true
            line.frame.size.width = lineWidth
            return
        }
        let c = Theme.Captions.self
        let measure = NSTextField(labelWithString: label)
        measure.font = Theme.font(c.indicatorFont)
        let textW = measure.intrinsicContentSize.width.rounded(.up)
        let f = Theme.CoachCard.savingBadge(labelWidth: Double(textW))
        badge.frame = NSRect(x: Theme.cg(f.x), y: Theme.cg(f.y), width: Theme.cg(f.width), height: Theme.cg(f.height))
        badge.layer?.backgroundColor = Theme.ns(c.indicatorFill(style: style).over(style.surface)).cgColor
        badge.layer?.borderColor = Theme.ns(c.hairline(style: style)).cgColor
        let pad = Theme.cg(c.indicatorPadding), dot = Theme.cg(c.dotDiameter), gap = Theme.cg(c.indicatorGap), bh = Theme.cg(f.height)
        badgeDot.frame = NSRect(x: pad, y: (bh - dot) / 2, width: dot, height: dot)
        badgeDot.layer?.backgroundColor = cg(CardStyle.dynamic(c.dotColor) { base, _ in base })
        badgeLabel.font = Theme.font(c.indicatorFont)
        badgeLabel.textColor = Theme.text(c.savingLabel, style)
        badgeLabel.stringValue = label
        let h = badgeLabel.intrinsicContentSize.height
        badgeLabel.frame = NSRect(x: pad + dot + gap, y: (bh - h) / 2, width: textW, height: h)
        badge.isHidden = false
        line.frame.size.width = max(0, min(lineWidth, Theme.cg(f.x) - line.frame.minX - Theme.cg(CardStyle.Spacing.control)))
    }
}

/// The minimized coach: grabber, coach glyph (and the nudge words while one holds), then Mute,
/// Pause/Resume and Stop. A click on the pill (or VoiceOver's press on the grabber) expands it.
final class CoachPillView: CoachSurfaceView {
    private let bar = CoachSurfaceView.layerView()
    private let grabber = CoachGrabber()
    private let glyph = NSImageView()
    private let words = CoachSurfaceView.label()
    private(set) var mute: CardButton!
    private(set) var pause: CardButton!
    private(set) var stop: CardButton!
    /// Laid out for this many buttons (Mute is left out with no Zoom call).
    let buttons: Int

    override var surfaceRadius: Double { Theme.CoachPill.radius }

    /// The words' label width: the text plus the text field's inset each side, so they never clip.
    static func wordsWidth(_ nudge: CoachNudge?) -> Double {
        guard let nudge else { return 0 }
        let text = (nudge.words as NSString).size(withAttributes: [.font: Theme.font(Theme.CoachPill.wordsFont)]).width
        return Double(text.rounded(.up)) + 2 * Theme.CoachPill.wordsInset
    }

    static func width(for s: CoachCardState) -> Double { s.pillWidth(wordsWidth: wordsWidth(s.nudge)) }

    init(state: CoachCardState, actions: CoachCardActions) {
        let p = Theme.CoachPill.self
        let w = Self.width(for: state)
        buttons = state.pillButtons
        super.init(state: state, actions: actions, size: NSSize(width: w, height: p.height))
        layer?.cornerRadius = Theme.cg(p.radius)
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true

        bar.frame = NSRect(x: 0, y: 0, width: CardStyle.Coach.nudgeBar, height: p.height)
        addSubview(bar)
        grabber.frame = NSRect(x: (w - p.grabber.width) / 2, y: p.height - p.grabberTop - p.grabber.height,
                               width: p.grabber.width, height: p.grabber.height)
        grabber.wantsLayer = true
        grabber.layer?.cornerRadius = Theme.cg(p.grabber.height / 2)
        grabber.onPress = { [weak self] in self?.actions.resize() }
        addSubview(grabber)
        glyph.frame = NSRect(x: p.glyphX, y: p.rowMidY - p.glyphSize / 2, width: p.glyphSize, height: p.glyphSize)
        glyph.setAccessibilityElement(false)
        addSubview(glyph)
        let wx = p.glyphX + p.glyphSize + p.glyphGap
        words.frame = NSRect(x: wx, y: p.rowMidY, width: p.wordsRoom(pillWidth: w, buttons: buttons), height: 0)
        addSubview(words)

        mute = button(radius: p.buttonRadius, action: #selector(mutePressed(_:)))
        pause = button(radius: p.buttonRadius, action: #selector(pausePressed(_:)))
        stop = button(radius: p.buttonRadius, action: #selector(stopPressed(_:)))
        let shown: [CardButton] = state.showsMute ? [mute, pause, stop] : [pause, stop]
        mute.isHidden = !state.showsMute
        for (b, x) in zip(shown, p.buttonXs(pillWidth: w, buttons: buttons)) {
            b.frame = NSRect(x: x, y: p.rowMidY - p.button / 2, width: p.button, height: p.button)
        }
        for b in [mute!, pause!, stop!] { addSubview(b) }
        onClick = { [weak self] in self?.actions.resize() }
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        built = true
        apply(state)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func apply(_ s: CoachCardState) {
        super.apply(s)
        let p = Theme.CoachPill.self
        let fg = lineColor
        applyNudge(s.nudge, box: self, bar: bar)
        grabber.layer?.backgroundColor = cg(Theme.text(p.grabberColor, style))
        let size = s.sizeControl
        grabber.toolTip = size.tooltip
        grabber.setAccessibilityLabel(size.accessibilityLabel)
        toolTip = size.tooltip
        glyph.image = Self.glyphImage(s.status.text)
        glyph.contentTintColor = glyphTint(fg)
        words.isHidden = s.nudge == nil
        words.font = Theme.font(p.wordsFont)
        words.textColor = fg
        words.stringValue = s.nudge?.words ?? ""
        let h = words.intrinsicContentSize.height
        words.frame.origin.y = p.rowMidY - h / 2
        words.frame.size.height = h
        setAccessibilityLabel(s.nudge.map { "\(s.status.text). \($0.words)" } ?? s.status.text)
        set(mute, s.muteControl, glyph: p.buttonGlyph)
        set(pause, s.pauseControl, glyph: p.buttonGlyph)
        set(stop, s.stopControl, glyph: p.buttonGlyph)
    }
}

/// The pill's drag handle, and for VoiceOver its Expand button.
final class CoachGrabber: NSView {
    var onPress: (() -> Void)?

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .button }
    override func accessibilityPerformPress() -> Bool {
        onPress?()
        return true
    }
}
