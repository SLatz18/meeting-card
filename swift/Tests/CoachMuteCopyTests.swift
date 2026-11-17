import XCTest
@testable import MeetingCardCore

/// The Mute control's approved copy, per reason and state.
final class CoachMuteCopyTests: XCTestCase {
    static let swiftDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    func testDisabledStringsAreTheApprovedWording() {
        XCTAssertEqual(CoachMuteCopy.strings["coach.mute.disabled.off"],
                       "Turn on \"Use Zoom/Meet controls\" in Settings to mute here.")
        XCTAssertEqual(CoachMuteCopy.strings["coach.mute.disabled.permission"],
                       "Allow MeetingCard in Privacy & Security to mute here.")
        XCTAssertEqual(CoachMuteCopy.strings["coach.mute.disabled.meet"], "Mute from the Meet window")
        XCTAssertEqual(CoachMuteCopy.strings.count, 3)
    }

    func testEachReasonMapsToItsString() {
        let expected: [MuteDisabledReason: (key: String, text: String)] = [
            .toggleOff: ("coach.mute.disabled.off", "Turn on \"Use Zoom/Meet controls\" in Settings to mute here."),
            .permissionDenied: ("coach.mute.disabled.permission", "Allow MeetingCard in Privacy & Security to mute here."),
            .meet: ("coach.mute.disabled.meet", "Mute from the Meet window"),
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
        XCTAssertEqual(CoachMuteCopy.presentation(reason: .toggleOff, isMuted: false).accessibilityLabel, "Mute your Zoom mic")
        XCTAssertEqual(CoachMuteCopy.presentation(reason: .permissionDenied, isMuted: true).accessibilityLabel, "Unmute your Zoom mic")
        XCTAssertEqual(CoachMuteCopy.presentation(reason: .meet, isMuted: false).accessibilityLabel, "Mute from the Meet window",
                       "no Zoom mic to name in a Meet call")
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
        XCTAssertEqual(live.tooltip, "Mute your mic")
        XCTAssertEqual(live.accessibilityLabel, "Mute your Zoom mic")
        XCTAssertNil(live.accessibilityHelp)
        let muted = CoachMuteCopy.presentation(reason: nil, isMuted: true)
        XCTAssertEqual(muted.tooltip, "Unmute your mic")
        XCTAssertEqual(muted.accessibilityLabel, "Unmute your Zoom mic")
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
