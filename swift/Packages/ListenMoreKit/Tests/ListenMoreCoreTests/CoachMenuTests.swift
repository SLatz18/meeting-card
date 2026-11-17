import XCTest
@testable import ListenMoreCore

final class CoachMenuTests: XCTestCase {
    let allIndicators: [CoachIndicator] = [.hidden, .on, .listening, .micOff, .paused, .muted]

    func items(_ i: CoachIndicator, gpt: Bool = true, micMuted: Bool = false) -> [CoachMenuItem] {
        CoachMenu.items(enabled: true, indicator: i, gptAvailable: gpt, micMuted: micMuted)
    }

    /// Off, the menu's way in is Start Coach, whatever the indicator says.
    func testOffOffersStart() {
        for indicator in allIndicators {
            for (gpt, micMuted) in [(false, false), (true, true)] {
                XCTAssertEqual(CoachMenu.items(enabled: false, indicator: indicator, gptAvailable: gpt, micMuted: micMuted),
                               [.startCoach, .separator, .status(.off), .separator, .settings])
            }
        }
    }

    /// Controls first (Start/Stop, Pause or Resume, Mute or Unmute), then the status lines, then Settings.
    func testEachStateOffersItsControlsThenStatusThenSettings() {
        XCTAssertEqual(items(.hidden), [.startCoach, .separator, .status(.waiting), .separator, .settings])
        XCTAssertEqual(items(.on), [.stopCoach, .separator, .status(.on), .separator, .settings])
        XCTAssertEqual(items(.listening), [.stopCoach, .pause, .muteMic, .separator, .status(.listening), .separator, .settings])
        XCTAssertEqual(items(.micOff), [.stopCoach, .pause, .unmuteMic, .separator, .status(.micOff), .separator, .settings])
        XCTAssertEqual(items(.paused), [.stopCoach, .resume, .muteMic, .separator, .status(.paused), .separator, .settings])
        XCTAssertEqual(items(.muted), [.stopCoach, .pause, .muteMic, .separator, .status(.muted), .separator, .settings])
    }

    /// One Start/Stop toggle: exactly one of the two in every state, Stop whenever pre-warmed or in a session.
    func testOneStartStopToggle() {
        for enabled in [false, true] {
            for indicator in allIndicators {
                let menu = CoachMenu.items(enabled: enabled, indicator: indicator, gptAvailable: true)
                XCTAssertEqual(menu.first, enabled && indicator != .hidden ? .stopCoach : .startCoach, "\(enabled) \(indicator)")
                XCTAssertEqual(menu.filter { $0 == .startCoach || $0 == .stopCoach }.count, 1)
            }
        }
    }

    /// The GPT-off note is a status line, right under the status.
    func testLocalOnlyShowsGptOffUnderTheStatus() {
        XCTAssertEqual(items(.listening, gpt: false),
                       [.stopCoach, .pause, .muteMic, .separator, .status(.listening), .gptOff, .separator, .settings])
        XCTAssertEqual(items(.hidden, gpt: false), [.startCoach, .separator, .status(.waiting), .gptOff, .separator, .settings])
    }

    /// Mute or Unmute shows only during a session: never while off, waiting or pre-warmed.
    func testMuteIsOfferedOnlyDuringASession() {
        for micMuted in [false, true] {
            for indicator in [CoachIndicator.hidden, .on] {
                let menu = items(indicator, micMuted: micMuted)
                XCTAssertFalse(menu.contains(.muteMic) || menu.contains(.unmuteMic), "\(indicator) micMuted=\(micMuted)")
            }
            for indicator in [CoachIndicator.listening, .micOff, .paused, .muted] {
                let menu = items(indicator, micMuted: micMuted)
                XCTAssertEqual(menu.filter { $0 == .muteMic || $0 == .unmuteMic }.count, 1, "\(indicator) micMuted=\(micMuted)")
            }
        }
    }

    /// Mic off offers Unmute even if the host passes no `micMuted`.
    func testMicOffOffersUnmute() {
        XCTAssertTrue(items(.micOff).contains(.unmuteMic))
        XCTAssertFalse(items(.micOff).contains(.muteMic))
        XCTAssertTrue(items(.micOff, micMuted: true).contains(.unmuteMic))
    }

    /// Pause and the call app's mute show over the coach's Mute, so with it on they offer Unmute.
    func testPausedOrMutedWithTheMicOffOfferUnmute() {
        XCTAssertEqual(items(.paused, micMuted: true), [.stopCoach, .resume, .unmuteMic, .separator, .status(.paused), .separator, .settings])
        XCTAssertEqual(items(.muted, micMuted: true), [.stopCoach, .pause, .unmuteMic, .separator, .status(.muted), .separator, .settings])
    }

    /// Settings is the last item in every state (a host's alternate for it, and Send Feedback, follow).
    func testSettingsIsAlwaysLast() {
        for enabled in [false, true] {
            for indicator in allIndicators {
                for gpt in [false, true] {
                    for micMuted in [false, true] {
                        let menu = CoachMenu.items(enabled: enabled, indicator: indicator, gptAvailable: gpt, micMuted: micMuted)
                        XCTAssertEqual(menu.last, .settings, "\(enabled) \(indicator) \(gpt) \(micMuted)")
                        XCTAssertEqual(menu.filter { $0 == .settings }.count, 1)
                    }
                }
            }
        }
    }

    /// Order in a session: Stop, then Pause or Resume, then Mute or Unmute, all before the status.
    func testSessionControlsOrder() throws {
        for indicator in [CoachIndicator.listening, .micOff, .paused, .muted] {
            for gpt in [false, true] {
                for micMuted in [false, true] {
                    let menu = items(indicator, gpt: gpt, micMuted: micMuted)
                    XCTAssertEqual(menu[0], .stopCoach)
                    XCTAssertTrue([.pause, .resume].contains(menu[1]), "\(indicator) \(gpt) \(micMuted)")
                    XCTAssertTrue([.muteMic, .unmuteMic].contains(menu[2]), "\(indicator) \(gpt) \(micMuted)")
                    let status = try XCTUnwrap(menu.firstIndex { if case .status = $0 { return true } else { return false } })
                    XCTAssertGreaterThan(status, 2)
                }
            }
        }
    }
}
