import XCTest
@testable import MeetingCardCore

/// #4 simplified (Scott 2026-10-06 10:24pm): Join (click or Return) shows "Joining..." for a FIXED
/// 30s (v2.4: 15s; v2.5: 8s, Scott 9:03am 2026-10-07), then the card closes. No meeting / browser / CptHost detection: OpenWatch stays in the
/// code but is switched off, so nothing is probed while joining.
final class JoinHoldTests: XCTestCase {
    typealias Rig = OpenWatchTests.Rig
    /// The shipped config: Coordinator built without a detection argument.
    func rig(_ name: String = "zoom") -> Rig { Rig(fx(name), detection: nil) }

    func testDetectionSwitchedOffAndHoldIsEight() {
        XCTAssertFalse(OpenWatch.detectionEnabled)
        XCTAssertEqual(OpenWatch.joinHold, 8)
    }

    /// Mutant guard: if the constant is ignored (detection runs), probes > 0.
    func testNoProbeRunsWhileJoining() {
        for prov in ["zoom", "meet", "teams"] {
            let r = rig(prov)
            XCTAssertNotNil(r.ctl.join(r.made[0]), prov)
            for _ in 0..<40 { r.advance(1); r.ctl.openTick() }
            XCTAssertEqual(r.probes, 0, "\(prov): no process scan / frontmost read while joining")
        }
    }

    func testSignalsDoNotCloseEarly() {
        let r = rig()
        _ = r.ctl.join(r.made[0])
        r.probe.zoomMeetingPIDs = [9794]; r.probe.frontmost = OpenWatchTests.aside
        r.advance(5); r.ctl.openTick()
        XCTAssertEqual(r.ctl.cards.count, 1, "a meeting surface does not close it: fixed hold only")
    }

    func testClosesAtEightNotBefore() {
        let r = rig()
        let c = r.made[0]
        XCTAssertNotNil(r.ctl.join(c))
        XCTAssertEqual(c.opening, [true])
        r.advance(7); r.ctl.openTick()
        XCTAssertEqual(r.ctl.cards.count, 1, "still Joining at 7s")
        XCTAssertTrue(r.ctl.isOpening(c))
        r.advance(0.9); r.ctl.openTick()
        XCTAssertEqual(r.ctl.cards.count, 1, "still Joining at 7.9s")
        r.advance(0.1); r.ctl.openTick()
        XCTAssertEqual(r.ctl.cards.count, 0, "closed at 8s")
        XCTAssertTrue(c.closedCalled)
        XCTAssertEqual(c.opening, [true], "never flips back to Join")
        XCTAssertTrue(r.logs.lines.contains { $0.contains("joined") && $0.contains("8s") })
    }

    /// 9s mutant: a hold of 9 would still be up at 8.
    func testNotStillUpAtEight() {
        let r = rig()
        _ = r.ctl.join(r.made[0])
        r.advance(8); r.ctl.openTick()
        XCTAssertEqual(r.ctl.cards.count, 0)
    }

    func testSecondJoinIsNoOp() {
        let r = rig()
        let c = r.made[0]
        XCTAssertNotNil(r.ctl.join(c))
        r.advance(5)
        XCTAssertNil(r.ctl.join(c), "second click / Return while Joining does not open again")
        XCTAssertEqual(c.opening, [true])
        r.advance(3); r.ctl.openTick()
        XCTAssertEqual(r.ctl.cards.count, 0, "the second press did not restart the 8s")
    }

    func testIgnoreAndCalendarCloseAtOnce() {
        let r = rig()
        _ = r.ctl.join(r.made[0]); r.ctl.ignore(r.made[0])
        XCTAssertEqual(r.ctl.cards.count, 0)
        let r2 = rig("multilink")
        XCTAssertNotNil(r2.ctl.join(r2.made[0]))
        XCTAssertEqual(r2.ctl.cards.count, 0, "Open in Calendar closes at once")
        XCTAssertEqual(r2.made[0].opening, [])
    }

    func testLiveCloseStillClosesJoiningCard() {
        // ended
        let ev = fx("zoom")
        let r = rig()
        _ = r.ctl.join(r.made[0])
        r.now = Timing.times(ev)!.end; r.ctl.tick()
        XCTAssertEqual(r.ctl.cards.count, 0, "meeting ended")
        // cancelled / declined via the live re-check
        for mutate in ["cancelled", "declined"] {
            let r = rig(); let c = r.made[0]
            _ = r.ctl.join(c)
            var t = ev
            if mutate == "cancelled" { t.status = "cancelled" }
            else { t.attendees = [Attendee(isSelf: true, responseStatus: "declined")] }
            r.ctl.liveDone(c, c.rk.shouldStart(r.mono + 100) ?? 0, .event(t))
            XCTAssertEqual(r.ctl.cards.count, 0, mutate)
            XCTAssertFalse(r.ctl.isOpening(c), mutate)
        }
    }

    func testRefreshKeepsJoining() {
        let r = rig(); let c = r.made[0]
        _ = r.ctl.join(c)
        var t = fx("zoom"); t.summary = "Renamed"
        r.ctl.liveDone(c, c.rk.shouldStart(r.mono + 100) ?? 0, .event(t))
        XCTAssertEqual(c.opening, [true, true])
        XCTAssertEqual(CardModel(t).openingTitle(true), "Joining\u{2026}",
                       "every rebuild (incl. light/dark flip) relabels from this rule")
    }

    /// Codex P2 (9f2f2d2): in hold mode a live link change must NOT cancel "Joining...";
    /// the card closes at the original deadline and a second Join stays a no-op.
    func testLinkChangeDuringHoldKeepsHold() {
        let ev = fx("zoom"); let r = rig(); let c = r.made[0]
        XCTAssertNotNil(r.ctl.join(c))
        r.advance(5)
        var e = fx("meet"); e.id = ev.id; e.start = ev.start; e.end = ev.end
        e.summary = ev.summary; e.status = ev.status
        r.ctl.liveDone(c, c.rk.shouldStart(r.mono + 100) ?? 0, .event(e))
        XCTAssertTrue(r.ctl.isOpening(c), "hold survives a link change")
        XCTAssertEqual(c.opening.last, true, "still Joining...")
        XCTAssertNil(r.ctl.join(c), "second Join still a no-op")
        r.advance(2.9); r.ctl.openTick()
        XCTAssertEqual(r.ctl.cards.count, 1)
        r.advance(0.1); r.ctl.openTick()
        XCTAssertEqual(r.ctl.cards.count, 0, "closed at the original t=8")
    }
}
