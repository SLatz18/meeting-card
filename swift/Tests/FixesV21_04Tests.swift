import XCTest
@testable import MeetingCardCore

/// BRIEF-engineer-v2.1-04-fixes: #4 series review (codex).
final class GateReentrancyTests: XCTestCase {
    /// P1: AppKit's canBecomeKey reads gate.allowsKey synchronously inside makeKey(). A surface that
    /// reads its own gate (same reference path as the App's Card) must not trap (exclusivity).
    final class Host: KeySurface {
        var gate = KeyGate(hoverKeys: true)
        var reads: [String] = []
        func makeKey() { reads.append("makeKey allowsKey=\(gate.allowsKey)") }
        func releaseKey() { reads.append("releaseKey allowsKey=\(gate.allowsKey)") }
        func cancelGiveBack() { reads.append("cancel armed=\(gate.armed)") }
    }
    static let p0 = KeyGate.Point(x: 1000, y: 200)

    func testSurfaceCallbacksMayReadTheGate() {
        let h = Host()
        KeyGate.apply(h.gate.step(.appear(cursor: Self.p0)), to: h)
        KeyGate.apply(h.gate.step(.click(inCard: true)), to: h)
        XCTAssertEqual(h.reads, ["cancel armed=true", "makeKey allowsKey=true"])
        h.reads = []
        KeyGate.apply(h.gate.step(.placed(cursor: Self.p0)), to: h)
        XCTAssertEqual(h.reads, ["releaseKey allowsKey=false"])
        h.reads = []
        KeyGate.apply(h.gate.step(.hoverEnter(cursor: KeyGate.Point(x: 1, y: 1), inCard: true)), to: h)
        KeyGate.apply(h.gate.step(.click(inCard: true)), to: h)   // armed: cancel only
        XCTAssertEqual(h.reads, ["cancel armed=true", "makeKey allowsKey=true", "cancel armed=true"])
    }
}


final class OpeningRetargetTests: XCTestCase {
    typealias Rig = OpenWatchTests.Rig
    static let aside = OpenWatchTests.aside

    /// Same id / times as `base`, links from fixture `name`.
    func relinked(_ base: Event, _ name: String) -> Event {
        var e = fx(name); e.id = base.id; e.start = base.start; e.end = base.end
        e.summary = base.summary; e.status = base.status
        return e
    }
    func live(_ r: Rig, _ c: FakeCard, _ ev: Event) {
        r.ctl.liveDone(c, c.rk.shouldStart(r.mono + 100) ?? 0, .event(ev))
    }

    func testZoomToMeetCancelsWatchAndRestoresButton() {
        let ev = fx("zoom"); let r = Rig(ev); let c = r.made[0]
        _ = r.ctl.join(c)
        live(r, c, relinked(ev, "meet"))
        XCTAssertEqual(c.refreshed.count, 1)
        XCTAssertFalse(r.ctl.isOpening(c), "link changed: the Zoom watch must not survive")
        XCTAssertEqual(c.opening.last, false, "normal button restored")
        r.probe.zoomMeetingPIDs = [4242]; r.advance(1); r.ctl.openTick()
        XCTAssertEqual(r.ctl.cards.count, 1, "a CptHost must not close the Meet card")
        XCTAssertNotNil(r.ctl.join(c), "Join works again for the new link")
    }

    func testUpdateToMultiOrNoLinkCancelsWatch() {
        for name in ["multilink", "nolink"] {
            let ev = fx("zoom"); let r = Rig(ev); let c = r.made[0]
            _ = r.ctl.join(c)
            live(r, c, relinked(ev, name))
            XCTAssertFalse(r.ctl.isOpening(c), name)
            XCTAssertEqual(c.opening.last, false, name)
            XCTAssertNotNil(r.ctl.join(c), "\(name): Open in Calendar is not blocked")
            XCTAssertEqual(r.ctl.cards.count, 0, "\(name): Open in Calendar closes at once")
        }
    }

    func testTitleOnlyUpdateKeepsWatch() {
        let ev = fx("zoom"); let r = Rig(ev); let c = r.made[0]
        _ = r.ctl.join(c)
        var t = ev; t.summary = "Renamed"
        live(r, c, t)
        XCTAssertTrue(r.ctl.isOpening(c))
        XCTAssertEqual(c.opening, [true, true])
    }
}

/// P2: an appearance change (refresh) must not bring "Join" back while opening.
final class OpeningSurvivesRefreshTests: XCTestCase {
    func testOpeningTitleHonoursOpening() {
        let m = CardModel(fx("zoom"))
        XCTAssertEqual(m.openingTitle(false), "Join Zoom")
        XCTAssertEqual(m.openingTitle(true), "Joining\u{2026}")
        XCTAssertNil(CardModel(fx("none")).openingTitle(true), "no button, nothing to relabel")
    }

    /// Wiring: the card stores the state Core fed it and every refresh (appearance flip included)
    /// re-applies it, so "Join" cannot come back while Core still says opening.
    func testAppRefreshReappliesStoredOpening() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/CardPanel.swift"))
        XCTAssertTrue(src.contains("private(set) var isOpening = false"), "card stores opening state")
        XCTAssertTrue(src.contains("isOpening = on"), "setOpening stores what Core fed it")
        // v2.4 supersedes the post-build relabel: refresh builds the button from the stored state.
        XCTAssertTrue(src.contains("let title = model.openingTitle(isOpening)"), "refresh builds from stored opening")
        XCTAssertTrue(src.contains("model.openingTitle(isOpening)"), "label comes from the Core rule")
    }
}
