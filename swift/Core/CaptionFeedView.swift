#if canImport(SwiftUI)
import Observation
import SwiftUI

/// What the caption feed shows: a header, the call's recent lines with their speaker labels (or a
/// placeholder before anyone talks, or a status note such as captions stopped at the cost cap), a
/// footnote, and the saving indicator's label while a transcript is being written. Every string is
/// the host's copy. The host updates it; the view follows. Content: memory only.
@MainActor
@Observable
public final class CaptionFeedModel {
    public struct Line: Equatable, Sendable {
        public var speaker: String
        public var text: String
        /// The user's own line (the mic stream).
        public var own: Bool

        public init(speaker: String, text: String, own: Bool) {
            self.speaker = speaker
            self.text = text
            self.own = own
        }
    }

    /// Above the lines, e.g. "Live captions"; nil = none.
    public var header: String?
    public var lines: [Line]
    /// A status shown in place of the lines (wins over `placeholder`).
    public var note: String?
    /// Shown while there are no lines and no note, e.g. before anyone talks.
    public var placeholder: String?
    /// Under the lines, e.g. kept in memory only, or saving a transcript.
    public var footnote: String?
    /// The saving indicator's label; nil = not saving.
    public var savingLabel: String?

    public init(header: String? = nil, lines: [Line] = [], note: String? = nil, placeholder: String? = nil,
                footnote: String? = nil, savingLabel: String? = nil) {
        self.header = header
        self.lines = lines
        self.note = note
        self.placeholder = placeholder
        self.footnote = footnote
        self.savingLabel = savingLabel
    }

    public var isEmpty: Bool {
        header == nil && lines.isEmpty && note == nil && placeholder == nil && footnote == nil && savingLabel == nil
    }

    public func clear() {
        header = nil
        lines = []
        note = nil
        placeholder = nil
        footnote = nil
        savingLabel = nil
    }
}

/// Live captions for a host to place inside the reminder card (the coach card hosts the `card`
/// layout, three caption rows, in its captions area through `CaptionFeedSlot`). It has no window, surface or
/// shadow of its own (the card supplies them) and takes every size, font and color from
/// `CardStyle` through `Theme.Captions`, following the environment's light or dark appearance.
/// Top to bottom: the saving indicator, the header, the lines (each one row: the speaker label,
/// then the newest words, older words cut at the start) or the note or placeholder, the footnote.
public struct CaptionFeedView: View {
    /// `full`: everything, for a host with room. `card`: for the coach card's captions area
    /// (`Theme.Captions.cardArea`): caption rows only (the card's status line carries the saving badge).
    public enum Layout: Sendable { case full, card }

    private let model: CaptionFeedModel
    private let layout: Layout
    @Environment(\.colorScheme) private var colorScheme

    public init(model: CaptionFeedModel, layout: Layout = .full) {
        self.model = model
        self.layout = layout
    }

    public var body: some View {
        let style = CardStyle.for(dark: colorScheme == .dark)
        switch layout {
        case .full: full(style)
        case .card: card(style)
        }
    }

    /// The card's captions area: up to `cardRows` rows of the card's caption height, newest lines
    /// last; a note or the placeholder when there are no lines. No header, indicator or footnote.
    @ViewBuilder private func card(_ style: CardStyle) -> some View {
        let c = Theme.Captions.self
        let rows = c.cardRows
        VStack(alignment: .leading, spacing: c.cardLineGap) {
            if model.lines.isEmpty, let status = model.note ?? model.placeholder {
                Text(status)
                    .font(c.cardTextFont.swiftUI)
                    .foregroundStyle(c.note.shapeStyle(style))
                    .lineLimit(1)
                    .frame(height: c.cardRowHeight, alignment: .leading)
            } else if !model.lines.isEmpty {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: c.speakerGap, verticalSpacing: c.cardLineGap) {
                    ForEach(Array(model.lines.suffix(rows).enumerated()), id: \.offset) { _, line in
                        GridRow {
                            Text(line.speaker)
                                .font(c.cardSpeakerFont.swiftUI)
                                .foregroundStyle((line.own ? c.ownSpeaker : c.speaker).shapeStyle(style))
                                .lineLimit(1)
                                .fixedSize()
                                .frame(height: c.cardRowHeight)
                            Text(line.text)
                                .font(c.cardTextFont.swiftUI)
                                .foregroundStyle(c.text.shapeStyle(style))
                                .lineLimit(1)
                                .truncationMode(.head)
                                .frame(maxWidth: .infinity, minHeight: c.cardRowHeight, maxHeight: c.cardRowHeight, alignment: .leading)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    @ViewBuilder private func full(_ style: CardStyle) -> some View {
        let c = Theme.Captions.self
        VStack(alignment: .leading, spacing: c.stackGap) {
            if let saving = model.savingLabel {
                CaptionSavingIndicator(label: saving)
            }
            if let header = model.header {
                Text(header)
                    .font(c.headerFont.swiftUI)
                    .foregroundStyle(c.header.shapeStyle(style))
                    .lineLimit(1)
                    .accessibilityAddTraits(.isHeader)
            }
            if model.lines.isEmpty, let status = model.note ?? model.placeholder {
                Text(status)
                    .font(c.noteFont.swiftUI)
                    .foregroundStyle(c.note.shapeStyle(style))
                    .lineLimit(1)
            } else if !model.lines.isEmpty {
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: c.speakerGap, verticalSpacing: c.lineGap) {
                    ForEach(Array(model.lines.enumerated()), id: \.offset) { _, line in
                        GridRow {
                            Text(line.speaker)
                                .font(c.speakerFont.swiftUI)
                                .foregroundStyle((line.own ? c.ownSpeaker : c.speaker).shapeStyle(style))
                                .lineLimit(1)
                                .fixedSize()
                            Text(line.text)
                                .font(c.textFont.swiftUI)
                                .foregroundStyle(c.text.shapeStyle(style))
                                .lineLimit(1)
                                .truncationMode(.head)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if let footnote = model.footnote {
                Text(footnote)
                    .font(c.footnoteFont.swiftUI)
                    .foregroundStyle(c.footnote.shapeStyle(style))
                    .lineLimit(1)
            }
        }
        .padding(.horizontal, c.inset)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The saving indicator: the card's secondary control (control height and radius, Ignore fill,
/// hairline) with a critical-red dot and its label.
public struct CaptionSavingIndicator: View {
    private let label: String
    @Environment(\.colorScheme) private var colorScheme

    public init(label: String) {
        self.label = label
    }

    public var body: some View {
        let c = Theme.Captions.self
        let style = CardStyle.for(dark: colorScheme == .dark)
        let shape = RoundedRectangle(cornerRadius: c.indicatorRadius, style: .continuous)
        HStack(spacing: c.indicatorGap) {
            Circle()
                .fill(c.dot(style: style).swiftUI)
                .frame(width: c.dotDiameter, height: c.dotDiameter)
            Text(label)
                .font(c.indicatorFont.swiftUI)
                .foregroundStyle(c.savingLabel.shapeStyle(style))
                .lineLimit(1)
                .fixedSize()
        }
        .padding(.horizontal, c.indicatorPadding)
        .frame(height: c.indicatorHeight)
        .background(shape.fill(c.indicatorFill(style: style).swiftUI))
        .overlay(shape.strokeBorder(c.hairline(style: style).swiftUI, lineWidth: c.hairlineWidth))
        .accessibilityElement(children: .combine)
    }
}

/// Renders the feed as it sits in a card: card width, card surface, the card's control-to-edge
/// spacing above and below (snapshot tests and the design packet).
@MainActor
public enum CaptionFeedSnapshot {
    public static func image(_ model: CaptionFeedModel, dark: Bool, scale: CGFloat) -> CGImage? {
        let style = CardStyle.for(dark: dark)
        let content = CaptionFeedView(model: model)
            .padding(.vertical, CardStyle.Spacing.controlBottom)
            .frame(width: Theme.Captions.cardWidth)
            .background(style.surface.swiftUI)
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        return renderer.cgImage
    }

    /// The `card` layout at the coach card's captions-area size, on the card surface.
    public static func cardImage(_ model: CaptionFeedModel, dark: Bool, scale: CGFloat) -> CGImage? {
        let style = CardStyle.for(dark: dark)
        let area = Theme.Captions.cardArea
        let content = CaptionFeedView(model: model, layout: .card)
            .frame(width: area.width, height: area.height)
            .background(style.surface.swiftUI)
            .environment(\.colorScheme, dark ? .dark : .light)
        let renderer = ImageRenderer(content: content)
        renderer.scale = scale
        return renderer.cgImage
    }
}

public extension Theme.FontSpec {
    /// The system font at this spec's size and weight.
    var swiftUI: Font {
        switch weight {
        case .regular: .system(size: size, weight: .regular)
        case .medium: .system(size: size, weight: .medium)
        case .semibold: .system(size: size, weight: .semibold)
        }
    }
}

public extension RGBA {
    var swiftUI: Color { Color(.sRGB, red: r, green: g, blue: b, opacity: a) }
}

public extension CardStyle.Text {
    /// Primary, secondary and tertiary are SwiftUI's hierarchical styles (they follow the
    /// environment's appearance); the rest are this style's color roles.
    func shapeStyle(_ style: CardStyle) -> AnyShapeStyle {
        switch self {
        case .primary: AnyShapeStyle(.primary)
        case .secondary: AnyShapeStyle(.secondary)
        case .tertiary: AnyShapeStyle(.tertiary)
        case .accent: AnyShapeStyle(style.accent.swiftUI)
        case .warning: AnyShapeStyle(style.warning.swiftUI)
        case .critical: AnyShapeStyle(style.critical.swiftUI)
        }
    }
}
#endif
