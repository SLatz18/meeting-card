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

    func glow(_ name: NSAppearance.Name) throws -> (rose: RGBA, amber: RGBA) {
        let g = Theme.Glow.self
        let dark = name == .darkAqua || name == .accessibilityHighContrastDarkAqua
        let red = try XCTUnwrap(resolved(.systemRed, name), "\(name)")
        let orange = try XCTUnwrap(resolved(.systemOrange, name), "\(name)")
        let rose = g.rose(base: red, dark: dark), amber = g.amber(base: orange, dark: dark)
        XCTAssertGreaterThan(rose.r, rose.g + 0.15, "\(name): reads as rose")
        XCTAssertGreaterThan(amber.r, amber.b + 0.25, "\(name): reads as amber")
        return (rose, amber)
    }

    func testRoseAndAmberFollowDarkMode() throws {
        let light = try glow(.aqua), dark = try glow(.darkAqua)
        XCTAssertNotEqual(light.rose, dark.rose)
        XCTAssertNotEqual(light.amber, dark.amber)
    }

    func testRoseAndAmberFollowIncreaseContrast() throws {
        guard NSAppearance(named: .accessibilityHighContrastAqua) != nil else {
            throw XCTSkip("this macOS can't construct the high-contrast appearances")
        }
        for (std, hc) in [(NSAppearance.Name.aqua, NSAppearance.Name.accessibilityHighContrastAqua),
                          (.darkAqua, .accessibilityHighContrastDarkAqua)] {
            let a = try glow(std), b = try glow(hc)
            XCTAssertNotEqual(a.rose, b.rose, "rose: \(hc)")
            XCTAssertNotEqual(a.amber, b.amber, "amber: \(hc)")
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
        XCTAssertTrue(controller.contains("Theme.dynamic(g.roseSource)"))
        XCTAssertTrue(controller.contains("Theme.dynamic(g.amberSource)"))
        XCTAssertTrue(controller.contains("increasedContrastPeakOpacity: g.increasedContrastPeakOpacity"))
        let kit = try String(contentsOf: app.deletingLastPathComponent()
            .appendingPathComponent("Packages/ListenMoreKit/Sources/ListenMoreMac/GlowOverlay.swift"), encoding: .utf8)
        XCTAssertTrue(kit.contains("accessibilityDisplayShouldIncreaseContrast"))
        XCTAssertEqual(Theme.Glow.roseSource, .red)
        XCTAssertEqual(Theme.Glow.amberSource, .orange)
    }
}
#endif
