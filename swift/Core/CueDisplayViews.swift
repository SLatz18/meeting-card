#if canImport(SwiftUI) && (DEBUG || MEETINGCARD_TEST_ID)
import SwiftUI

// The coaching-display prototype's surfaces (test builds only, like CueDisplay.swift): the coach card
// and pill as they would look with each option, drawn in SwiftUI from the coach card's tokens and
// frames (Theme.CoachCard, Theme.CoachPill) and the real caption feed. Not wired to the live card.

/// The coach card or pill at one moment of a timeline, with one display option.
public struct CueDisplaySurface: View {
    public enum Mode: String, CaseIterable, Sendable { case card, pill }

    let option: CueDisplayOption
    let timeline: CueTimeline
    let t: TimeInterval
    let mode: Mode
    let hover: Bool
    @Environment(\.colorScheme) private var colorScheme

    public init(option: CueDisplayOption, timeline: CueTimeline, t: TimeInterval, mode: Mode, hover: Bool = false) {
        self.option = option
        self.timeline = timeline
        self.t = t
        self.mode = mode
        self.hover = hover
    }

    public var body: some View {
        let display = CueDisplayPacer.frame(at: t, events: timeline.events)
        let style = CardStyle.for(dark: colorScheme == .dark)
        switch mode {
        case .card: CueCardMock(option: option, timeline: timeline, display: display, hover: hover, style: style)
        case .pill: CuePillMock(option: option, display: display, hover: hover, style: style)
        }
    }
}

// MARK: shared pieces

extension CoachNudge.Tone {
    func color(_ style: CardStyle) -> Color { CoachNudgeColors.tone(self, dark: style.dark).swiftUI }
}

/// The nudge band's look: the tone's tint over the surface, its outline and its leading bar, each
/// scaled by `strength` (1 = the shipped nudge).
struct CueBand: View {
    let tone: CoachNudge.Tone?
    let strength: Double
    let tinted: Bool
    let radius: Double
    let style: CardStyle

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        let k = CardStyle.Coach.self
        if let tone {
            let c = tone.color(style)
            ZStack(alignment: .leading) {
                shape.fill(c.opacity(tinted ? k.nudgeTint(dark: style.dark, increasedContrast: false) * strength : 0))
                shape.strokeBorder(c.opacity(tinted ? k.nudgeEdgeAlpha(dark: style.dark, increasedContrast: false) * strength : 0),
                                   lineWidth: k.nudgeBorder)
                Rectangle()
                    .fill(c.opacity(k.nudgeEdgeAlpha(dark: style.dark, increasedContrast: false) * strength))
                    .frame(width: k.nudgeBar)
            }
            .clipShape(shape)
        }
    }
}

/// An SF Symbol scaled to fit a square, like the card's image views (wide glyphs never overflow).
struct CueGlyph: View {
    let symbol: String
    let size: Double
    let weight: Theme.FontSpec.Weight
    let style: AnyShapeStyle

    var body: some View {
        Image(systemName: symbol)
            .resizable()
            .scaledToFit()
            .fontWeight(weight.swiftUI)
            .foregroundStyle(style)
            .frame(width: size, height: size)
    }
}

extension Theme.FontSpec.Weight {
    var swiftUI: Font.Weight {
        switch self {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        }
    }
}

struct CueIconButton: View {
    let symbol: String
    let size: Double
    let radius: Double
    let glyph: Theme.FontSpec
    let label: String
    let style: CardStyle

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        Image(systemName: symbol)
            .font(glyph.swiftUI)
            .foregroundStyle(CardStyle.Text.primary.shapeStyle(style))
            .frame(width: size, height: size)
            .background(shape.fill(style.controlFill(.normal).swiftUI))
            .overlay(shape.strokeBorder(style.hairline.swiftUI, lineWidth: CardStyle.Stroke.hairline))
            .accessibilityLabel(label)
    }
}

extension View {
    /// Places a view at a frame given in the card's bottom-left coordinates, inside a container
    /// `height` tall aligned top-leading.
    func placed(_ f: Theme.CoachCard.Frame, height: Double) -> some View {
        frame(width: f.width, height: f.height).offset(x: f.x, y: height - f.maxY)
    }
}

// MARK: the card

struct CueCardMock: View {
    let option: CueDisplayOption
    let timeline: CueTimeline
    let display: CueDisplayFrame
    let hover: Bool
    let style: CardStyle

    var body: some View {
        let k = Theme.CoachCard.self
        let h = k.height
        ZStack(alignment: .topLeading) {
            statusRow.placed(k.statusRow, height: h)
            CueIconButton(symbol: Theme.CoachCard.Symbols.minimize, size: k.iconButton, radius: k.iconButtonRadius, glyph: k.iconGlyph,
                          label: CoachCardCopy.A11y.minimize, style: style)
                .placed(k.minimizeButton, height: h)
            captions.placed(k.captions, height: h)
            CueIconButton(symbol: Theme.CoachCard.Symbols.coachHearing, size: k.iconButton, radius: k.iconButtonRadius, glyph: k.iconGlyph,
                          label: CoachCardCopy.Tooltip.muteMic, style: style)
                .placed(k.micMuteButton, height: h)
            CueIconButton(symbol: Theme.CoachCard.Symbols.pause, size: k.iconButton, radius: k.iconButtonRadius, glyph: k.iconGlyph,
                          label: CoachCardCopy.A11y.pause, style: style)
                .placed(k.pauseButton(showsMute: false), height: h)
            stopButton
        }
        .frame(width: k.width, height: h, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: k.radius, style: .continuous).fill(style.surface.swiftUI))
        .accessibilityElement(children: .contain)
    }

    private var stopButton: some View {
        let k = Theme.CoachCard.self
        let shape = RoundedRectangle(cornerRadius: CardStyle.Radius.control, style: .continuous)
        return Text(CoachCardCopy.Button.stop)
            .font(k.buttonFont.swiftUI)
            .foregroundStyle(CardStyle.Text.primary.shapeStyle(style))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, k.textButtonPadding)
            .frame(height: k.rowHeight)
            .background(shape.fill(style.controlFill(.normal).swiftUI))
            .overlay(shape.strokeBorder(style.hairline.swiftUI, lineWidth: CardStyle.Stroke.hairline))
            .frame(width: k.width - k.leading - k.trailing, height: k.rowHeight, alignment: .trailing)
            .offset(x: k.leading, y: k.height - k.vertical - k.rowHeight)
            .accessibilityLabel(CoachCardCopy.A11y.stop)
    }

    /// The status row. Rotating line and caption-anchored: the shipped band (tint, outline, bar,
    /// words) for the hold. Glyph state: the status line stays; the glyph turns into the cue's in
    /// its tone for the hold, then in the held role while it lingers, with the bar fading; hover
    /// shows the words and how long ago.
    @ViewBuilder private var statusRow: some View {
        let k = Theme.CoachCard.self
        let d = Theme.CueDisplay.self
        let status = CueDisplayCopy.statusListening
        switch option {
        case .rotatingLine, .captionAnchored:
            let nudge = display.line?.nudge
            row(band: CueBand(tone: nudge?.tone, strength: 1, tinted: true, radius: k.bandRadius, style: style),
                glyph: Theme.CoachCard.Symbols.status,
                glyphStyle: nudge.map { _ in k.nudgeText.shapeStyle(style) } ?? AnyShapeStyle(Theme.Coach.live(style: style).swiftUI),
                text: nudge?.words ?? status, font: nudge == nil ? k.statusFont : k.nudgeFont, detail: nil,
                label: nudge?.words ?? status)
        case .glyphState:
            let cue = display.lingering
            let inHold = display.line != nil
            let glyphStyle: AnyShapeStyle = cue.map { c in inHold ? AnyShapeStyle(c.nudge.tone.color(style)) : d.lingerText.shapeStyle(style) }
                ?? AnyShapeStyle(Theme.Coach.live(style: style).swiftUI)
            let age = cue.map { CueDisplayCopy.age($0.age(at: display.t)) }
            row(band: CueBand(tone: cue?.nudge.tone, strength: display.strength, tinted: hover && cue != nil, radius: k.bandRadius, style: style),
                glyph: cue.map { d.glyph($0.kind) } ?? Theme.CoachCard.Symbols.status, glyphStyle: glyphStyle,
                text: hover ? (cue?.nudge.words ?? status) : status, font: hover && cue != nil ? k.nudgeFont : k.statusFont,
                detail: hover ? age : nil,
                label: cue.map { CueDisplayCopy.glyphLabel(status: status, words: $0.nudge.words, age: age ?? "") } ?? status)
        }
    }

    private func row(band: CueBand, glyph: String, glyphStyle: AnyShapeStyle, text: String, font: Theme.FontSpec, detail: String?,
                     label: String) -> some View {
        let k = Theme.CoachCard.self
        return ZStack(alignment: .leading) {
            band
            HStack(spacing: k.glyphGap) {
                CueGlyph(symbol: glyph, size: k.glyphSize, weight: k.iconGlyph.weight, style: glyphStyle)
                Text(text)
                    .font(font.swiftUI)
                    .foregroundStyle(k.statusText.shapeStyle(style))
                    .lineLimit(1)
                Spacer(minLength: CardStyle.Spacing.control)
                if let detail {
                    Text(detail)
                        .font(Theme.CueDisplay.ageFont.swiftUI)
                        .foregroundStyle(Theme.CueDisplay.ageText.shapeStyle(style))
                        .lineLimit(1)
                        .fixedSize()
                }
            }
            .padding(.leading, k.bandInset)
            .padding(.trailing, CardStyle.Spacing.control)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
    }

    /// The captions area: the real caption feed, or (caption-anchored) the same rows with the
    /// lingering cue's mark on the row that triggered it.
    @ViewBuilder private var captions: some View {
        let rows = timeline.visibleCaptions(at: display.t)
        let lines = rows.map { CaptionFeedModel.Line(speaker: $0.line.own ? CueDisplayCopy.you : CueDisplayCopy.them, text: $0.text, own: $0.line.own) }
        switch option {
        case .rotatingLine, .glyphState:
            CaptionFeedView(model: CaptionFeedModel(lines: lines), layout: .card)
        case .captionAnchored:
            CueAnchoredCaptions(lines: lines, mark: CueDisplayPacer.anchorRow(display, in: timeline).flatMap { row in
                display.lingering.map { (row: row, cue: $0, strength: display.strength) }
            }, style: style)
        }
    }
}

/// The real caption feed (`CaptionFeedView`'s card layout), with the lingering cue's mark behind
/// the row that triggered it: the nudge tint across the row and the cue's glyph in the gutter to
/// its left. The mark fades with the linger; without one the rows are the plain feed's.
struct CueAnchoredCaptions: View {
    let lines: [CaptionFeedModel.Line]
    let mark: (row: Int, cue: ShownCue, strength: Double)?
    let style: CardStyle

    var body: some View {
        let c = Theme.Captions.self
        let d = Theme.CueDisplay.self
        let k = CardStyle.Coach.self
        CaptionFeedView(model: CaptionFeedModel(lines: lines), layout: .card)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(alignment: .topLeading) {
                if let m = mark, m.row < lines.count {
                    let tone = m.cue.nudge.tone.color(style)
                    HStack(spacing: 0) {
                        CueGlyph(symbol: d.glyph(m.cue.kind), size: d.markGlyphSize, weight: CardStyle.Typography.button.weight,
                                 style: AnyShapeStyle(tone.opacity(max(m.strength, k.nudgeEdgeAlpha(dark: style.dark, increasedContrast: false)))))
                            .frame(width: d.markGutter)
                        Spacer(minLength: 0)
                    }
                    .frame(width: c.cardArea.width + d.markGutter, height: c.cardRowHeight)
                    .background(RoundedRectangle(cornerRadius: d.markRadius, style: .continuous)
                        .fill(tone.opacity(k.nudgeTint(dark: style.dark, increasedContrast: false) * m.strength)))
                    .offset(x: -d.markGutter, y: Double(m.row) * c.cardRowHeight)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(CueDisplayCopy.anchoredRowLabel(speaker: lines[m.row].speaker, text: lines[m.row].text,
                                                                         words: m.cue.nudge.words))
                }
            }
    }
}

// MARK: the pill

struct CuePillMock: View {
    let option: CueDisplayOption
    let display: CueDisplayFrame
    let hover: Bool
    let style: CardStyle

    var body: some View {
        let p = Theme.CoachPill.self
        let d = Theme.CueDisplay.self
        let shape = RoundedRectangle(cornerRadius: p.radius, style: .continuous)
        // Rotating line and caption-anchored (no captions in the pill): the shipped pill, tinted and
        // widened for the words. Glyph state: never widens; the glyph carries the cue.
        let words = option == .glyphState ? nil : display.line?.nudge
        let cue = option == .glyphState ? display.lingering : nil
        let tone = words?.tone ?? cue?.nudge.tone
        let inHold = display.line != nil
        let glyph = cue.map { d.glyph($0.kind) } ?? Theme.CoachCard.Symbols.status
        let glyphStyle: AnyShapeStyle = cue.map { c in inHold ? AnyShapeStyle(c.nudge.tone.color(style)) : d.lingerText.shapeStyle(style) }
            ?? (words != nil ? Theme.CoachCard.nudgeText.shapeStyle(style) : AnyShapeStyle(Theme.Coach.live(style: style).swiftUI))
        let age = cue.map { CueDisplayCopy.age($0.age(at: display.t)) }
        VStack(spacing: d.tooltipPadding) {
            ZStack(alignment: .top) {
                CueBand(tone: tone, strength: option == .glyphState ? display.strength : 1, tinted: words != nil, radius: p.radius, style: style)
                Capsule()
                    .fill(Theme.CoachPill.grabberColor.shapeStyle(style))
                    .frame(width: p.grabber.width, height: p.grabber.height)
                    .padding(.top, p.grabberTop)
                HStack(spacing: p.glyphGap) {
                    CueGlyph(symbol: glyph, size: p.glyphSize, weight: Theme.CoachCard.iconGlyph.weight, style: glyphStyle)
                    if let words {
                        Text(words.words)
                            .font(p.wordsFont.swiftUI)
                            .foregroundStyle(Theme.CoachCard.nudgeText.shapeStyle(style))
                            .lineLimit(1)
                            .fixedSize()
                            .padding(.horizontal, p.wordsInset)
                    }
                    Spacer(minLength: CardStyle.Spacing.control)
                    HStack(spacing: p.buttonGap) {
                        CueIconButton(symbol: Theme.CoachCard.Symbols.coachHearing, size: p.button, radius: p.buttonRadius, glyph: p.buttonGlyph,
                                      label: CoachCardCopy.Tooltip.muteMic, style: style)
                        CueIconButton(symbol: Theme.CoachCard.Symbols.pause, size: p.button, radius: p.buttonRadius, glyph: p.buttonGlyph,
                                      label: CoachCardCopy.A11y.pause, style: style)
                        CueIconButton(symbol: Theme.CoachCard.Symbols.stop, size: p.button, radius: p.buttonRadius, glyph: p.buttonGlyph,
                                      label: CoachCardCopy.A11y.stop, style: style)
                    }
                }
                .padding(.leading, p.glyphX)
                .padding(.trailing, p.padding)
                .frame(maxHeight: .infinity)
                .padding(.top, p.grabberTop + p.grabber.height)
            }
            .frame(minWidth: p.width, maxWidth: p.maxWidth)
            .fixedSize(horizontal: true, vertical: false)
            .frame(height: p.height)
            .background(shape.fill(style.surface.swiftUI))
            .clipShape(shape)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(words.map { CueDisplayCopy.nudgeLabel(status: CueDisplayCopy.statusListening, words: $0.words) }
                ?? cue.map { CueDisplayCopy.glyphLabel(status: CueDisplayCopy.statusListening, words: $0.nudge.words, age: age ?? "") }
                ?? CueDisplayCopy.statusListening)
            if hover, let cue, let age {
                Text(CueDisplayCopy.tooltip(words: cue.nudge.words, age: age))
                    .font(d.tooltipFont.swiftUI)
                    .foregroundStyle(CardStyle.Text.primary.shapeStyle(style))
                    .lineLimit(1)
                    .fixedSize()
                    .padding(d.tooltipPadding)
                    .background(RoundedRectangle(cornerRadius: d.tooltipRadius, style: .continuous).fill(style.surface.swiftUI))
                    .overlay(RoundedRectangle(cornerRadius: d.tooltipRadius, style: .continuous)
                        .strokeBorder(style.hairline.swiftUI, lineWidth: CardStyle.Stroke.hairline))
            }
        }
    }
}

// MARK: snapshots

/// Renders the prototype for the snapshot tests and the doc: one surface, a strip of moments, or
/// the glyph vocabulary, each on the backdrop.
@MainActor
public enum CueDisplaySnapshot {
    public static func image(_ option: CueDisplayOption, _ timeline: CueTimeline, at t: TimeInterval, mode: CueDisplaySurface.Mode,
                             hover: Bool = false, dark: Bool, scale: CGFloat) -> CGImage? {
        render(CueDisplaySurface(option: option, timeline: timeline, t: t, mode: mode, hover: hover), dark: dark, scale: scale)
    }

    /// The surface at each moment, side by side, each under its time.
    public static func strip(_ option: CueDisplayOption, _ timeline: CueTimeline, moments: [TimeInterval], mode: CueDisplaySurface.Mode,
                             dark: Bool, scale: CGFloat) -> CGImage? {
        let style = CardStyle.for(dark: dark)
        let d = Theme.CueDisplay.self
        let content = HStack(alignment: .top, spacing: d.stripGap) {
            ForEach(Array(moments.enumerated()), id: \.offset) { _, t in
                VStack(alignment: .leading, spacing: d.stripGap / 2) {
                    Text(CueDisplayCopy.stripTime(t))
                        .font(d.stripLabelFont.swiftUI)
                        .foregroundStyle(d.stripLabelText.shapeStyle(style))
                    CueDisplaySurface(option: option, timeline: timeline, t: t, mode: mode)
                }
            }
        }
        return render(content, dark: dark, scale: scale)
    }

    /// Each cue type's glyph in its tone beside its words (the glyph-state vocabulary).
    public static func glyphs(dark: Bool, scale: CGFloat) -> CGImage? {
        let style = CardStyle.for(dark: dark)
        let k = Theme.CoachCard.self
        let content = VStack(alignment: .leading, spacing: CardStyle.Spacing.control) {
            ForEach(CoachNudge.Kind.priorityOrder, id: \.self) { kind in
                let n = CoachNudge(kind: kind, tone: kind.tone)
                HStack(spacing: k.glyphGap) {
                    CueGlyph(symbol: Theme.CueDisplay.glyph(kind), size: k.glyphSize, weight: k.iconGlyph.weight,
                             style: AnyShapeStyle(n.tone.color(style)))
                    Text(n.words)
                        .font(k.nudgeFont.swiftUI)
                        .foregroundStyle(k.nudgeText.shapeStyle(style))
                }
            }
        }
        .padding(CardStyle.Spacing.leading)
        .background(RoundedRectangle(cornerRadius: k.radius, style: .continuous).fill(style.surface.swiftUI))
        return render(content, dark: dark, scale: scale)
    }

    private static func render(_ view: some View, dark: Bool, scale: CGFloat) -> CGImage? {
        let style = CardStyle.for(dark: dark)
        let content = view
            .padding(Theme.CueDisplay.snapshotPadding)
            .background(Theme.CueDisplay.backdrop(style: style).swiftUI)
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        return renderer.cgImage
    }
}
#endif
