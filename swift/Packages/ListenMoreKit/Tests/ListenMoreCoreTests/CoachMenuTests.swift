import XCTest
@testable import ListenMoreCore

final class CoachMenuTests: XCTestCase {
    let allIndicators: [CoachIndicator] = [.hidden, .on, .listening, .micOff, .paused, .muted]

    func items(_ i: CoachIndicator, gpt: Bool = true, micMuted: Bool = false) -> [CoachMenuItem] {
        CoachMenu.items(enabled: true, indicator: i, gptAvailable: gpt, micMuted: micMuted)
    }

    func testOffAlwaysOffersEnable() {
        for indicator in allIndicators {
            XCTAssertEqual(CoachMenu.items(enabled: false, indicator: indicator, gptAvailable: false),
                           [.status(.off), .enable, .separator, .settings])
            XCTAssertEqual(CoachMenu.items(enabled: false, indicator: indicator, gptAvailable: true, micMuted: true),
                           [.status(.off), .enable, .separator, .settings])
        }
    }

    func testEachStateOffersItsControl() {
        XCTAssertEqual(items(.hidden), [.status(.waiting), .startNow, .turnOff, .separator, .settings])
        XCTAssertEqual(items(.on), [.status(.on), .stopForCall, .turnOff, .separator, .settings])
        XCTAssertEqual(items(.listening), [.status(.listening), .pause, .muteMic, .stopForCall, .turnOff, .separator, .settings])
        XCTAssertEqual(items(.micOff), [.status(.micOff), .pause, .unmuteMic, .stopForCall, .turnOff, .separator, .settings])
        XCTAssertEqual(items(.paused), [.status(.paused), .resume, .muteMic, .stopForCall, .turnOff, .separator, .settings])
        XCTAssertEqual(items(.muted), [.status(.muted), .pause, .muteMic, .stopForCall, .turnOff, .separator, .settings])
    }

    /// Stop replaces Skip this call and is there whenever the coach is pre-warmed or in a session.
    func testStopForThisCallReplacesSkip() {
        for indicator in [CoachIndicator.on, .listening, .micOff, .paused, .muted] {
            XCTAssertTrue(items(indicator).contains(.stopForCall), "\(indicator)")
        }
        XCTAssertFalse(items(.hidden).contains(.stopForCall))
    }

    func testLocalOnlyShowsGptOffUnderTheStatus() {
        XCTAssertEqual(items(.listening, gpt: false),
                       [.status(.listening), .gptOff, .pause, .muteMic, .stopForCall, .turnOff, .separator, .settings])
        XCTAssertEqual(items(.micOff, gpt: false),
                       [.status(.micOff), .gptOff, .pause, .unmuteMic, .stopForCall, .turnOff, .separator, .settings])
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
        XCTAssertEqual(items(.paused, micMuted: true),
                       [.status(.paused), .resume, .unmuteMic, .stopForCall, .turnOff, .separator, .settings])
        XCTAssertEqual(items(.muted, micMuted: true),
                       [.status(.muted), .pause, .unmuteMic, .stopForCall, .turnOff, .separator, .settings])
    }

    /// Settings is the last item in every state.
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

    /// Mute or Unmute sits right after Pause or Resume.
    func testMuteSitsRightAfterPauseOrResume() throws {
        for indicator in [CoachIndicator.listening, .micOff, .paused, .muted] {
            for gpt in [false, true] {
                for micMuted in [false, true] {
                    let menu = items(indicator, gpt: gpt, micMuted: micMuted)
                    let control = try XCTUnwrap(menu.firstIndex { $0 == .pause || $0 == .resume })
                    XCTAssertTrue([.muteMic, .unmuteMic].contains(menu[control + 1]), "\(indicator) \(gpt) \(micMuted)")
                }
            }
        }
    }
}
