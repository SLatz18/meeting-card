#if canImport(AppKit)
import AppKit
import XCTest
@testable import MeetingCardCore

/// The glow's rose and amber come from the live semantic system colors (systemRed / systemOrange),
/// so they follow dark mode and Increase Contrast; Increase Contrast also raises the peak.
final class GlowContrastTests: XCTestCase {
    func resolved(_ c: NSColor, _ name: NSAppearance.Name) -> RGBA? {
        var out: RGBA?
        NSAppearance(named: name)?.performAsCurrentDrawingAppearance {
            if let s = c.usingColorSpace(.sRGB) {
                out = RGBA(Double(s.redComponent), Double(s.greenComponent), Double(s.blueComponent))
            }
        }
        return out
    }

    /// The glow colors as the app builds them (`CoachController.glowStyle`).
    let rose = CardStyle.dynamic(Theme.Glow.roseSource) { Theme.Glow.rose(base: $0, dark: $1) }
    let amber = CardStyle.dynamic(Theme.Glow.amberSource) { Theme.Glow.amber(base: $0, dark: $1) }

    func near(_ a: RGBA?, _ b: RGBA?, _ msg: String) {
        guard let a, let b else { return XCTFail("unresolved: \(msg)") }
        XCTAssertEqual(a.r, b.r, accuracy: 0.002, msg); XCTAssertEqual(a.g, b.g, accuracy: 0.002, msg)
        XCTAssertEqual(a.b, b.b, accuracy: 0.002, msg)
    }

    /// In every appearance (including the high-contrast ones) the glow is the muted semantic color
    /// resolved in that appearance, so macOS's Increase Contrast variants flow through. CI can't
    /// turn Increase Contrast on, so this checks the tracking, not a particular contrast value.
    func testGlowTracksTheSemanticColorsInEveryAppearance() {
        let names: [(NSAppearance.Name, Bool)] = [(.aqua, false), (.darkAqua, true),
                                                  (.accessibilityHighContrastAqua, false),
                                                  (.accessibilityHighContrastDarkAqua, true)]
        for (name, dark) in names {
            guard NSAppearance(named: name) != nil else { continue }
            near(resolved(rose, name), resolved(.systemRed, name).map { Theme.Glow.rose(base: $0, dark: dark) }, "rose \(name)")
            near(resolved(amber, name), resolved(.systemOrange, name).map { Theme.Glow.amber(base: $0, dark: dark) }, "amber \(name)")
        }
    }

    func testGlowFollowsDarkMode() {
        XCTAssertNotEqual(resolved(rose, .aqua), resolved(rose, .darkAqua))
        XCTAssertNotEqual(resolved(amber, .aqua), resolved(amber, .darkAqua))
        for name in [NSAppearance.Name.aqua, .darkAqua] {
            guard let r = resolved(rose, name), let a = resolved(amber, name) else { return XCTFail("\(name)") }
            XCTAssertGreaterThan(r.r, r.g + 0.15, "\(name): reads as rose")
            XCTAssertGreaterThan(a.r, a.b + 0.25, "\(name): reads as amber")
        }
    }

    func testStandardContrastMatchesTheTokenValues() {
        for (name, dark) in [(NSAppearance.Name.aqua, false), (.darkAqua, true)] {
            XCTAssertEqual(resolved(.systemRed, name).map { Theme.Glow.rose(base: $0, dark: dark) }?.r ?? 0,
                           Theme.Glow.rose(dark: dark).r, accuracy: 0.02)
            XCTAssertEqual(resolved(.systemOrange, name).map { Theme.Glow.amber(base: $0, dark: dark) }?.g ?? 0,
                           Theme.Glow.amber(dark: dark).g, accuracy: 0.02)
        }
    }

    func testIncreaseContrastPeakAndUnchangedTiming() {
        XCTAssertEqual(Theme.Glow.peakOpacity, 0.45)
        XCTAssertEqual(Theme.Glow.increasedContrastPeakOpacity, 0.60)
        XCTAssertEqual(Theme.Glow.rise, 0.32)
        XCTAssertEqual(Theme.Glow.hold, 0.8)
        XCTAssertEqual(Theme.Glow.fade, 1.88)
    }

    /// The app draws the glow from these dynamic colors and passes the Increase Contrast peak.
    func testAppWiresTheDynamicColorsAndPeak() throws {
        let app = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App")
        let controller = try String(contentsOf: app.appendingPathComponent("CoachController.swift"), encoding: .utf8)
        XCTAssertTrue(controller.contains("CardStyle.dynamic(g.roseSource) { g.rose(base: $0, dark: $1) }"))
        XCTAssertTrue(controller.contains("CardStyle.dynamic(g.amberSource) { g.amber(base: $0, dark: $1) }"))
        XCTAssertTrue(controller.contains("increasedContrastPeakOpacity: g.increasedContrastPeakOpacity"))
        let kit = try String(contentsOf: app.deletingLastPathComponent()
            .appendingPathComponent("Packages/ListenMoreKit/Sources/ListenMoreMac/GlowOverlay.swift"), encoding: .utf8)
        XCTAssertTrue(kit.contains("accessibilityDisplayShouldIncreaseContrast"))
        XCTAssertEqual(Theme.Glow.roseSource, .red)
        XCTAssertEqual(Theme.Glow.amberSource, .orange)
    }
}
#endif
