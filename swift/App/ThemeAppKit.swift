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

    static func ns(_ c: RGBA) -> NSColor {
        NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a))
    }

    static func cg(_ v: Double) -> CGFloat { CGFloat(v) }

    static var isDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
}
