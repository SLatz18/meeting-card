#if canImport(SwiftUI)
import Observation
import SwiftUI

/// What the caption feed shows: the call's recent lines with their speaker labels, an optional
/// status note (e.g. captions stopped at the cost cap) and the saving indicator's label while a
/// transcript is being written. The host updates it; the view follows. Content: memory only.
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

    public var lines: [Line]
    /// Shown in place of the lines when there are none.
    public var note: String?
    /// nil = not saving.
    public var savingLabel: String?

    public init(lines: [Line] = [], note: String? = nil, savingLabel: String? = nil) {
        self.lines = lines
        self.note = note
        self.savingLabel = savingLabel
    }

    public var isEmpty: Bool { lines.isEmpty && note == nil && savingLabel == nil }

    public func clear() {
        lines = []
        note = nil
        savingLabel = nil
    }
}

/// Live captions for a host to place inside the reminder card. It has no window, surface or
/// shadow of its own (the card supplies them) and takes every size, font and color from
/// `CardStyle` through `Theme.Captions`, following the environment's light or dark appearance.
/// Each line is one row: the speaker label, then the newest words (older words are cut at the
/// start). The saving indicator, when set, sits above the lines.
public struct CaptionFeedView: View {
    private let model: CaptionFeedModel
    @Environment(\.colorScheme) private var colorScheme

    public init(model: CaptionFeedModel) {
        self.model = model
    }

    public var body: some View {
        let c = Theme.Captions.self
        let style = CardStyle.for(dark: colorScheme == .dark)
        VStack(alignment: .leading, spacing: c.stackGap) {
            if let saving = model.savingLabel {
                CaptionSavingIndicator(label: saving)
            }
            if model.lines.isEmpty, let note = model.note {
                Text(note)
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
