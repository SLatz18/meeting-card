import AppKit
import XCTest
@testable import ListenMoreCore
@testable import ListenMoreMac

/// The call window tracker with a fake window list: which apps it asks for (browsers never without a
/// Meet hint, so browser-only polling never reads the window list) and what it binds.
final class CallWindowTrackerTests: XCTestCase {
    static let zoom = "us.zoom.xos"
    static let chrome = "com.google.chrome"
    static let dia = "company.thebrowser.dia"
    let browsers: Set<String> = [chrome, dia]
    let home = CGRect(x: 0, y: 0, width: 1400, height: 880)
    let meeting = CGRect(x: 1600, y: 100, width: 1000, height: 700)

    final class Source {
        var windows: [AppWindow] = []
        var asked: [Set<String>] = []
        func read(_ keys: Set<String>) -> [AppWindow] {
            asked.append(keys)
            return windows.filter { w in w.bundleId.map { id in keys.contains { BundleIds.belongs(id, to: $0) } } == true }
        }
    }

    func window(_ id: Int, _ bundle: String, _ r: CGRect) -> AppWindow {
        AppWindow(id: id, bundleId: bundle, layer: 0, onScreen: true, bounds: r)
    }

    func testBrowserOnlyPollingNeverReadsTheWindowList() {
        let src = Source()
        let t = CallWindowTracker(lookbackS: 60, windowSource: src.read)
        for i in 0..<20 {
            t.update(session: nil, appKeys: [Self.chrome, Self.dia], browserKeys: browsers, hints: [:], now: Double(i) / 2)
        }
        t.update(session: (appKey: Self.chrome, startedAt: 3), appKeys: [Self.chrome, Self.dia], browserKeys: browsers,
                 hints: [:], now: 10)
        XCTAssertTrue(src.asked.isEmpty, "no native app and no Meet hint: the window list is never read")
        XCTAssertNil(t.target(appKey: Self.chrome))
    }

    func testNativeAppsAreReadEveryPollAndBrowsersOnlyWithAHint() {
        let src = Source()
        let t = CallWindowTracker(lookbackS: 60, windowSource: src.read)
        let keys: Set<String> = [Self.zoom, Self.chrome, Self.dia]
        t.update(session: nil, appKeys: keys, browserKeys: browsers, hints: [:], now: 0)
        t.update(session: nil, appKeys: keys, browserKeys: browsers, hints: [:], now: 0.5)
        XCTAssertEqual(src.asked, [[Self.zoom], [Self.zoom]])
        t.update(session: nil, appKeys: keys, browserKeys: browsers, hints: [Self.chrome: CallWindowHint(rank: 1, visibleWindows: 1)], now: 1)
        XCTAssertEqual(src.asked.last, [Self.zoom, Self.chrome], "Dia has no hint, so it is not read")
    }

    func testBrowserBindsOnlyFromTheHint() {
        let src = Source()
        src.windows = [window(5, "com.google.Chrome", meeting), window(6, "com.google.Chrome", home)]
        let t = CallWindowTracker(lookbackS: 60, windowSource: src.read)
        let hint = CallWindowHint(rank: 1, visibleWindows: 2)
        t.update(session: (appKey: Self.chrome, startedAt: 1), appKeys: [Self.chrome], browserKeys: browsers, hints: [Self.chrome: hint], now: 1)
        XCTAssertEqual(t.target(appKey: Self.chrome), meeting, "the rank-1 window")
        t.update(session: (appKey: Self.chrome, startedAt: 1), appKeys: [Self.chrome], browserKeys: browsers, hints: [:], now: 2)
        XCTAssertNil(t.target(appKey: Self.chrome), "the hint went away: nothing is bound")
    }

    func testZoomMeetingWindowBindsThroughTheTracker() {
        let src = Source()
        let t = CallWindowTracker(lookbackS: 60, windowSource: src.read)
        src.windows = [window(1, "us.zoom.xos", home)]
        t.update(session: nil, appKeys: [Self.zoom], browserKeys: browsers, hints: [:], now: 0)
        src.windows = [window(1, "us.zoom.xos", home), window(2, "us.zoom.xos", meeting)]
        t.update(session: (appKey: Self.zoom, startedAt: 5), appKeys: [Self.zoom], browserKeys: browsers, hints: [:], now: 5)
        XCTAssertEqual(t.target(appKey: Self.zoom), meeting, "the meeting window, not the larger home window")
        XCTAssertEqual(t.callWindowPresent(appKey: Self.zoom), true)
        t.reset()
        XCTAssertNil(t.target(appKey: Self.zoom))
    }
}
