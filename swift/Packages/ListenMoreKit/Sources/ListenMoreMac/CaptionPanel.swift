import AppKit
import ListenMoreCore

/// The caption strip's look, owned by the host (MeetingCard builds it from its card tokens). The Kit
/// only lays out and draws. Colors may be dynamic (per appearance); they are resolved when drawn.
public struct CaptionStyle {
    /// Strip: the host's card surface.
    public var width: CGFloat
    public var radius: CGFloat
    public var padding: NSSize
    public var lineGap: CGFloat
    public var speakerGap: CGFloat
    public var surface: NSColor
    public var textColor: NSColor
    public var speakerColor: NSColor
    /// The user's own label ("You").
    public var ownSpeakerColor: NSColor
    public var noteColor: NSColor
    public var textFont: NSFont
    public var speakerFont: NSFont
    public var noteFont: NSFont
    /// Saving indicator: a pill above the strip.
    public var indicatorHeight: CGFloat
    public var indicatorRadius: CGFloat
    public var indicatorPadding: CGFloat
    /// Dot to label.
    public var indicatorGap: CGFloat
    public var indicatorFont: NSFont
    public var hairline: NSColor
    public var hairlineWidth: CGFloat
    public var dot: NSColor
    public var dotDiameter: CGFloat
    /// Space between the indicator and the strip.
    public var stackGap: CGFloat
    /// Distance from the display's visible bottom edge, and the width kept clear at its right
    /// (where the host's own window sits).
    public var margin: CGFloat
    public var trailingReserve: CGFloat
    public var level: NSWindow.Level

    public init(width: CGFloat, radius: CGFloat, padding: NSSize, lineGap: CGFloat, speakerGap: CGFloat,
                surface: NSColor, textColor: NSColor, speakerColor: NSColor, ownSpeakerColor: NSColor, noteColor: NSColor,
                textFont: NSFont, speakerFont: NSFont, noteFont: NSFont,
                indicatorHeight: CGFloat, indicatorRadius: CGFloat, indicatorPadding: CGFloat, indicatorGap: CGFloat,
                indicatorFont: NSFont,
                hairline: NSColor, hairlineWidth: CGFloat, dot: NSColor, dotDiameter: CGFloat,
                stackGap: CGFloat, margin: CGFloat, trailingReserve: CGFloat, level: NSWindow.Level = GlowPanel.overlayLevel) {
        self.width = width
        self.radius = radius
        self.padding = padding
        self.lineGap = lineGap
        self.speakerGap = speakerGap
        self.surface = surface
        self.textColor = textColor
        self.speakerColor = speakerColor
        self.ownSpeakerColor = ownSpeakerColor
        self.noteColor = noteColor
        self.textFont = textFont
        self.speakerFont = speakerFont
        self.noteFont = noteFont
        self.indicatorHeight = indicatorHeight
        self.indicatorRadius = indicatorRadius
        self.indicatorPadding = indicatorPadding
        self.indicatorGap = indicatorGap
        self.indicatorFont = indicatorFont
        self.hairline = hairline
        self.hairlineWidth = hairlineWidth
        self.dot = dot
        self.dotDiameter = dotDiameter
        self.stackGap = stackGap
        self.margin = margin
        self.trailingReserve = trailingReserve
        self.level = level
    }
}

/// What the strip shows. Content: RAM only, never logged.
public struct CaptionContent: Equatable {
    public struct Line: Equatable {
        public var speaker: String
        public var text: String
        /// The mic stream (the user).
        public var own: Bool

        public init(speaker: String, text: String, own: Bool) {
            self.speaker = speaker
            self.text = text
            self.own = own
        }
    }

    public var lines: [Line]
    /// A status line in place of captions (e.g. stopped at the cost cap).
    public var note: String?
    /// The saving indicator's label; nil = not saving.
    public var saving: String?

    public init(lines: [Line] = [], note: String? = nil, saving: String? = nil) {
        self.lines = lines
        self.note = note
        self.saving = saving
    }

    public var showsStrip: Bool { !lines.isEmpty || note != nil }
    public var isEmpty: Bool { !showsStrip && saving == nil }

    /// Caption strip lines from the live buffer, with the current speaker labels.
    public static func rows(_ captions: [CaptionLine], labels: SpeakerLabels) -> [Line] {
        captions.compactMap { c in
            let text = c.text
            return text.isEmpty ? nil : Line(speaker: labels.label(c.speaker), text: text, own: c.speaker == .me)
        }
    }
}

/// The saving indicator (pill) stacked above the caption strip, in one transparent view. Each
/// caption line is one row: the speaker label, then the newest words (older words are cut at the
/// start, so the end of what was said stays visible).
public final class CaptionView: NSView {
    public private(set) var style: CaptionStyle
    public private(set) var content = CaptionContent()
    public private(set) var strip: NSView?
    public private(set) var indicator: NSView?
    /// Text fields in row order: speaker, text, speaker, text, ... (or the note alone).
    public private(set) var stripLabels: [NSTextField] = []
    public private(set) var indicatorLabel: NSTextField?

    public init(style: CaptionStyle) {
        self.style = style
        super.init(frame: NSRect(x: 0, y: 0, width: style.width, height: 0))
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override public var isOpaque: Bool { false }

    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        rebuild()
    }

    public func apply(style: CaptionStyle) {
        self.style = style
        rebuild()
    }

    public func show(_ content: CaptionContent) {
        guard content != self.content else { return }
        self.content = content
        rebuild()
    }

    static func lineHeight(_ font: NSFont) -> CGFloat {
        (font.ascender - font.descender + font.leading).rounded(.up)
    }

    /// Height of the strip for `rows` rows.
    public static func stripHeight(_ style: CaptionStyle, rows: Int) -> CGFloat {
        guard rows > 0 else { return 0 }
        let row = max(lineHeight(style.textFont), lineHeight(style.speakerFont))
        return 2 * style.padding.height + CGFloat(rows) * row + CGFloat(rows - 1) * style.lineGap
    }

    /// The view's size for `content`.
    public static func size(_ style: CaptionStyle, _ content: CaptionContent) -> NSSize {
        let rows = content.lines.isEmpty ? (content.note == nil ? 0 : 1) : content.lines.count
        let strip = stripHeight(style, rows: rows)
        let pill = content.saving == nil ? 0 : style.indicatorHeight
        let gap = strip > 0 && pill > 0 ? style.stackGap : 0
        return NSSize(width: style.width, height: strip + gap + pill)
    }

    private func cg(_ c: NSColor) -> CGColor {
        var out = c.cgColor
        effectiveAppearance.performAsCurrentDrawingAppearance { out = c.cgColor }
        return out
    }

    /// A plain label's full width, cell padding included.
    public static func labelWidth(_ s: String, _ font: NSFont) -> CGFloat {
        let f = NSTextField(labelWithString: s)
        f.font = font
        return f.intrinsicContentSize.width.rounded(.up)
    }

    /// Labels sized to `labelWidth` keep the plain label's clipping mode (a truncating label needs
    /// more than its measured width and would cut its own text); only text that can run long
    /// truncates, in a frame wider than it usually needs.
    private func label(_ s: String, _ font: NSFont, _ color: NSColor, truncate: NSLineBreakMode? = nil) -> NSTextField {
        let f = NSTextField(labelWithString: s)
        f.font = font
        f.textColor = color
        if let truncate {
            f.maximumNumberOfLines = 1
            f.usesSingleLineMode = true
            f.lineBreakMode = truncate
            f.cell?.lineBreakMode = truncate
        }
        return f
    }

    private func rebuild() {
        subviews.forEach { $0.removeFromSuperview() }
        strip = nil
        indicator = nil
        stripLabels = []
        indicatorLabel = nil
        let s = style
        let size = Self.size(s, content)
        setFrameSize(size)
        // Laid out from the top edge down (unflipped coordinates): the indicator, then the strip.
        var top = size.height
        if let saving = content.saving {
            let text = label(saving, s.indicatorFont, s.textColor)
            let textW = Self.labelWidth(saving, s.indicatorFont)
            let w = s.indicatorPadding + s.dotDiameter + s.indicatorGap + textW + s.indicatorPadding
            let pill = NSView(frame: NSRect(x: 0, y: top - s.indicatorHeight, width: w, height: s.indicatorHeight))
            pill.wantsLayer = true
            pill.layer?.backgroundColor = cg(s.surface)
            pill.layer?.cornerRadius = s.indicatorRadius
            pill.layer?.cornerCurve = .continuous
            pill.layer?.borderWidth = s.hairlineWidth
            pill.layer?.borderColor = cg(s.hairline)
            let dot = NSView(frame: NSRect(x: s.indicatorPadding, y: (s.indicatorHeight - s.dotDiameter) / 2,
                                           width: s.dotDiameter, height: s.dotDiameter))
            dot.wantsLayer = true
            dot.layer?.backgroundColor = cg(s.dot)
            dot.layer?.cornerRadius = s.dotDiameter / 2
            pill.addSubview(dot)
            let th = text.intrinsicContentSize.height
            text.frame = NSRect(x: s.indicatorPadding + s.dotDiameter + s.indicatorGap,
                                y: (s.indicatorHeight - th) / 2, width: textW, height: th)
            pill.addSubview(text)
            pill.setAccessibilityElement(true)
            pill.setAccessibilityRole(.staticText)
            pill.setAccessibilityLabel(saving)
            addSubview(pill)
            indicator = pill
            indicatorLabel = text
            top -= s.indicatorHeight + (content.showsStrip ? s.stackGap : 0)
        }
        guard content.showsStrip else { return }
        let h = top
        let box = NSView(frame: NSRect(x: 0, y: 0, width: s.width, height: h))
        box.wantsLayer = true
        box.layer?.backgroundColor = cg(s.surface)
        box.layer?.cornerRadius = s.radius
        box.layer?.cornerCurve = .continuous
        box.layer?.masksToBounds = true
        addSubview(box)
        strip = box
        let row = max(Self.lineHeight(s.textFont), Self.lineHeight(s.speakerFont))
        let inner = s.width - 2 * s.padding.width
        top = h - s.padding.height
        if content.lines.isEmpty, let note = content.note {
            let n = label(note, s.noteFont, s.noteColor, truncate: .byTruncatingTail)
            n.frame = NSRect(x: s.padding.width, y: top - row, width: inner, height: row)
            box.addSubview(n)
            stripLabels = [n]
            return
        }
        let speakers = content.lines.map { label($0.speaker, s.speakerFont, $0.own ? s.ownSpeakerColor : s.speakerColor) }
        let column = min(inner / 2, content.lines.map { Self.labelWidth($0.speaker, s.speakerFont) }.max() ?? 0)
        for (line, name) in zip(content.lines, speakers) {
            name.frame = NSRect(x: s.padding.width, y: top - row, width: column, height: row)
            let text = label(line.text, s.textFont, s.textColor, truncate: .byTruncatingHead)
            let x = s.padding.width + column + s.speakerGap
            text.frame = NSRect(x: x, y: top - row, width: s.width - s.padding.width - x, height: row)
            box.addSubview(name)
            box.addSubview(text)
            stripLabels += [name, text]
            top -= row + s.lineGap
        }
        box.setAccessibilityElement(true)
        box.setAccessibilityRole(.group)
    }
}

/// Borderless, click-through, non-activating panel for the captions. Never key or main, so it can
/// never take keyboard focus from the call. `sharingType = .none`, like the glow, asks the window
/// server to leave it out of screen shares.
public final class CaptionPanel: NSPanel {
    public let captionView: CaptionView

    public init(style: CaptionStyle) {
        captionView = CaptionView(style: style)
        super.init(contentRect: NSRect(x: 0, y: 0, width: style.width, height: 1),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        sharingType = .none
        isFloatingPanel = true
        level = style.level
        collectionBehavior = GlowPanel.overlayCollectionBehavior
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
        contentView = captionView
    }

    override public var canBecomeKey: Bool { false }
    override public var canBecomeMain: Bool { false }
}

/// Places the caption panel on a display: bottom-centred on its visible frame, `margin` up from the
/// bottom, moved left if it would reach into the `trailingReserve` kept clear at the right.
public enum CaptionLayout {
    public static func frame(size: NSSize, visible: NSRect, margin: CGFloat, trailingReserve: CGFloat) -> NSRect {
        var x = visible.midX - size.width / 2
        let limit = visible.maxX - trailingReserve - margin
        if x + size.width > limit { x = limit - size.width }
        x = max(visible.minX + margin, x)
        return NSRect(x: x.rounded(), y: (visible.minY + margin).rounded(), width: size.width, height: size.height)
    }
}

/// Shows and hides the caption panel on the call's display. `screen` returns that display's
/// Cocoa frame (CoachService.callScreen, which uses CallDisplayLocator); nil = the main display.
@MainActor
public final class CaptionPanelController {
    public let panel: CaptionPanel
    public var screen: () -> NSRect? = { nil }
    private let visibleFrames: () -> [(frame: NSRect, visible: NSRect)]

    public init(style: CaptionStyle,
                visibleFrames: @escaping () -> [(frame: NSRect, visible: NSRect)] = { NSScreen.screens.map { ($0.frame, $0.visibleFrame) } }) {
        panel = CaptionPanel(style: style)
        self.visibleFrames = visibleFrames
    }

    public var isVisible: Bool { panel.isVisible }
    public var content: CaptionContent { panel.captionView.content }

    public func apply(style: CaptionStyle) {
        panel.level = style.level
        panel.captionView.apply(style: style)
    }

    public func show(_ content: CaptionContent) {
        guard !content.isEmpty else { return hide() }
        let view = panel.captionView
        view.show(content)
        let s = view.style
        let size = CaptionView.size(s, content)
        let frames = visibleFrames()
        let target = screen()
        let visible = frames.first { $0.frame == target }?.visible ?? frames.first?.visible
            ?? NSRect(x: 0, y: 0, width: size.width, height: size.height)
        panel.setFrame(CaptionLayout.frame(size: size, visible: visible, margin: s.margin, trailingReserve: s.trailingReserve),
                       display: true)
        if !panel.isVisible { panel.orderFrontRegardless() }
    }

    public func hide() {
        panel.captionView.show(CaptionContent())
        panel.orderOut(nil)
    }
}
