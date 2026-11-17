import XCTest
@testable import ListenMoreCore

final class CoachMenuTests: XCTestCase {
    func testOffAlwaysOffersEnable() {
        for indicator in [CoachIndicator.hidden, .on, .listening, .paused] {
            XCTAssertEqual(CoachMenu.items(enabled: false, indicator: indicator, gptAvailable: false),
                           [.status(.off), .enable, .separator, .settings])
        }
    }

    func testEachStateOffersItsControl() {
        func items(_ i: CoachIndicator) -> [CoachMenuItem] { CoachMenu.items(enabled: true, indicator: i, gptAvailable: true) }
        XCTAssertEqual(items(.hidden), [.status(.waiting), .startNow, .turnOff, .separator, .settings])
        XCTAssertEqual(items(.on), [.status(.on), .skipThisCall, .turnOff, .separator, .settings])
        XCTAssertEqual(items(.listening), [.status(.listening), .pause, .turnOff, .separator, .settings])
        XCTAssertEqual(items(.paused), [.status(.paused), .resume, .turnOff, .separator, .settings])
    }

    func testLocalOnlyShowsGptOffUnderTheStatus() {
        XCTAssertEqual(CoachMenu.items(enabled: true, indicator: .listening, gptAvailable: false),
                       [.status(.listening), .gptOff, .pause, .turnOff, .separator, .settings])
    }
}
