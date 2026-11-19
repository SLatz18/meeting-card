import XCTest
@testable import MeetingCardCore

/// The coach menu's own Mute (mic only): the card's mic-off state, its copy, how the controller wires
/// it (never the call app's mute), that it adds no permission, and the snapshots that show it.
/// Hostless tests can't load AppKit, so the App's sources are read as text.
final class CoachMicMuteTests: XCTestCase {
    static let swiftDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    func read(_ path: String) throws -> String {
        try String(contentsOf: Self.swiftDir.appendingPathComponent(path), encoding: .utf8)
    }

    /// The text after `marker` up to the next closing brace at method indent.
    func body(_ marker: String, in text: String) throws -> String {
        try XCTUnwrap(text.components(separatedBy: marker).dropFirst().first?.components(separatedBy: "\n    }").first, marker)
    }

    /// Mic off still captures the call: Pause is offered, the card is neither held nor live, and it
    /// has its own glyph, distinct from the Zoom Mute button's and the status glyph.
    func testMicOffCardStatus() {
        let mute = CoachMuteCopy.presentation(reason: nil, isMuted: false)
        let off = CoachCardState(status: .micOff, mute: mute)
        let listening = CoachCardState(status: .listening, mute: mute)
        let s = Theme.CoachCard.Symbols.self
        XCTAssertEqual(off.pauseControl, CoachControl(symbol: s.pause, tooltip: CoachCardCopy.Tooltip.pause,
                                                      accessibilityLabel: CoachCardCopy.A11y.pause))
        XCTAssertTrue(off.pauseControl.enabled)
        XCTAssertFalse(off.held, "the call is still captured")
        XCTAssertFalse(off.live)
        XCTAssertEqual(off.stopControl, listening.stopControl)
        XCTAssertEqual(off.sizeControl, listening.sizeControl)
        for mode in [CoachCardState.Mode.card, .pill] {
            XCTAssertEqual(CoachCardState(status: .micOff, mute: mute, mode: mode).sizeControl,
                           CoachCardState(status: .listening, mute: mute, mode: mode).sizeControl)
        }
        XCTAssertEqual(Theme.Coach.micOffSymbol, Theme.Coach.notHearingSymbol, "the status shows the coach not hearing")
        XCTAssertEqual(s.micOff, Theme.Coach.micOffSymbol)
        XCTAssertNotEqual(s.micOff, s.unmute, "never Mute in Zoom's mic.slash.fill")
        XCTAssertNotEqual(s.micOff, s.status)
        XCTAssertEqual(Theme.Coach.menuSymbols.mute, Theme.Coach.hearingSymbol, "the menu's Mute shows the coach hearing")
        XCTAssertEqual(Theme.Coach.menuSymbols.unmute, Theme.Coach.notHearingSymbol)
    }

    /// Every new string lives in CoachCopy, under the draft heading, word for word.
    func testCopyIsDraftedInOnePlace() throws {
        let copy = try read("App/CoachCopy.swift")
        let heading = try XCTUnwrap(copy.range(of: "// MARK: Final copy (VP Comms): the coach menu's Start/Stop toggle and its Mute, mic only"))
        let strings: [(String, String)] = [
            ("menuStart", "Start Coach"),
            ("menuStop", "Stop Coach"),
            ("menuMute", "Mute My Mic for Coach"),
            ("menuUnmute", "Unmute My Mic for Coach"),
            ("menuMuteHelp", "The coach stops hearing your mic. It still hears the others. This doesn't mute you in Zoom or Meet."),
            ("menuUnmuteHelp", "The coach hears your mic again."),
            ("coachMicOff", "Coach is hearing others only"),
            ("chipMicOff", "Coach can't hear you"),
            ("micMutedAnnouncement", "Call coach stopped hearing your mic. It still hears the others."),
            ("micUnmutedAnnouncement", "Call coach hears your mic again."),
        ]
        for (name, value) in strings {
            let line = "static let \(name) = \"\(value)\""
            let at = try XCTUnwrap(copy.range(of: line), line)
            XCTAssertGreaterThan(at.lowerBound, heading.upperBound, "\(name) sits under the heading")
        }
        XCTAssertTrue(copy.contains("static let menuStop = \"Stop Coach\"\n"), "Stop Coach, as on the card button")
        XCTAssertTrue(copy.contains("static let menuStart = \"Start Coach\"\n"))
    }

    /// Mute is the coach's alone: the menu items map to it, it stops only the service's mic, and it
    /// never reaches the call app. The card's Mute button and Send Feedback are as before.
    func testControllerWiring() throws {
        let src = try read("App/CoachController.swift")
        XCTAssertTrue(src.contains("case .muteMic: return action(CoachCopy.menuMute, sym.mute, #selector(muteMicClicked(_:)), tooltip: CoachCopy.menuMuteHelp)"))
        XCTAssertTrue(src.contains("case .unmuteMic: return action(CoachCopy.menuUnmute, sym.unmute, #selector(unmuteMicClicked(_:)), tooltip: CoachCopy.menuUnmuteHelp)"))
        XCTAssertTrue(src.contains("@objc func muteMicClicked(_ sender: Any?) { setMicMuted(true) }"))
        XCTAssertTrue(src.contains("@objc func unmuteMicClicked(_ sender: Any?) { setMicMuted(false) }"))
        XCTAssertTrue(src.contains("case .micOff: return CoachCopy.coachMicOff"), "the status label")

        let mic = try body("func setMicMuted(_ muted: Bool) {", in: src)
        XCTAssertTrue(mic.contains("service.setMicMuted(muted)"))
        for banned in ["callControlsModel", "CallControlsPermissions", "AXUIElement", "toggleMute"] {
            XCTAssertFalse(mic.contains(banned), "Mute touches the call app: \(banned)")
        }

        let toggle = try body("func toggleMute() {", in: src)
        XCTAssertEqual(toggle.trimmingCharacters(in: .whitespacesAndNewlines), "callControlsModel.toggleMute()")

        let menu = try body("func menu(for items: [CoachMenuItem]) -> NSMenu {", in: src)
        let adds = menu.components(separatedBy: "\n").filter { $0.contains("menu.addItem(") }
        XCTAssertEqual(adds.last?.trimmingCharacters(in: .whitespaces), "for entry in MenuFooter.entries { menu.addItem(footerItem(entry)) }",
                       "the version line and Quit close the menu")
        XCTAssertEqual(adds.dropLast().last?.trimmingCharacters(in: .whitespaces), "menu.addItem(feedbackMenuItem())", "Send Feedback keeps its place")
    }

    /// Mute asks for nothing new: still the three usage strings, and no entitlements file.
    func testNoNewPermissions() throws {
        let plistData = Data(try read("App/Info.plist").utf8)
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any])
        let keys = ["NSMicrophoneUsageDescription", "NSAudioCaptureUsageDescription", "NSAppleEventsUsageDescription"]
        XCTAssertEqual(Set(plist.keys.filter { $0.hasSuffix("UsageDescription") }), Set(keys))
        let spec = try read("project.yml").components(separatedBy: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .compactMap { $0.components(separatedBy: ":").first }
            .filter { $0.hasSuffix("UsageDescription") }
        XCTAssertEqual(spec.sorted(), keys.sorted())
        XCTAssertFalse(try read("project.yml").lowercased().contains("entitlements"))

        let e = try XCTUnwrap(FileManager.default.enumerator(at: Self.swiftDir, includingPropertiesForKeys: nil))
        var entitlements: [String] = []
        for case let url as URL in e {
            if url.lastPathComponent == "build" || url.lastPathComponent == ".build" {
                e.skipDescendants()
                continue
            }
            if url.pathExtension == "entitlements" { entitlements.append(url.path) }
        }
        XCTAssertEqual(entitlements, [], "no entitlements file")
    }

    /// The CI snapshots show the mic-off chip, card and pill, and the Mute and Unmute menus, and the gate checks them.
    func testSnapshotsShowMicOff() throws {
        let shots = try read("App/UISnapshots.swift"), script = try read("scripts/snapshots.sh")
        for needle in ["(\"card-mic-off\", shotState(.micOff", "(\"pill-mic-off\", shotState(.micOff", "(\"menu-mute\"", "(\"menu-unmute\"",
                       "case \"mic-off\": return CoachChip(mode: .micOff"] {
            XCTAssertTrue(shots.contains(needle), needle)
        }
        for needle in ["card-mic-off", "pill-mic-off", "menu-mute", "menu-unmute", "mic-off"] {
            XCTAssertTrue(script.contains(needle), needle)
        }
    }
}
