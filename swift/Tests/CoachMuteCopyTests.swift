import XCTest
@testable import MeetingCardCore

/// The Mute in Zoom control: shown only while it can act, with its copy per Zoom's mute state.
final class CoachMuteCopyTests: XCTestCase {
    static let swiftDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    func read(_ path: String) throws -> String {
        try String(contentsOf: Self.swiftDir.appendingPathComponent(path), encoding: .utf8)
    }

    /// Every reason it can't act hides it, with no tooltip and no VoiceOver label: setting off,
    /// Accessibility missing, a Meet call, no Zoom call.
    func testHiddenWheneverItCantAct() {
        for reason in MuteDisabledReason.allCases {
            for muted in [false, true] {
                XCTAssertEqual(CoachMuteCopy.presentation(reason: reason, isMuted: muted),
                               MuteControlPresentation(visibility: .hidden, tooltip: nil, accessibilityLabel: nil), "\(reason)")
            }
        }
    }

    /// Visible only with no reason (setting on, Accessibility granted, a Zoom call), following Zoom's mute.
    func testVisibleOnlyWhenItCanAct() {
        let live = CoachMuteCopy.presentation(reason: nil, isMuted: false)
        XCTAssertEqual(live, MuteControlPresentation(visibility: .enabled, tooltip: "Mute in Zoom", accessibilityLabel: "Mute your mic in Zoom"))
        let muted = CoachMuteCopy.presentation(reason: nil, isMuted: true)
        XCTAssertEqual(muted, MuteControlPresentation(visibility: .enabled, tooltip: "Unmute in Zoom", accessibilityLabel: "Unmute your mic in Zoom"))
    }

    /// The disabled-state lines (setting off, permission, Meet) and the Meet VoiceOver line are retired.
    func testDisabledLinesAreRetired() throws {
        let copy = try read("Core/CoachMuteCopy.swift")
        for gone in ["coach.mute.disabled", "coach.a11y.mute.disabled", "case disabled", "accessibilityHelp", "Meet window",
                     "Privacy & Security", "in Settings to mute"] {
            XCTAssertFalse(copy.contains(gone), gone)
        }
    }

    /// Mute means only the coach's own listening: no coach string is a bare Mute, Unmute or Muted, and
    /// every line of the Zoom control names Zoom.
    func testNoCoachStringSaysJustMute() throws {
        for line in [CoachMuteCopy.muteTooltip, CoachMuteCopy.unmuteTooltip, CoachMuteCopy.muteAccessibilityLabel,
                     CoachMuteCopy.unmuteAccessibilityLabel] {
            XCTAssertTrue(line.contains("Zoom"), line)
        }
        let re = try NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
        for path in ["App/CoachCopy.swift", "Core/CoachMuteCopy.swift", "Core/CoachCard.swift"] {
            let text = try read(path)
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let literal = (text as NSString).substring(with: m.range(at: 1))
                XCTAssertFalse(["Mute", "Unmute", "Muted", "Mute your mic", "Unmute your mic"].contains(literal), "\(path): \"\(literal)\"")
            }
        }
    }

    /// The pill's own Mute reads exactly like the coach menu's.
    func testPillMuteMatchesTheMenu() throws {
        let copy = try read("App/CoachCopy.swift")
        XCTAssertTrue(copy.contains("static let menuMute = \"\(CoachCardCopy.Tooltip.muteMic)\""))
        XCTAssertTrue(copy.contains("static let menuUnmute = \"\(CoachCardCopy.Tooltip.unmuteMic)\""))
        XCTAssertEqual(CoachCardCopy.Tooltip.muteMic, "Mute My Mic for Coach")
        XCTAssertEqual(CoachCardCopy.Tooltip.unmuteMic, "Unmute My Mic for Coach")
    }

    /// VP's copy for what stays: chip, status and the Use Zoom/Meet controls help sentence.
    func testRemainingZoomCopy() throws {
        let copy = try read("App/CoachCopy.swift")
        XCTAssertTrue(copy.contains("static let chipMuted = \"Muted in Zoom\""))
        XCTAssertTrue(copy.contains("static let coachMuted = \"Coach paused while you're muted in Zoom\""))
        XCTAssertTrue(copy.contains("Lets the Mute in Zoom button on the coach card mute your Zoom mic."))
    }

    /// Every Kit reason has a copy reason with the same raw value, and the App maps them exhaustively.
    func testReasonsMatchTheKitAndTheAppMapsEachOne() throws {
        let kit = try read("Packages/ListenMoreKit/Sources/ListenMoreCore/CallControlsModel.swift")
        let body = try XCTUnwrap(kit.components(separatedBy: "public enum MuteUnavailableReason").dropFirst().first?
            .components(separatedBy: "\n}").first)
        let re = try NSRegularExpression(pattern: #"case (\w+)"#)
        let kitCases = re.matches(in: body, range: NSRange(body.startIndex..., in: body))
            .map { (body as NSString).substring(with: $0.range(at: 1)) }
        XCTAssertEqual(Set(kitCases), Set(MuteDisabledReason.allCases.map(\.rawValue)))
        let controller = try read("App/CoachController.swift")
        for c in kitCases { XCTAssertTrue(controller.contains("case .\(c): .\(c)"), c) }
        XCTAssertTrue(controller.contains("CoachMuteCopy.presentation(reason: m.muteUnavailableReason.map(Self.muteDisabledReason), isMuted: m.isMuted)"))
    }
}
