import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif
import XCTest
@testable import ListenMoreCore

/// The call's window, from fake window lists: Zoom's meeting window, never its home (launcher)
/// window, through every window change a real call goes through; Meet's window in Chrome and Dia.
final class CallWindowsTests: XCTestCase {
    static let zoom = "us.zoom.xos"
    static let chrome = "com.google.chrome"
    static let dia = "company.thebrowser.dia"
    let keys: Set<String> = [zoom, chrome, dia]
    let browsers: Set<String> = [chrome, dia]

    // The home window is the larger one, so a "largest window" rule would pick it.
    let home = CGRect(x: 0, y: 0, width: 1400, height: 880)
    let meeting = CGRect(x: 1600, y: 100, width: 1000, height: 700)
    let mini = CGRect(x: 1700, y: 80, width: 320, height: 180)
    let toolbar = CGRect(x: 1700, y: 0, width: 640, height: 52)

    var selector = CallWindowSelector(lookbackS: 60)

    func zoomWindow(_ id: Int, _ r: CGRect, layer: Int = 0, onScreen: Bool = true) -> AppWindow {
        AppWindow(id: id, bundleId: "us.zoom.xos", layer: layer, onScreen: onScreen, bounds: r)
    }

    func observe(_ w: [AppWindow], session: Double? = nil, appKey: String = CallWindowsTests.zoom,
                 hints: [String: CallWindowHint] = [:], at now: Double) {
        selector.observe(w, appKeys: keys, browserKeys: browsers, session: session.map { (appKey: appKey, startedAt: $0) },
                         hints: hints, now: now)
    }

    // MARK: Zoom

    func testMeetingWindowOpensAfterTheMainWindow() {
        observe([zoomWindow(1, home)], at: 0)                                // Zoom open, no call
        observe([zoomWindow(1, home), zoomWindow(2, meeting)], at: 100)      // Join: the meeting window opens
        observe([zoomWindow(1, home), zoomWindow(2, meeting)], session: 104, at: 104)
        XCTAssertEqual(selector.target(appKey: Self.zoom), meeting, "the meeting window, not the larger home window")
        XCTAssertEqual(selector.callWindowPresent(appKey: Self.zoom), true)
    }

    func testMainWindowClosesMidCall() {
        observe([zoomWindow(1, home)], at: 0)
        observe([zoomWindow(1, home), zoomWindow(2, meeting)], session: 5, at: 5)
        observe([zoomWindow(2, meeting)], session: 5, at: 30)
        XCTAssertEqual(selector.target(appKey: Self.zoom), meeting)
        observe([zoomWindow(9, home), zoomWindow(2, meeting)], session: 5, at: 60)   // home reopened from the Dock
        XCTAssertEqual(selector.target(appKey: Self.zoom), meeting, "a later window never takes over")
    }

    func testMeetingMinimizedUsesTheMiniWindowElseNothing() {
        observe([zoomWindow(1, home)], at: 0)
        observe([zoomWindow(1, home), zoomWindow(2, meeting)], session: 5, at: 5)
        observe([zoomWindow(1, home), zoomWindow(2, meeting, onScreen: false)], session: 5, at: 20)
        XCTAssertNil(selector.target(appKey: Self.zoom), "minimized with no mini window: the card's display, never home")
        XCTAssertEqual(selector.callWindowPresent(appKey: Self.zoom), true, "still the meeting's window")
        observe([zoomWindow(1, home), zoomWindow(2, meeting, onScreen: false), zoomWindow(3, mini, layer: 3)], session: 5, at: 21)
        XCTAssertEqual(selector.target(appKey: Self.zoom), mini, "the pop-out mini window stands in")
        observe([zoomWindow(1, home), zoomWindow(2, meeting)], session: 5, at: 40)
        XCTAssertEqual(selector.target(appKey: Self.zoom), meeting, "restored")
    }

    func testFloatingMiniWindowNeverOutranksTheVisibleMeetingWindow() {
        observe([zoomWindow(1, home)], at: 0)
        observe([zoomWindow(1, home), zoomWindow(2, meeting), zoomWindow(3, mini, layer: 3)], session: 5, at: 5)
        XCTAssertEqual(selector.target(appKey: Self.zoom), meeting)
    }

    func testScreenShareToolbarsAreIgnored() {
        observe([zoomWindow(1, home)], at: 0)
        observe([zoomWindow(1, home), zoomWindow(2, meeting)], session: 5, at: 5)
        observe([zoomWindow(1, home), zoomWindow(2, meeting, onScreen: false), zoomWindow(4, toolbar, layer: 25),
                 zoomWindow(5, CGRect(x: 0, y: 0, width: 60, height: 60), layer: 3)], session: 5, at: 30)
        XCTAssertNil(selector.target(appKey: Self.zoom), "share bars and badges are never the call")
        observe([zoomWindow(1, home), zoomWindow(2, meeting), zoomWindow(4, toolbar)], session: 5, at: 31)
        XCTAssertEqual(selector.target(appKey: Self.zoom), meeting, "a layer-0 toolbar is too thin to count")
    }

    func testMultipleZoomWindows() {
        observe([zoomWindow(1, home), zoomWindow(7, CGRect(x: 0, y: 0, width: 700, height: 500))], at: 0)   // home + chat
        observe([zoomWindow(1, home), zoomWindow(7, CGRect(x: 0, y: 0, width: 700, height: 500)), zoomWindow(2, meeting)],
                session: 10, at: 8)
        XCTAssertEqual(selector.target(appKey: Self.zoom), meeting)
        observe([zoomWindow(1, home), zoomWindow(2, meeting), zoomWindow(8, CGRect(x: 0, y: 0, width: 800, height: 600))],
                session: 10, at: 20)                                          // Settings opened mid-call
        XCTAssertEqual(selector.target(appKey: Self.zoom), meeting, "Settings opened later doesn't move it")
    }

    func testZoomLaunchedStraightIntoAMeeting() {
        observe([], at: 0)
        observe([zoomWindow(1, home)], at: 10)                                // launched by a link
        observe([zoomWindow(1, home), zoomWindow(2, meeting)], session: 16, at: 13)
        XCTAssertEqual(selector.target(appKey: Self.zoom), meeting, "the newer one: the meeting window opens after home")
    }

    func testTwoWindowsAppearingTogetherWaitForTheNextChange() {
        observe([], at: 0)
        observe([zoomWindow(1, home), zoomWindow(2, meeting)], session: 3, at: 3)
        XCTAssertNil(selector.target(appKey: Self.zoom), "can't tell them apart: stay quiet")
        observe([zoomWindow(2, meeting)], session: 3, at: 10)
        XCTAssertEqual(selector.target(appKey: Self.zoom), meeting, "re-resolved once the home window closes")
    }

    func testATieNeverResolvesByItselfAndALaterWindowWinsTheFirstBind() {
        let chat = CGRect(x: 1700, y: 100, width: 400, height: 600)
        observe([], at: 0)
        observe([zoomWindow(1, home), zoomWindow(2, meeting)], session: 3, at: 3)
        for t in stride(from: 4.0, through: 60.0, by: 4.0) {
            observe([zoomWindow(1, home), zoomWindow(2, meeting)], session: 3, at: t)
            XCTAssertNil(selector.target(appKey: Self.zoom), "still tied at \(t) s")
        }
        observe([zoomWindow(1, home), zoomWindow(2, meeting), zoomWindow(9, chat)], session: 3, at: 64)
        XCTAssertEqual(selector.target(appKey: Self.zoom), chat, "nothing was bound when Chat opened, so it is the newest and binds")
    }

    func testNothingIdentifiedFallsBackAndNeverLatchesOntoHome() {
        observe([zoomWindow(1, home), zoomWindow(2, meeting)], session: 0, at: 0)   // observing starts mid-call
        observe([zoomWindow(1, home), zoomWindow(2, meeting)], session: 0, at: 30)
        XCTAssertNil(selector.target(appKey: Self.zoom))
        XCTAssertNil(selector.callWindowPresent(appKey: Self.zoom))
        observe([zoomWindow(1, home)], at: 0)
        selector.reset()
        observe([zoomWindow(1, home)], at: 100)
        observe([zoomWindow(1, home)], session: 200, at: 200)                  // a call with no new window
        XCTAssertNil(selector.target(appKey: Self.zoom), "only the home window: the card's display")
    }

    func testOldWindowsOutsideTheLookbackNeverBind() {
        observe([], at: 0)
        observe([zoomWindow(1, home)], at: 1)
        observe([zoomWindow(1, home)], session: 500, at: 500)
        XCTAssertNil(selector.target(appKey: Self.zoom), "opened long before the call")
    }

    func testMeetingWindowClosingReResolves() {
        observe([zoomWindow(1, home)], at: 0)
        observe([zoomWindow(1, home), zoomWindow(2, meeting)], session: 5, at: 5)
        observe([zoomWindow(1, home)], session: 5, at: 50)
        XCTAssertNil(selector.target(appKey: Self.zoom), "meeting window closed: never falls back to home")
        XCTAssertNil(selector.callWindowPresent(appKey: Self.zoom))
        observe([zoomWindow(1, home), zoomWindow(3, meeting)], session: 5, at: 52)   // e.g. a breakout room window
        XCTAssertEqual(selector.target(appKey: Self.zoom), meeting)
        observe([zoomWindow(1, home), zoomWindow(3, meeting)], at: 90)          // session over
        XCTAssertNil(selector.target(appKey: Self.zoom))
    }

    // MARK: re-resolve

    let preview = CGRect(x: 1600, y: 200, width: 640, height: 480)
    let settings = CGRect(x: 1700, y: 150, width: 800, height: 600)

    func testWaitingRoomBindsFirstThenTheMeetingWindowTakesOver() {
        observe([zoomWindow(1, home)], at: 0)
        observe([zoomWindow(1, home), zoomWindow(5, preview)], session: 10, at: 8)    // preview / waiting room
        XCTAssertEqual(selector.target(appKey: Self.zoom), preview)
        observe([zoomWindow(1, home)], session: 10, at: 200)                           // admitted: it closes
        XCTAssertNil(selector.target(appKey: Self.zoom), "between windows: the card's display, never home")
        observe([zoomWindow(1, home), zoomWindow(6, meeting)], session: 10, at: 201)   // then the meeting window opens
        XCTAssertEqual(selector.target(appKey: Self.zoom), meeting, "the binding moves to the meeting window")
    }

    /// The meeting window can open before the preview closes: it opened while the preview was
    /// bound, so it never takes over, and the glow falls back to the card's display (ZW1b accepts it).
    func testMeetingWindowOpeningBeforeThePreviewClosesNeverBinds() {
        observe([zoomWindow(1, home)], at: 0)
        observe([zoomWindow(1, home), zoomWindow(5, preview)], session: 10, at: 8)
        XCTAssertEqual(selector.target(appKey: Self.zoom), preview)
        observe([zoomWindow(1, home), zoomWindow(5, preview), zoomWindow(6, meeting)], session: 10, at: 100)
        XCTAssertEqual(selector.target(appKey: Self.zoom), preview, "the preview stays bound while it is open")
        observe([zoomWindow(1, home), zoomWindow(6, meeting)], session: 10, at: 101)
        XCTAssertNil(selector.target(appKey: Self.zoom), "the meeting window opened while another was bound: the card's display")
        XCTAssertNil(selector.callWindowPresent(appKey: Self.zoom))
        observe([zoomWindow(1, home), zoomWindow(6, meeting)], session: 10, at: 300)
        XCTAssertNil(selector.target(appKey: Self.zoom), "and it stays that way for the call")
    }

    /// Stopping the coach and starting it again mid-call is a new session: its first bind only takes
    /// windows from the last 60 s before it started, so the still-open meeting window doesn't bind.
    func testARestartedSessionMidCallDoesNotRebindTheEarlierWindow() {
        observe([zoomWindow(1, home)], at: 0)
        observe([zoomWindow(1, home), zoomWindow(2, meeting)], session: 5, at: 5)
        XCTAssertEqual(selector.target(appKey: Self.zoom), meeting)
        observe([zoomWindow(1, home), zoomWindow(2, meeting)], at: 100)                 // the coach stopped
        observe([zoomWindow(1, home), zoomWindow(2, meeting)], session: 300, at: 300)   // and started again
        XCTAssertNil(selector.target(appKey: Self.zoom), "documented: the card's display for the rest of that call")
        observe([zoomWindow(1, home), zoomWindow(2, meeting)], session: 300, at: 400)
        XCTAssertNil(selector.target(appKey: Self.zoom))
    }

    /// An app outside the allowlist ("coach any app") joins the watch only when its session starts,
    /// so the windows it already has never bind; one it opens afterwards can.
    func testAnAppOutsideTheAllowlistNeverBindsItsOpenWindows() {
        let other = "com.example.callapp"
        func win(_ id: Int, _ r: CGRect) -> AppWindow { AppWindow(id: id, bundleId: other, layer: 0, onScreen: true, bounds: r) }
        selector.observe([win(1, home), win(2, meeting)], appKeys: keys, browserKeys: browsers, session: nil, hints: [:], now: 0)
        selector.observe([win(1, home), win(2, meeting)], appKeys: keys.union([other]), browserKeys: browsers,
                         session: (appKey: other, startedAt: 10), hints: [:], now: 10)
        XCTAssertNil(selector.target(appKey: other), "its windows were already open when it joined the watch: unknown age")
        selector.observe([win(1, home), win(2, meeting), win(3, preview)], appKeys: keys.union([other]), browserKeys: browsers,
                         session: (appKey: other, startedAt: 10), hints: [:], now: 15)
        XCTAssertEqual(selector.target(appKey: other), preview, "a window it opens after that binds")
    }

    func testOnlyNativeAppsAndBrowsersWithAHintAreRead() {
        let hint = CallWindowHint(rank: 1, visibleWindows: 1)
        XCTAssertEqual(CallWindowSelector.keysToRead(appKeys: keys, browserKeys: browsers, hints: [:]), [Self.zoom],
                       "browsers without a hint cost no window-list read")
        XCTAssertEqual(CallWindowSelector.keysToRead(appKeys: keys, browserKeys: browsers, hints: [Self.chrome: hint]),
                       [Self.zoom, Self.chrome])
        XCTAssertEqual(CallWindowSelector.keysToRead(appKeys: browsers, browserKeys: browsers, hints: [:]), [],
                       "browser-only: nothing to read")
        XCTAssertEqual(CallWindowSelector.keysToRead(appKeys: [Self.zoom, "com.microsoft.teams2"], browserKeys: browsers, hints: [:]),
                       [Self.zoom, "com.microsoft.teams2"])
    }

    func testReResolveFindsAMeetingWindowOlderThanTheLookback() {
        observe([zoomWindow(1, home)], at: 0)
        observe([zoomWindow(1, home), zoomWindow(2, meeting)], at: 10)                 // in the meeting, no audio yet
        observe([zoomWindow(1, home), zoomWindow(2, meeting), zoomWindow(5, preview)], at: 195)   // a join-audio window
        observe([zoomWindow(1, home), zoomWindow(2, meeting), zoomWindow(5, preview)], session: 200, at: 200)
        XCTAssertEqual(selector.target(appKey: Self.zoom), preview, "first bind: only windows within the 60 s lookback")
        observe([zoomWindow(1, home), zoomWindow(2, meeting)], session: 200, at: 205)
        XCTAssertEqual(selector.target(appKey: Self.zoom), meeting, "re-resolve: no lookback, so the 190 s old meeting window binds")
    }

    func testSettingsOrChatOpenedMidCallNeverTakesTheBinding() {
        observe([zoomWindow(1, home)], at: 0)
        observe([zoomWindow(1, home), zoomWindow(2, meeting)], session: 5, at: 5)
        observe([zoomWindow(1, home), zoomWindow(2, meeting), zoomWindow(8, settings)], session: 5, at: 20)
        observe([zoomWindow(1, home), zoomWindow(2, meeting), zoomWindow(8, settings),
                 zoomWindow(9, CGRect(x: 1700, y: 100, width: 400, height: 600))], session: 5, at: 25)   // Chat
        XCTAssertEqual(selector.target(appKey: Self.zoom), meeting, "Settings and Chat don't take it while the meeting window is open")
        observe([zoomWindow(1, home), zoomWindow(8, settings), zoomWindow(9, CGRect(x: 1700, y: 100, width: 400, height: 600))],
                session: 5, at: 40)
        XCTAssertNil(selector.target(appKey: Self.zoom), "only windows opened mid-call are left: the card's display (documented)")
    }

    func testANewSessionStartsWithTheLookbackAgain() {
        observe([zoomWindow(1, home)], at: 0)
        observe([zoomWindow(1, home), zoomWindow(2, meeting)], session: 5, at: 5)
        observe([zoomWindow(1, home)], at: 100)                                        // call over
        observe([zoomWindow(1, home), zoomWindow(3, meeting)], session: 400, at: 400)
        XCTAssertEqual(selector.target(appKey: Self.zoom), meeting)
        observe([zoomWindow(1, home), zoomWindow(3, meeting), zoomWindow(4, settings)], at: 500)   // between calls
        observe([zoomWindow(1, home), zoomWindow(4, settings)], session: 900, at: 900)
        XCTAssertNil(selector.target(appKey: Self.zoom), "a window from 400 s ago never binds a new call's first bind")
    }

    // MARK: Meet in a browser

    func browserWindow(_ id: Int, _ bundle: String, _ r: CGRect, onScreen: Bool = true, layer: Int = 0) -> AppWindow {
        AppWindow(id: id, bundleId: bundle, layer: layer, onScreen: onScreen, bounds: r)
    }

    func testMeetBindsToTheWindowHoldingTheMeetingTab() {
        let front = CGRect(x: 0, y: 0, width: 1400, height: 880), back = CGRect(x: 1500, y: 0, width: 1200, height: 800)
        let w = [browserWindow(11, "com.google.Chrome", front), browserWindow(12, "com.google.Chrome", back)]
        observe(w, session: 0, appKey: Self.chrome, hints: [Self.chrome: CallWindowHint(rank: 2, visibleWindows: 2)], at: 0)
        XCTAssertEqual(selector.target(appKey: Self.chrome), back, "the second visible window holds the call")
        observe(w, session: 0, appKey: Self.chrome, hints: [Self.chrome: CallWindowHint(rank: 1, visibleWindows: 2)], at: 1)
        XCTAssertEqual(selector.target(appKey: Self.chrome), front, "follows the tab when its window comes forward")
    }

    func testMeetWithoutAClearWindowStaysQuiet() {
        let w = [browserWindow(11, "com.google.Chrome", home), browserWindow(12, "com.google.Chrome", meeting)]
        observe(w, session: 0, appKey: Self.chrome, at: 0)
        XCTAssertNil(selector.target(appKey: Self.chrome), "no hint (flag off, several meeting tabs, or minimized)")
        observe(w, session: 0, appKey: Self.chrome, hints: [Self.chrome: CallWindowHint(rank: 1, visibleWindows: 3)], at: 1)
        XCTAssertNil(selector.target(appKey: Self.chrome), "the counts disagree: never guess")
        observe(w + [browserWindow(13, "com.google.Chrome", mini, layer: 3)], session: 0, appKey: Self.chrome,
                hints: [Self.chrome: CallWindowHint(rank: 2, visibleWindows: 2)], at: 2)
        XCTAssertEqual(selector.target(appKey: Self.chrome), meeting, "a floating picture-in-picture window isn't counted")
    }

    func testMeetInDia() {
        let w = [browserWindow(21, "company.thebrowser.dia", home)]
        observe(w, session: 0, appKey: Self.dia, hints: [Self.dia: CallWindowHint(rank: 1, visibleWindows: 1)], at: 0)
        XCTAssertEqual(selector.target(appKey: Self.dia), home, "Dia's only visible window holds the meeting tab")
        observe(w, session: 0, appKey: Self.dia, at: 1)
        XCTAssertNil(selector.target(appKey: Self.dia))
    }

    func testMeetScriptResultDecodes() {
        XCTAssertTrue(MeetScript.decode(0) == (0, 0, 0))
        XCTAssertTrue(MeetScript.decode(2_002_001) == (1, 2, 2))
        XCTAssertTrue(MeetScript.decode(3_000_002) == (2, 0, 3), "two windows hold meeting tabs: no rank")
    }
}
