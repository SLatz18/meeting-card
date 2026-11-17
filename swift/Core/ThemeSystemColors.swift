#if canImport(AppKit)
import AppKit

/// The card style's system colors as live AppKit colors.
public extension CardStyle {
    static func nsColor(_ c: SystemColor) -> NSColor {
        switch c {
        case .red: .systemRed
        case .orange: .systemOrange
        }
    }

    /// A dynamic color: `c` resolved in the drawing appearance (light or dark, and the Increase
    /// Contrast variant when that is on), then passed through `transform(resolved, dark)`.
    static func dynamic(_ c: SystemColor, _ transform: @escaping (RGBA, Bool) -> RGBA) -> NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            var base = srgb(c, dark: dark)
            appearance.performAsCurrentDrawingAppearance {
                if let r = nsColor(c).usingColorSpace(.sRGB) {
                    base = RGBA(Double(r.redComponent), Double(r.greenComponent), Double(r.blueComponent))
                }
            }
            let t = transform(base, dark)
            return NSColor(srgbRed: CGFloat(t.r), green: CGFloat(t.g), blue: CGFloat(t.b), alpha: CGFloat(t.a))
        }
    }
}
#endif
