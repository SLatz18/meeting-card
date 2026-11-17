import XCTest
@testable import ListenMoreCore

final class CoachMenuTests: XCTestCase {
    func testOffAlwaysOffersEnable() {
        for indicator in [CoachIndicator.hidden, .on, .listening, .paused, .muted] {
            XCTAssertEqual(CoachMenu.items(enabled: false, indicator: indicator, gptAvailable: false),
                           [.status(.off), .enable, .separator, .settings])
        }
    }

    func testEachStateOffersItsControl() {
        func items(_ i: CoachIndicator) -> [CoachMenuItem] { CoachMenu.items(enabled: true, indicator: i, gptAvailable: true) }
        XCTAssertEqual(items(.hidden), [.status(.waiting), .startNow, .turnOff, .separator, .settings])
        XCTAssertEqual(items(.on), [.status(.on), .stopForCall, .turnOff, .separator, .settings])
        XCTAssertEqual(items(.listening), [.status(.listening), .pause, .stopForCall, .turnOff, .separator, .settings])
        XCTAssertEqual(items(.paused), [.status(.paused), .resume, .stopForCall, .turnOff, .separator, .settings])
        XCTAssertEqual(items(.muted), [.status(.muted), .pause, .stopForCall, .turnOff, .separator, .settings])
    }

    /// Stop replaces Skip this call and is there whenever the coach is pre-warmed or in a session.
    func testStopForThisCallReplacesSkip() {
        for indicator in [CoachIndicator.on, .listening, .paused, .muted] {
            XCTAssertTrue(CoachMenu.items(enabled: true, indicator: indicator, gptAvailable: true).contains(.stopForCall), "\(indicator)")
        }
        XCTAssertFalse(CoachMenu.items(enabled: true, indicator: .hidden, gptAvailable: true).contains(.stopForCall))
    }

    func testLocalOnlyShowsGptOffUnderTheStatus() {
        XCTAssertEqual(CoachMenu.items(enabled: true, indicator: .listening, gptAvailable: false),
                       [.status(.listening), .gptOff, .pause, .stopForCall, .turnOff, .separator, .settings])
    }
}
