import XCTest
@testable import MeetingCardCore

/// v2.4 (Scott 2026-10-07 8:32am: "flashed multiple times while displaying 'joining'").
/// 1: the key give-back never orders the panel out (that out/in WAS the flash).
/// 2: no key arming while Joining; Join hands key back once.
/// 3: a refresh during Joining builds the button as "Joining..." directly and doesn't re-place.
/// 4: hold = 15s (now 8s, Scott 9:03am 2026-10-07).
final class FixesV24Tests: XCTestCase {
    typealias Surface = KeyDeliveryTests.Surface
    static let p0 = KeyGate.Point(x: 1000, y: 200)
    static let p1 = KeyGate.Point(x: 1010, y: 205)

    static func appSource() throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/CardPanel.swift"), encoding: .utf8)
    }
    /// Body of `func <name>` up to the next top-level-in-class `func ` / `// MARK`.
    static func body(_ src: String, _ sig: String) -> String {
        guard let r = src.range(of: sig) else { return "" }
        let rest = src[r.upperBound...]
        let end = [rest.range(of: "\n    func "), rest.range(of: "\n    // MARK"), rest.range(of: "\n    private func ")]
            .compactMap { $0?.lowerBound }.min() ?? rest.endIndex
        return String(rest[..<end])
    }

    // MARK: 1 give-back

    func testReleaseKeyNeverOrdersOut() throws {
        let b = Self.body(try Self.appSource(), "func releaseKey()")
        XCTAssertFalse(b.isEmpty)
        XCTAssertFalse(b.contains("orderOut"), "the give-back must never order the panel out (= the flash)")
        XCTAssertFalse(b.contains("orderFront"), "nor re-order it in")
        XCTAssertTrue(b.contains("panel.resignKey()"), "probe-chosen handoff: resignKey() in place")
    }

    // MARK: 2 no arming while Joining

    func testJoinReleasesKeyOnceAndHoverDoesNotRearm() {
        var g = KeyGate(hoverKeys: true); let s = Surface()
        KeyGate.apply(g.step(.appear(cursor: Self.p0)), to: s)
        KeyGate.apply(g.step(.click(inCard: true)), to: s)      // the Join click arms first
        s.calls = []
        KeyGate.apply(g.step(.opening(true)), to: s)
        XCTAssertEqual(s.calls, ["releaseKey"], "Join gives key back once, immediately")
        XCTAssertFalse(g.armed)
        s.calls = []
        for _ in 0..<3 {
            KeyGate.apply(g.step(.hoverEnter(cursor: Self.p1, inCard: true)), to: s)
            KeyGate.apply(g.step(.moved(cursor: Self.p0, inCard: true)), to: s)
            KeyGate.apply(g.step(.click(inCard: true)), to: s)
            KeyGate.apply(g.step(.hoverExit), to: s)
        }
        XCTAssertEqual(s.calls, [], "no arm/release cycles while Joining")
        XCTAssertNil(g.action(keyCode: 36), "Return does nothing while Joining")
        XCTAssertNil(g.action(keyCode: 53), "Esc does nothing while Joining")
    }

    func testOpeningWhileUnarmedDeliversNothingAndOffRestoresArming() {
        var g = KeyGate(hoverKeys: true); let s = Surface()
        KeyGate.apply(g.step(.opening(true)), to: s)
        XCTAssertEqual(s.calls, [])
        KeyGate.apply(g.step(.opening(false)), to: s)
        KeyGate.apply(g.step(.click(inCard: true)), to: s)
        XCTAssertEqual(s.calls, ["cancelGiveBack", "makeKey"], "Join back = arming back")
    }

    func testAppWiresOpeningIntoGate() throws {
        let b = Self.body(try Self.appSource(), "func setOpening(_ on: Bool)")
        XCTAssertTrue(b.contains("gateStep(.opening(on))"), "setOpening must feed the gate")
    }

    // MARK: 3 refresh during Joining

    func testRefreshBuildsJoiningTitleDirectly() throws {
        let b = Self.body(try Self.appSource(), "func refresh(_ ev: Event, now: Date)")
        XCTAssertTrue(b.contains("model.openingTitle(isOpening)"), "button built with its final title")
        XCTAssertFalse(b.contains("model.buttonTitle"), "no intermediate normal title")
        XCTAssertFalse(b.contains("applyOpeningLabel()"), "no relabel after the build")
        XCTAssertFalse(b.contains("place("), "a refresh never re-places")
        XCTAssertFalse(b.contains("orderOut"))
    }

    func testCoreRefreshDuringJoiningDoesNotReplace() {
        let r = OpenWatchTests.Rig(fx("zoom"), detection: nil); let c = r.made[0]
        _ = r.ctl.join(c)
        let placedBefore = c.placed
        var t = fx("zoom"); t.summary = "Renamed"
        r.ctl.liveDone(c, c.rk.shouldStart(r.mono + 100) ?? 0, .event(t))
        XCTAssertEqual(c.refreshed.count, 1)
        XCTAssertEqual(c.placed, placedBefore, "same slot: no place() on a refresh")
        XCTAssertEqual(c.opening.last, true)
    }

    // MARK: 4 hold (8s)

    func testHoldIsEight() {
        XCTAssertEqual(OpenWatch.joinHold, 8)
        let r = OpenWatchTests.Rig(fx("zoom"), detection: nil); let c = r.made[0]
        XCTAssertNotNil(r.ctl.join(c))
        r.advance(7.9); r.ctl.openTick()
        XCTAssertEqual(r.ctl.cards.count, 1, "still Joining at 7.9s")
        XCTAssertTrue(r.ctl.isOpening(c))
        r.advance(0.1); r.ctl.openTick()
        XCTAssertEqual(r.ctl.cards.count, 0, "closed at 8s")
        XCTAssertTrue(r.logs.lines.contains { $0.contains("joined") && $0.contains("8s") })
    }
}
