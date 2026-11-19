import XCTest
@testable import MeetingCardCore

/// The coach menu's footer: the version line (CFBundleShortVersionString and CFBundleVersion) and Quit.
/// Hostless tests can't load AppKit, so the pure pieces are tested directly and the App's wiring is read as text.
final class MenuFooterTests: XCTestCase {
    static let swiftDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    func read(_ path: String) throws -> String {
        try String(contentsOf: Self.swiftDir.appendingPathComponent(path), encoding: .utf8)
    }

    func testVersionShowsMarketingVersionThenBuild() {
        XCTAssertEqual(AppVersion.display(short: "2.0", build: "1"), "2.0 (1)")
        XCTAssertEqual(AppVersion.display(short: "2.1.3", build: "47"), "2.1.3 (47)")
    }

    func testVersionWithOnlyOnePart() {
        XCTAssertEqual(AppVersion.display(short: "2.0", build: nil), "2.0")
        XCTAssertEqual(AppVersion.display(short: "2.0", build: ""), "2.0")
        XCTAssertEqual(AppVersion.display(short: nil, build: "7"), "(7)")
    }

    /// Blank values, and build settings Xcode never substituted, are not versions.
    func testUnusableValuesAreMissing() {
        XCTAssertNil(AppVersion.display(short: nil, build: nil))
        XCTAssertNil(AppVersion.display(short: "  ", build: "\n"))
        XCTAssertNil(AppVersion.display(short: "$(MARKETING_VERSION)", build: "$(CURRENT_PROJECT_VERSION)"))
        XCTAssertEqual(AppVersion.display(short: " 2.0 ", build: "$(CURRENT_PROJECT_VERSION)"), "2.0")
    }

    func testMenuLineFromTheInfoDictionary() {
        let info: [String: Any] = ["CFBundleShortVersionString": "2.0", "CFBundleVersion": "1", "CFBundleName": "ignored"]
        XCTAssertEqual(AppVersion.menuLine(label: "Version", unknown: "unknown", infoDictionary: info), "Version 2.0 (1)")
        XCTAssertEqual(AppVersion.menuLine(label: "Version", unknown: "unknown", infoDictionary: [:]), "Version unknown")
        XCTAssertEqual(AppVersion.menuLine(label: "Version", unknown: "unknown", infoDictionary: nil), "Version unknown")
        XCTAssertEqual(AppVersion.menuLine(label: "Version", unknown: "unknown", infoDictionary: ["CFBundleVersion": 1]), "Version unknown",
                       "a non-string value is not a version")
    }

    /// Separator, the version line, then Quit last.
    func testFooterEndsWithQuitAndTheVersionLineAboveIt() throws {
        let entries = MenuFooter.entries
        XCTAssertEqual(entries, [.separator, .version, .quit])
        XCTAssertEqual(entries.last, .quit)
        let version = try XCTUnwrap(entries.firstIndex(of: .version))
        XCTAssertEqual(version, entries.index(before: try XCTUnwrap(entries.firstIndex(of: .quit))), "the version line is right above Quit")
        XCTAssertEqual(entries.first, .separator, "Quit sits after a separator")
        XCTAssertEqual(MenuFooter.quitKeyEquivalent, "q")
    }

    /// The controller adds the footer after everything else, the version line disabled and Quit on
    /// NSApplication.terminate with Cmd-Q, and the strings live in CoachCopy.
    func testControllerWiring() throws {
        let src = try read("App/CoachController.swift")
        XCTAssertTrue(src.contains("for entry in MenuFooter.entries { menu.addItem(footerItem(entry)) }"))
        XCTAssertTrue(src.contains("#selector(NSApplication.terminate(_:))"))
        XCTAssertTrue(src.contains("keyEquivalent: MenuFooter.quitKeyEquivalent"))
        XCTAssertTrue(src.contains("m.target = NSApplication.shared"))
        XCTAssertTrue(src.contains("infoDictionary: Bundle.main.infoDictionary"))
        let version = try XCTUnwrap(src.components(separatedBy: "case .version:").dropFirst().first?.components(separatedBy: "case .quit:").first)
        XCTAssertTrue(version.contains("m.isEnabled = false"), "the version line is disabled")
        XCTAssertTrue(version.contains("action: nil"))

        let copy = try read("App/CoachCopy.swift")
        for line in ["static let menuVersion = \"Version\"", "static let menuVersionUnknown = \"unknown\"", "static let menuQuit = \"Quit\""] {
            XCTAssertTrue(copy.contains(line), line)
        }
    }

    /// The version comes from the same two Info.plist keys the build fills in, and Quit adds no permission.
    func testInfoPlistKeysAndNoNewPermissions() throws {
        let plistData = Data(try read("App/Info.plist").utf8)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        XCTAssertNotNil(plist["CFBundleShortVersionString"])
        XCTAssertNotNil(plist["CFBundleVersion"])
        XCTAssertEqual(Set(plist.keys.filter { $0.hasSuffix("UsageDescription") }),
                       ["NSMicrophoneUsageDescription", "NSAudioCaptureUsageDescription", "NSAppleEventsUsageDescription"])
    }
}
