import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import XCTest
@testable import ListenMoreCore

final class CallDisplayTests: XCTestCase {
    // Primary 1440x900 at origin; second display 1920x1080 to its right, bottoms aligned.
    let primary = CGRect(x: 0, y: 0, width: 1440, height: 900)
    let second = CGRect(x: 1440, y: 0, width: 1920, height: 1080)
    var screens: [CGRect] { [primary, second] }

    func win(_ b: String?, _ r: CGRect, layer: Int = 0) -> CallDisplay.WindowInfo {
        CallDisplay.WindowInfo(bundleId: b, layer: layer, bounds: r)
    }

    func testPicksTheCallWindowsDisplay() {
        let w = [win("us.zoom.xos", CGRect(x: 1600, y: 100, width: 1200, height: 800))]
        XCTAssertEqual(CallDisplay.screen(appKey: "us.zoom.xos", windows: w, screens: screens, primaryHeight: 900, fallback: primary), second)
    }

    func testHelperWindowsCountForTheBrowser() {
        let w = [win("com.google.Chrome", CGRect(x: 100, y: 100, width: 1000, height: 700))]
        XCTAssertEqual(CallDisplay.screen(appKey: "com.google.chrome", windows: w, screens: screens, primaryHeight: 900, fallback: second), primary)
    }

    func testLargestWindowWinsAndOverlaysAreIgnored() {
        let w = [win("us.zoom.xos", CGRect(x: 10, y: 10, width: 200, height: 150)),
                 win("us.zoom.xos", CGRect(x: 1500, y: 50, width: 1600, height: 900)),
                 win("us.zoom.xos", CGRect(x: 0, y: 0, width: 3000, height: 1000), layer: 25)]
        XCTAssertEqual(CallDisplay.screen(appKey: "us.zoom.xos", windows: w, screens: screens, primaryHeight: 900, fallback: primary), second)
    }

    func testFallsBackToTheCardsDisplay() {
        let w = [win("com.apple.Safari", CGRect(x: 1600, y: 100, width: 1200, height: 800))]
        XCTAssertEqual(CallDisplay.screen(appKey: "us.zoom.xos", windows: w, screens: screens, primaryHeight: 900, fallback: second), second)
        XCTAssertEqual(CallDisplay.screen(appKey: nil, windows: w, screens: screens, primaryHeight: 900, fallback: second), second)
        XCTAssertEqual(CallDisplay.screen(appKey: nil, windows: [], screens: screens, primaryHeight: 900, fallback: nil), primary)
    }

    // The call window rule (flag on): the display holding the call's own window.

    func testBoundWindowPicksTheCallWindowsDisplay() {
        XCTAssertEqual(CallDisplay.screen(callWindow: CGRect(x: 1600, y: 100, width: 1200, height: 800), screens: screens,
                                          primaryHeight: 900, fallback: primary), second)
        XCTAssertEqual(CallDisplay.screen(callWindow: CGRect(x: 100, y: 100, width: 1000, height: 700), screens: screens,
                                          primaryHeight: 900, fallback: second), primary)
    }

    func testBoundWindowMostOfTheWindowDecides() {
        let straddling = CGRect(x: 1000, y: 100, width: 1200, height: 600)   // 440 on primary, 760 on second
        XCTAssertEqual(CallDisplay.screen(callWindow: straddling, screens: screens, primaryHeight: 900, fallback: primary), second)
    }

    func testBoundWindowFallsBackToTheCardsDisplay() {
        XCTAssertEqual(CallDisplay.screen(callWindow: nil, screens: screens, primaryHeight: 900, fallback: second), second)
        XCTAssertEqual(CallDisplay.screen(callWindow: nil, screens: screens, primaryHeight: 900, fallback: nil), primary)
        let offscreen = CGRect(x: 9000, y: 9000, width: 500, height: 500)
        XCTAssertEqual(CallDisplay.screen(callWindow: offscreen, screens: screens, primaryHeight: 900, fallback: second), second)
    }

    func testCoordinateFlip() {
        XCTAssertEqual(CallDisplay.cocoaRect(CGRect(x: 0, y: 0, width: 100, height: 50), primaryHeight: 900),
                       CGRect(x: 0, y: 850, width: 100, height: 50))
    }
}
