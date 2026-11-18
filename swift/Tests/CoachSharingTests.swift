import XCTest
@testable import MeetingCardCore

/// "Show Coach in Screenshots": off by default; when on, the coach card and its captions are readable by
/// screenshots and screen recordings; turning it on or off reaches windows already open.
final class CoachSharingTests: XCTestCase {
    final class FakeWindow: SharingWindow {
        var sharing: CoachSurface.Sharing = .excluded
    }

    final class CountingWindow: SharingWindow {
        var sets = 0
        var value: CoachSurface.Sharing = .excluded
        var sharing: CoachSurface.Sharing {
            get { value }
            set { value = newValue; sets += 1 }
        }
    }

    func testOffByDefault() {
        XCTAssertFalse(CoachSurface.showInScreenshotsDefault)
        XCTAssertEqual(SharingRegistry().sharing, .excluded)
    }

    /// The decision: the setting maps to what the window shows captures, for every coach surface.
    func testSettingMapsToSharing() {
        for surface in CoachSurface.allCases {
            XCTAssertEqual(surface.sharing(showInScreenshots: false), .excluded, "\(surface)")
            XCTAssertEqual(surface.sharing(showInScreenshots: true), .shared, "\(surface)")
        }
    }

    func testReminderCardIsAlwaysSharedExceptWhileItCarriesTheChip() {
        XCTAssertEqual(SharingRegistry.reminderCardSharing(chipShown: false, showInScreenshots: false), .shared)
        XCTAssertEqual(SharingRegistry.reminderCardSharing(chipShown: false, showInScreenshots: true), .shared)
        XCTAssertEqual(SharingRegistry.reminderCardSharing(chipShown: true, showInScreenshots: false), .excluded)
        XCTAssertEqual(SharingRegistry.reminderCardSharing(chipShown: true, showInScreenshots: true), .shared)
    }

    func testRegisteringAppliesTheCurrentSetting() {
        let off = SharingRegistry(showInScreenshots: false)
        let a = FakeWindow()
        a.sharing = .shared
        off.register(a)
        XCTAssertEqual(a.sharing, .excluded, "a window that joins while the setting is off is left out")
        let on = SharingRegistry(showInScreenshots: true)
        let b = FakeWindow()
        on.register(b)
        XCTAssertEqual(b.sharing, .shared)
    }

    /// Toggling reaches every window that is already open, in both directions, without a relaunch.
    func testTogglingUpdatesExistingWindows() {
        let registry = SharingRegistry()
        let card = CountingWindow(), other = CountingWindow()
        registry.register(card)
        registry.register(other)
        XCTAssertEqual([card.value, other.value], [.excluded, .excluded])
        XCTAssertEqual(registry.set(showInScreenshots: true), 2)
        XCTAssertEqual([card.value, other.value], [.shared, .shared])
        XCTAssertTrue(registry.showInScreenshots)
        XCTAssertEqual(registry.set(showInScreenshots: false), 2)
        XCTAssertEqual([card.value, other.value], [.excluded, .excluded])
        XCTAssertEqual(card.sets, 3, "once when it joined, once for each toggle")
    }

    func testWindowsClosedAndReleasedAreDropped() {
        let registry = SharingRegistry()
        var gone: FakeWindow? = FakeWindow()
        let kept = FakeWindow()
        registry.register(gone!)
        registry.register(kept)
        gone = nil
        XCTAssertEqual(registry.set(showInScreenshots: true), 1)
        XCTAssertEqual(kept.sharing, .shared)
    }

    // MARK: wiring (hostless tests read the App's sources)

    static let swiftDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    func read(_ path: String) throws -> String {
        try String(contentsOf: Self.swiftDir.appendingPathComponent(path), encoding: .utf8)
    }

    func testSharingMapsToTheWindowServerSettings() throws {
        let map = try read("App/CoachSharingAppKit.swift")
        XCTAssertTrue(map.contains("case .excluded: .none"))
        XCTAssertTrue(map.contains("case .shared: .readOnly"))
        XCTAssertTrue(map.contains("extension CoachCardPanel: SharingWindow"))
    }

    /// The setting is one UserDefaults key, off unless set; the toggle lives in Settings, not the menu, and applies live.
    func testSettingsToggleWiring() throws {
        let controller = try read("App/CoachController.swift")
        XCTAssertTrue(controller.contains("static let showInScreenshots = \"coach.showInScreenshots\""))
        XCTAssertTrue(controller.contains("var showInScreenshots: Bool { defaults.bool(forKey: Keys.showInScreenshots) }"), "bool(forKey:) is false until set")
        let set = try XCTUnwrap(controller.components(separatedBy: "    func setShowInScreenshots(_ on: Bool) {").dropFirst().first?.components(separatedBy: "\n    }\n").first)
        XCTAssertTrue(set.contains("defaults.set(on, forKey: Keys.showInScreenshots)"))
        XCTAssertTrue(set.contains("sharingRegistry.set(showInScreenshots: on)"), "open coach windows follow at once")
        XCTAssertTrue(set.contains("refresh()"), "reminder cards carrying the chip follow too")
        XCTAssertTrue(controller.contains("sharingRegistry.register(p.panel)"))
        XCTAssertTrue(controller.contains("c.setCoach(chip, showInScreenshots: showInScreenshots)"))
        XCTAssertFalse(controller.contains("showInScreenshots") && controller.contains("menuShowInScreenshots"), "not a menu item")
        let copy = try read("App/CoachCopy.swift")
        XCTAssertTrue(copy.contains("static let screenshotsToggle = \"Show Coach in Screenshots\""))
        XCTAssertFalse(copy.contains("menuShowInScreenshots"))
        let settings = try read("App/CoachSettingsWindow.swift")
        XCTAssertTrue(settings.contains("coach.setShowInScreenshots(sender.state == .on)"))
        XCTAssertTrue(settings.contains("screenshotsSwitch.state = coach.showInScreenshots ? .on : .off"), "the switch follows the setting")
        XCTAssertTrue(settings.contains("var showInScreenshots: Bool"), "part of the refresh's view state")
    }

    /// `.readOnly` and `.none` for window sharing are chosen in one place; no other App file sets a sharing type by hand.
    func testNoOtherPlaceSetsASharingTypeByHand() throws {
        let files = try FileManager.default.contentsOfDirectory(atPath: Self.swiftDir.appendingPathComponent("App").path).filter { $0.hasSuffix(".swift") }
        for f in files where f != "CoachSharingAppKit.swift" {
            let text = try read("App/\(f)")
            XCTAssertFalse(text.contains(".sharingType = .readOnly"), "\(f)")
            XCTAssertFalse(text.contains("sharingType = .readOnly"), "\(f)")
        }
    }

    func testNoNewPermissionsOrPlistKeys() throws {
        let plistData = Data(try read("App/Info.plist").utf8)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        XCTAssertEqual(Set(plist.keys.filter { $0.hasSuffix("UsageDescription") }),
                       ["NSMicrophoneUsageDescription", "NSAudioCaptureUsageDescription", "NSAppleEventsUsageDescription"])
    }
}
