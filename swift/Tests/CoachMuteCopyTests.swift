import XCTest
@testable import MeetingCardCore

/// The Mute in Zoom control's copy, per reason and state.
final class CoachMuteCopyTests: XCTestCase {
    static let swiftDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    func testDisabledStringsAreTheApprovedWording() {
        XCTAssertEqual(CoachMuteCopy.strings["coach.mute.disabled.off"],
                       "Turn on \"Use Zoom/Meet controls\" in Settings to mute in Zoom from here.")
        XCTAssertEqual(CoachMuteCopy.strings["coach.mute.disabled.permission"],
                       "Allow MeetingCard in Privacy & Security to mute in Zoom from here.")
        XCTAssertEqual(CoachMuteCopy.strings["coach.mute.disabled.meet"], "Meet can't be muted from here. Mute in the Meet window.")
        XCTAssertEqual(CoachMuteCopy.strings["coach.a11y.mute.disabled.meet"], "Mute in Zoom is unavailable in a Meet call. Mute in the Meet window.")
        XCTAssertEqual(CoachMuteCopy.strings.count, 4)
    }

    func testEachReasonMapsToItsString() {
        let expected: [MuteDisabledReason: (key: String, text: String)] = [
            .toggleOff: ("coach.mute.disabled.off", "Turn on \"Use Zoom/Meet controls\" in Settings to mute in Zoom from here."),
            .permissionDenied: ("coach.mute.disabled.permission", "Allow MeetingCard in Privacy & Security to mute in Zoom from here."),
            .meet: ("coach.mute.disabled.meet", "Meet can't be muted from here. Mute in the Meet window."),
        ]
        for (reason, e) in expected {
            for muted in [false, true] {
                let p = CoachMuteCopy.presentation(reason: reason, isMuted: muted)
                XCTAssertEqual(p.visibility, .disabled, "\(reason)")
                XCTAssertEqual(p.disabledKey, e.key)
                XCTAssertEqual(p.tooltip, e.text, "\(reason): the tooltip says why")
                XCTAssertEqual(p.accessibilityHelp, e.text)
            }
        }
        XCTAssertEqual(CoachMuteCopy.presentation(reason: .toggleOff, isMuted: false).accessibilityLabel, "Mute your mic in Zoom")
        XCTAssertEqual(CoachMuteCopy.presentation(reason: .permissionDenied, isMuted: true).accessibilityLabel, "Unmute your mic in Zoom")
        for muted in [false, true] {
            let meet = CoachMuteCopy.presentation(reason: .meet, isMuted: muted)
            XCTAssertEqual(meet.accessibilityLabel, "Mute in Zoom is unavailable in a Meet call. Mute in the Meet window.",
                           "coach.a11y.mute.disabled.meet: no Zoom mic to name in a Meet call")
            XCTAssertEqual(meet.tooltip, "Meet can't be muted from here. Mute in the Meet window.", "the tooltip stays coach.mute.disabled.meet")
        }
    }

    func testNoZoomCallHidesTheControlWithNoTooltip() {
        for muted in [false, true] {
            let p = CoachMuteCopy.presentation(reason: .noZoomCall, isMuted: muted)
            XCTAssertEqual(p, MuteControlPresentation(visibility: .hidden, tooltip: nil, accessibilityLabel: nil,
                                                      accessibilityHelp: nil, disabledKey: nil))
        }
        XCTAssertNil(CoachMuteCopy.disabledKey(.noZoomCall))
    }

    func testEnabledTooltipsAndAccessibilityLabelsFollowZoomsMuteState() {
        let live = CoachMuteCopy.presentation(reason: nil, isMuted: false)
        XCTAssertEqual(live.visibility, .enabled)
        XCTAssertEqual(live.tooltip, "Mute in Zoom")
        XCTAssertEqual(live.accessibilityLabel, "Mute your mic in Zoom")
        XCTAssertNil(live.accessibilityHelp)
        let muted = CoachMuteCopy.presentation(reason: nil, isMuted: true)
        XCTAssertEqual(muted.tooltip, "Unmute in Zoom")
        XCTAssertEqual(muted.accessibilityLabel, "Unmute your mic in Zoom")
    }

    /// Mute means only the coach's own listening: no coach string is a bare Mute, Unmute or Muted, and
    /// every line of the Zoom control names Zoom or Meet.
    func testNoCoachStringSaysJustMute() throws {
        let zoomLines = Array(CoachMuteCopy.strings.values) + [CoachMuteCopy.muteTooltip, CoachMuteCopy.unmuteTooltip,
                                                                CoachMuteCopy.muteAccessibilityLabel, CoachMuteCopy.unmuteAccessibilityLabel]
        for line in zoomLines { XCTAssertTrue(line.contains("Zoom") || line.contains("Meet"), line) }
        let re = try NSRegularExpression(pattern: #""((?:[^"\\]|\\.)*)""#)
        for path in ["App/CoachCopy.swift", "Core/CoachMuteCopy.swift", "Core/CoachCard.swift"] {
            let text = try String(contentsOf: Self.swiftDir.appendingPathComponent(path), encoding: .utf8)
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let literal = (text as NSString).substring(with: m.range(at: 1))
                XCTAssertFalse(["Mute", "Unmute", "Muted", "Mute your mic", "Unmute your mic"].contains(literal), "\(path): \"\(literal)\"")
            }
        }
    }

    /// Every Kit reason has a copy reason with the same raw value, and the App maps them exhaustively.
    func testReasonsMatchTheKitAndTheAppMapsEachOne() throws {
        let kit = try String(contentsOf: Self.swiftDir.appendingPathComponent(
            "Packages/ListenMoreKit/Sources/ListenMoreCore/CallControlsModel.swift"), encoding: .utf8)
        let body = try XCTUnwrap(kit.components(separatedBy: "public enum MuteUnavailableReason").dropFirst().first?
            .components(separatedBy: "\n}").first)
        let re = try NSRegularExpression(pattern: #"case (\w+)"#)
        let kitCases = re.matches(in: body, range: NSRange(body.startIndex..., in: body))
            .map { (body as NSString).substring(with: $0.range(at: 1)) }
        XCTAssertEqual(Set(kitCases), Set(MuteDisabledReason.allCases.map(\.rawValue)))
        let controller = try String(contentsOf: Self.swiftDir.appendingPathComponent("App/CoachController.swift"), encoding: .utf8)
        for c in kitCases { XCTAssertTrue(controller.contains("case .\(c): .\(c)"), c) }
        XCTAssertTrue(controller.contains("CoachMuteCopy.presentation(reason: m.muteUnavailableReason.map(Self.muteDisabledReason), isMuted: m.isMuted)"))
    }
}
