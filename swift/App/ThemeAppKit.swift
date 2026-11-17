import AppKit
import MeetingCardCore

/// AppKit spellings of the shared Theme (cards and coach both draw through these).
extension Theme {
    static func font(_ s: FontSpec) -> NSFont {
        switch s.weight {
        case .regular: .systemFont(ofSize: CGFloat(s.size))
        case .medium: .systemFont(ofSize: CGFloat(s.size), weight: .medium)
        case .semibold: .systemFont(ofSize: CGFloat(s.size), weight: .semibold)
        }
    }

    static func weight(_ s: FontSpec) -> NSFont.Weight {
        switch s.weight {
        case .regular: .regular
        case .medium: .medium
        case .semibold: .semibold
        }
    }

    /// An SF Symbol at a font spec's size and weight (symbols match the text beside them).
    static func symbol(_ name: String, _ s: FontSpec, label: String? = nil) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(.init(pointSize: CGFloat(s.size), weight: weight(s)))
    }

    static func ns(_ c: RGBA) -> NSColor {
        NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a))
    }

    static func cg(_ v: Double) -> CGFloat { CGFloat(v) }

    /// A `CardStyle` text role as an AppKit color (semantic label colors track the system).
    static func text(_ t: CardStyle.Text, _ style: CardStyle) -> NSColor {
        switch t {
        case .primary: .labelColor
        case .secondary: .secondaryLabelColor
        case .tertiary: .tertiaryLabelColor
        case .accent: ns(style.accent)
        case .warning: ns(style.warning)
        case .critical: system(CardStyle.criticalColor)
        }
    }

    static func system(_ c: CardStyle.SystemColor) -> NSColor {
        switch c {
        case .red: .systemRed
        case .orange: .systemOrange
        }
    }

    /// A dynamic color: `c` resolved in the drawing appearance (dark, Increase Contrast) and then
    /// passed through `transform(resolved, dark)`.
    static func dynamic(_ c: CardStyle.SystemColor, _ transform: @escaping (RGBA, Bool) -> RGBA) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            var base = CardStyle.srgb(c, dark: dark)
            appearance.performAsCurrentDrawingAppearance {
                if let r = system(c).usingColorSpace(.sRGB) {
                    base = RGBA(Double(r.redComponent), Double(r.greenComponent), Double(r.blueComponent))
                }
            }
            return ns(transform(base, dark))
        }
    }

    static var isDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}
