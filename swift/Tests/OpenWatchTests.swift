import XCTest
@testable import MeetingCardCore

/// #4: Join -> "Opening...", the card stays until the meeting surface is up, Join comes back after
/// ~15s with no signal. Detection is pure over injected snapshots (process list, frontmost, clock).
final class OpenWatchTests: XCTestCase {
    static let aside = "at.studio.asidebrowser", zoomApp = "us.zoom.xos", slack = "com.tinyspeck.slackmacgap"
    func p(front: String? = slack, cpt: Set<Int32> = [], browser: String? = aside) -> OpenProbe {
        OpenProbe(frontmost: front, zoomMeetingPIDs: cpt, defaultBrowser: browser)
    }

    // MARK: pure OpenWatch

    func testZoomNewCptHostOpens() {
        let w = OpenWatch(provider: "zoom", at: 0, probe: p())
        XCTAssertEqual(w.step(p(front: Self.aside), at: 1), .waiting)
        XCTAssertEqual(w.step(p(front: Self.aside, cpt: [9794]), at: 3), .opened("zoom meeting pid 9794"))
    }

    /// Brief refinement (binding): Scott already in a Zoom meeting -> that CptHost must not count.
    func testPreExistingCptHostDoesNotOpen() {
        let w = OpenWatch(provider: "zoom", at: 0, probe: p(cpt: [9794]))
        XCTAssertEqual(w.step(p(cpt: [9794]), at: 1), .waiting)
        XCTAssertEqual(w.step(p(front: Self.zoomApp, cpt: [9794]), at: 5), .waiting)
        XCTAssertEqual(w.step(p(cpt: [9794, 12001]), at: 6), .opened("zoom meeting pid 12001"))
    }

    /// Ruling: the browser coming forward (Zoom launch page) is NOT a Zoom open.
    func testBrowserFrontDoesNotOpenZoom() {
        let w = OpenWatch(provider: "zoom", at: 0, probe: p())
        XCTAssertEqual(w.step(p(front: Self.aside), at: 2), .waiting)
        XCTAssertEqual(w.step(p(front: Self.zoomApp), at: 3), .waiting, "zoom.us frontmost alone is not a meeting")
    }

    func testMeetTeamsWebexOpenWhenDefaultBrowserFrontmost() {
        for prov in ["meet", "teams", "webex"] {
            let w = OpenWatch(provider: prov, at: 0, probe: p())
            XCTAssertEqual(w.step(p(), at: 1), .waiting, prov)
            XCTAssertEqual(w.step(p(front: "com.apple.Safari"), at: 2), .waiting, "\(prov): not the default browser")
            XCTAssertEqual(w.step(p(front: Self.aside), at: 3), .opened("browser \(Self.aside) frontmost"), prov)
        }
    }

    func testNewCptHostDoesNotOpenMeet() {
        let w = OpenWatch(provider: "meet", at: 0, probe: p())
        XCTAssertEqual(w.step(p(cpt: [12001]), at: 2), .waiting)
    }

    func testTimeoutAtFifteenSeconds() {
        XCTAssertEqual(OpenWatch.timeout, 15)
        let w = OpenWatch(provider: "zoom", at: 100, probe: p())
        XCTAssertEqual(w.step(p(front: Self.aside), at: 114.9), .waiting)
        XCTAssertEqual(w.step(p(front: Self.aside), at: 115), .timedOut)
        // A signal on the same poll as the deadline still wins (it really opened).
        XCTAssertEqual(w.step(p(cpt: [1]), at: 115), .opened("zoom meeting pid 1"))
    }

    func testDefaultBrowserCapturedAtClick() {
        // The expected browser is the default AT THE CLICK, not a later read.
        let w = OpenWatch(provider: "meet", at: 0, probe: p(browser: Self.aside))
        XCTAssertEqual(w.step(p(front: Self.aside, browser: "com.apple.Safari"), at: 1), .opened("browser \(Self.aside) frontmost"))
    }

    // MARK: Coordinator wiring

    final class Rig {
        var now: Date; var mono: TimeInterval = 0
        var probe = OpenProbe(frontmost: OpenWatchTests.slack, zoomMeetingPIDs: [], defaultBrowser: OpenWatchTests.aside)
        var probes = 0
        var made: [FakeCard] = []
        let logs = LogBox()
        var ctl: Coordinator<FakeCard>!
        /// detection: true = the (switched-off) OpenWatch detection path; nil = the Coordinator's
        /// default, i.e. what the app ships (OpenWatch.detectionEnabled).
        init(_ ev: Event, detection: Bool? = true) {
            now = start(ev) - 2 * M
            let mk: (Event, CardSlot, Date) -> FakeCard = { [unowned self] ev, _, _ in let c = FakeCard(ev); self.made.append(c); return c }
            let pr: () -> OpenProbe = { [unowned self] in self.probes += 1; return self.probe }
            if let detection {
                ctl = Coordinator<FakeCard>(
                    recheck: false, log: { [logs] in logs.add($0) }, makeCard: mk,
                    spawnGet: { _, _ in }, clock: { [unowned self] in self.now }, mono: { [unowned self] in self.mono },
                    probe: pr, detection: detection)
            } else {
                ctl = Coordinator<FakeCard>(
                    recheck: false, log: { [logs] in logs.add($0) }, makeCard: mk,
                    spawnGet: { _, _ in }, clock: { [unowned self] in self.now }, mono: { [unowned self] in self.mono },
                    probe: pr)
            }
            ctl.pollResult([ev]); ctl.tick()
        }
        func advance(_ s: TimeInterval) { now += s; mono += s }
    }

    func testJoinZoomStaysOpeningUntilNewCptHost() {
        let r = Rig(fx("zoom"))
        let c = r.made[0]
        XCTAssertNotNil(r.ctl.join(c))
        XCTAssertEqual(r.ctl.cards.count, 1, "card stays after Join (was: closed in the same second)")
        XCTAssertFalse(c.closedCalled)
        XCTAssertEqual(c.opening, [true])
        XCTAssertTrue(r.ctl.isOpening(c))
        r.probe.frontmost = Self.aside; r.advance(1); r.ctl.openTick()
        XCTAssertEqual(r.ctl.cards.count, 1, "browser launch page is not a Zoom open")
        r.probe.zoomMeetingPIDs = [9794]; r.advance(2); r.ctl.openTick()
        XCTAssertEqual(r.ctl.cards.count, 0)
        XCTAssertTrue(c.closedCalled)
        XCTAssertTrue(r.logs.lines.contains { $0.contains("opened") && $0.contains("zoom meeting pid 9794") })
        XCTAssertFalse(r.ctl.isOpening(c))
    }

    func testJoinWhileAlreadyInZoomMeetingWaitsForNewCptHost() {
        let r = Rig(fx("zoom"))
        r.probe.zoomMeetingPIDs = [9794]
        _ = r.ctl.join(r.made[0])
        for _ in 0..<4 { r.advance(1); r.ctl.openTick() }
        XCTAssertEqual(r.ctl.cards.count, 1, "pre-existing CptHost does not close the card")
    }

    func testMeetClosesWhenBrowserFrontmost() {
        let r = Rig(fx("meet"))
        _ = r.ctl.join(r.made[0])
        r.advance(0.5); r.ctl.openTick()
        XCTAssertEqual(r.ctl.cards.count, 1)
        r.probe.frontmost = Self.aside; r.advance(0.5); r.ctl.openTick()
        XCTAssertEqual(r.ctl.cards.count, 0)
    }

    func testTimeoutBringsJoinBackAndRetryRestartsWatch() {
        let r = Rig(fx("zoom"))
        let c = r.made[0]
        _ = r.ctl.join(c)
        r.probe.frontmost = Self.aside
        for _ in 0..<14 { r.advance(1); r.ctl.openTick() }
        XCTAssertTrue(r.ctl.isOpening(c))
        r.advance(1); r.ctl.openTick()
        XCTAssertFalse(r.ctl.isOpening(c))
        XCTAssertEqual(c.opening, [true, false], "Join comes back")
        XCTAssertEqual(r.ctl.cards.count, 1, "card stays after the timeout")
        XCTAssertTrue(r.logs.lines.contains { $0.contains("open timeout") })
        // Retry: a fresh 15s window from the second click.
        XCTAssertNotNil(r.ctl.join(c))
        XCTAssertEqual(c.opening, [true, false, true])
        for _ in 0..<14 { r.advance(1); r.ctl.openTick() }
        XCTAssertTrue(r.ctl.isOpening(c), "retry got its own 15s")
    }

    func testJoinDuringOpeningIsANoOp() {
        let r = Rig(fx("zoom"))
        let c = r.made[0]
        XCTAssertNotNil(r.ctl.join(c))
        XCTAssertNil(r.ctl.join(c), "Return / a second click while opening does not open again")
        XCTAssertEqual(c.opening, [true])
    }

    func testIgnoreDuringOpeningClosesAtOnce() {
        let r = Rig(fx("zoom"))
        let c = r.made[0]
        _ = r.ctl.join(c)
        r.ctl.ignore(c)
        XCTAssertEqual(r.ctl.cards.count, 0)
        XCTAssertFalse(r.ctl.isOpening(c))
        r.probe.zoomMeetingPIDs = [1]; r.ctl.openTick()
        XCTAssertFalse(r.logs.lines.contains { $0.contains("opened") })
    }

    func testOpenInCalendarClosesAtOnce() {
        let r = Rig(fx("multilink"))
        let c = r.made[0]
        XCTAssertEqual(r.ctl.join(c), "https://www.google.com/calendar/event?eid=TEST_MULTILINK")
        XCTAssertEqual(r.ctl.cards.count, 0, "no meeting to detect")
        XCTAssertEqual(c.opening, [])
    }

    func testMeetingEndDuringOpeningClosesAndClearsWatch() {
        let ev = fx("zoom")
        let r = Rig(ev)
        let c = r.made[0]
        _ = r.ctl.join(c)
        r.now = Timing.times(ev)!.end; r.ctl.tick()
        XCTAssertEqual(r.ctl.cards.count, 0)
        XCTAssertFalse(r.ctl.isOpening(c))
    }

    func testLiveUpdateDuringOpeningKeepsOpening() {
        let ev = fx("zoom")
        let r = Rig(ev)
        let c = r.made[0]
        _ = r.ctl.join(c)
        var t = ev; t.summary = "Renamed"
        r.ctl.liveDone(c, c.rk.shouldStart(r.mono + 100) ?? 0, .event(t))
        XCTAssertEqual(c.refreshed.count, 1)
        XCTAssertEqual(c.opening, [true, true], "refresh rebuilt the button; opening re-applied after it")
    }

    func testProbeOnlyWhileOpening() {
        let r = Rig(fx("zoom"))
        r.ctl.openTick(); r.ctl.openTick()
        XCTAssertEqual(r.probes, 0, "no process-list reads unless a card is opening")
        _ = r.ctl.join(r.made[0])
        XCTAssertEqual(r.probes, 1, "baseline snapshot at the click")
        r.ctl.openTick()
        XCTAssertEqual(r.probes, 2)
    }

    /// App wiring (hostless tests can't run AppKit): the real poll + the grant-free probe are hooked up.
    func testAppPollsOpenTickWithTheRealProbe() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/Controller.swift"))
        XCTAssertTrue(src.contains("probe: { OpenProbeReader.read() })"))
        XCTAssertTrue(src.contains("schedule(Controller.openInterval, repeats: true) { [unowned self] in self.coord.openTick() }"))
        XCTAssertTrue(src.contains("static let cptHostSuffix = \"/zoom.us.app/Contents/Frameworks/CptHost.app/Contents/MacOS/CptHost\""))
        for banned in ["CGWindowListCopyWindowInfo", "kCGWindowName", "AXUIElement", "NSAppleScript"] {
            XCTAssertFalse(src.contains(banned), "no titles / Accessibility / AppleScript: \(banned)")
        }
    }
}
