import XCTest
@testable import MeetingCardCore

/// Port of tests/test_timing.py.
final class TimingTests: XCTestCase {
    func act(_ c: Event, _ f: Event?, _ now: Date, _ p: Phase) -> RecheckAction {
        Timing.recheckAction(cached: c, fresh: f, now: now, phase: p).0
    }

    func testAppearsAtTMinus2() {
        let ev = fx("meet")
        XCTAssertTrue(Timing.isDue(ev, start(ev) - 2 * M))
        XCTAssertFalse(Timing.isDue(ev, start(ev) - 2 * M - 1))
    }

    func testCountdownText() {
        let ev = fx("meet"), st = start(ev)
        XCTAssertEqual(Timing.countdownSuffix(ev, st - 2 * M), "in 2 min")
        XCTAssertEqual(Timing.countdownSuffix(ev, st - 90 * S), "in 2 min")
        XCTAssertEqual(Timing.countdownSuffix(ev, st - 61 * S), "in 2 min")
        XCTAssertEqual(Timing.countdownSuffix(ev, st - 1 * M), "in 1 min")
        XCTAssertEqual(Timing.countdownSuffix(ev, st - 1 * S), "in 1 min")
        XCTAssertEqual(Timing.countdownSuffix(ev, st), "now")
        XCTAssertEqual(Timing.countdownSuffix(ev, st + 30 * S), "now")
    }

    // ---- pre-fire
    func testPrefireCancelledSkips() {
        let ev = fx("meet"); var f = ev; f.status = "cancelled"
        XCTAssertEqual(act(ev, f, start(ev) - M, .prefire), .skip)
    }

    func testPrefireDeclinedSkips() {
        let ev = fx("meet"); var f = ev
        f.attendees = f.attendees!.map { $0.isSelf == true ? Attendee(isSelf: true, responseStatus: "declined") : $0 }
        XCTAssertEqual(act(ev, f, start(ev) - M, .prefire), .skip)
    }

    func testPrefireMovedReschedulesAndFiresLater() {
        let ev = fx("meet"); let s = Scheduler(); s.update([ev])
        let now = start(ev) - 2 * M
        let c = s.due(now)[0]
        let f = moved(ev, 30)
        let (a, use) = Timing.recheckAction(cached: c, fresh: f, now: now, phase: .prefire)
        XCTAssertEqual(a, .reschedule)
        XCTAssertTrue(s.resolve(c, a, use))
        XCTAssertEqual(s.due(now + 5 * S).count, 0)
        XCTAssertEqual(s.due(start(f) - 2 * M).map(Timing.key), [Timing.key(f)])
    }

    func testPrefireLinkChangeUsesFresh() {
        let ev = fx("meet")
        var f = fx("zoom"); f.id = ev.id; f.start = ev.start; f.end = ev.end
        let (a, use) = Timing.recheckAction(cached: ev, fresh: f, now: start(ev) - M, phase: .prefire)
        XCTAssertEqual(a, .show); XCTAssertEqual(use, f)
        XCTAssertEqual(Links.joinLink(use)?.provider, "zoom")
    }

    func testPrefireFailureShowsCached() {
        let ev = fx("meet")
        let (a, use) = Timing.recheckAction(cached: ev, fresh: nil, now: start(ev) - M, phase: .prefire)
        XCTAssertEqual(a, .show); XCTAssertEqual(use, ev)
    }

    func testPrefireMovedStillDueNoDoubleFire() {
        let ev = fx("meet"); let s = Scheduler(); s.update([ev])
        let now = start(ev) - 2 * M
        let c = s.due(now)[0]
        let f = moved(ev, -1)
        let (a, use) = Timing.recheckAction(cached: c, fresh: f, now: now, phase: .prefire)
        XCTAssertEqual(a, .show); XCTAssertEqual(use, f)
        s.resolve(c, a, use)
        s.update([f])
        XCTAssertEqual(s.due(now + 60 * S).count, 0)
    }

    func testLiveMovedStillDueNoDoubleFire() {
        let ev = fx("meet"); let s = Scheduler(); s.update([ev])
        let now = start(ev) - 2 * M
        let c = s.due(now)[0]; s.resolve(c, .show, c)
        let f = moved(ev, -1)
        let (a, use) = Timing.recheckAction(cached: c, fresh: f, now: now + 10 * S, phase: .live)
        XCTAssertEqual(a, .update)
        s.rekey(use)
        s.update([f])
        XCTAssertEqual(s.due(now + 70 * S).count, 0)
    }

    func testStalePendingIsFailedCheck() {
        let ev = fx("meet"); let s = Scheduler(); s.update([ev])
        let now = start(ev) - 2 * M
        let c = s.due(now)[0]
        XCTAssertEqual(s.stale(now + Scheduler.pendingMax).count, 0)
        let st = s.stale(now + Scheduler.pendingMax + S)
        XCTAssertEqual(st.count, 1)
        let (a, use) = Timing.recheckAction(cached: st[0], fresh: nil, now: now + 21 * S, phase: .prefire)
        XCTAssertEqual(a, .show); XCTAssertEqual(use, ev)
        XCTAssertTrue(s.resolve(st[0], a, use))
        XCTAssertEqual(s.stale(now + 30 * S).count, 0)
        XCTAssertFalse(s.resolve(c, .show, c))  // hung thread's late result dropped
        XCTAssertEqual(s.due(now + 31 * S).count, 0)
    }

    // ---- live
    func testLiveCancelCloses() {
        let ev = fx("meet"); var f = ev; f.status = "cancelled"
        XCTAssertEqual(act(ev, f, start(ev), .live), .close)
    }

    func testLiveMovedOutClosesAndReschedules() {
        let ev = fx("meet"); let s = Scheduler(); s.update([ev])
        let now = start(ev) - M
        let c = s.due(now)[0]; s.resolve(c, .show, c)
        let f = moved(ev, 30)
        let (a, use) = Timing.recheckAction(cached: c, fresh: f, now: now, phase: .live)
        XCTAssertEqual(a, .closeReschedule)
        s.reschedule(use); s.closed(c)
        XCTAssertEqual(s.due(start(f) - M).map(Timing.key), [Timing.key(f)])
    }

    func testLiveLinkChangeUpdates() {
        let ev = fx("meet")
        var f = fx("zoom"); f.id = ev.id; f.start = ev.start; f.end = ev.end; f.summary = ev.summary; f.htmlLink = ev.htmlLink
        let (a, use) = Timing.recheckAction(cached: ev, fresh: f, now: start(ev), phase: .live)
        XCTAssertEqual(a, .update); XCTAssertEqual(use, f)
    }

    func testLiveTitleAndEndChangeUpdates() {
        let ev = fx("meet"), st = start(ev)
        var t = ev; t.summary = "New title"
        XCTAssertEqual(act(ev, t, st, .live), .update)
        var f = ev; f.end?.dateTime = "2026-10-06T10:10:00-05:00"
        XCTAssertEqual(act(ev, f, st, .live), .update)
    }

    func testLiveIdenticalKeeps() {
        let ev = fx("meet")
        XCTAssertEqual(act(ev, ev, start(ev), .live), .keep)
    }

    func testLiveFailureKeeps() {
        let ev = fx("meet")
        let (a, use) = Timing.recheckAction(cached: ev, fresh: nil, now: start(ev), phase: .live)
        XCTAssertEqual(a, .keep); XCTAssertEqual(use, ev)
    }

    func testRecheckOneInflightAndStopsOnClose() {
        let r = Rechecker(now: 0)
        XCTAssertNil(r.shouldStart(5))
        let g1 = r.shouldStart(10)
        XCTAssertNotNil(g1)
        XCTAssertNil(r.shouldStart(30))  // one in flight
        XCTAssertTrue(r.accept(31, g1!))
        XCTAssertNil(r.shouldStart(40))  // next measured from completion
        let g2 = r.shouldStart(41)
        XCTAssertNotNil(g2); XCTAssertNotEqual(g2, g1)
        r.close()
        XCTAssertFalse(r.accept(42, g2!))  // current-generation result after close dropped
        XCTAssertNil(r.shouldStart(100))
    }

    // ---- get_event
    func testGetEventOk() throws {
        let body = #"{"kind": "calendar#event", "id": "abc", "status": "confirmed"}"#
        let r = FakeRunner(out: body, err: "Using keyring backend: keyring")
        let ev = try gws(r).getEvent("abc")
        XCTAssertEqual(ev, Event(kind: "calendar#event", id: "abc", status: "confirmed"))
        let c = r.calls[0]
        XCTAssertEqual(c.executable, "/fake/gws")
        XCTAssertEqual(Array(c.args.prefix(3)), ["calendar", "events", "get"])
        XCTAssertEqual(c.args[3], "--params")
        XCTAssertEqual(json(c.args[4]) as! [String: String], ["calendarId": "primary", "eventId": "abc"])
        XCTAssertFalse(c.env["HOME"]!.isEmpty)
        XCTAssertEqual(c.timeout, 8)
    }

    func testGetEventFailuresNil() throws {
        XCTAssertNil(try gws(FakeRunner(rc: 1, err: "error[api]: Not Found")).getEvent("abc"))
        XCTAssertNil(try gws(FakeRunner(out: "nope")).getEvent("abc"))
        XCTAssertNil(try gws(FakeRunner(out: #"{"items": []}"#)).getEvent("abc"))
        XCTAssertNil(try gws(FakeRunner(out: #"{"kind": "calendar#event", "id": "zzz"}"#)).getEvent("abc"))
        XCTAssertNil(try gws(FakeRunner(result: .timedOut)).getEvent("abc"))
        let r = FakeRunner(out: "{}")
        XCTAssertNil(try gws(r).getEvent(""))
        XCTAssertNil(try gws(r).getEvent(nil))
        XCTAssertEqual(r.calls.count, 0)
    }

    func testGetEventDestructiveFatal() {
        XCTAssertThrowsError(try gws(FakeRunner(rc: 1, err: "removing undecryptable credentials")).getEvent("abc")) {
            XCTAssertTrue($0 is GwsFatal)
        }
    }

    // ---- review fixes (codex xhigh)
    func testLiveUnchangedKeepsPastGrace() {
        let ev = fx("meet"), st = start(ev)
        for m in [6.0, 25.0] { XCTAssertEqual(act(ev, ev, st + m * M, .live), .keep) }
    }

    func testLiveClosesAtEnd() {
        let ev = fx("meet")
        XCTAssertEqual(act(ev, ev, Timing.times(ev)!.end, .live), .close)
    }

    func testLiveMovedSoonOrStartedUpdates() {
        let ev = fx("meet"), st = start(ev)
        XCTAssertEqual(act(ev, moved(ev, 1), st, .live), .update)
        XCTAssertEqual(act(ev, moved(ev, -10), st + 10 * M, .live), .update)
        XCTAssertEqual(act(ev, moved(ev, 3), st, .live), .closeReschedule)
    }

    func testMovedKeyWhileOldPendingOneShow() {
        let ev = fx("meet"); let s = Scheduler(); s.update([ev])
        let now = start(ev) - 2 * M
        let c = s.due(now)[0]
        let f = moved(ev, -1)
        s.update([f])
        XCTAssertEqual(s.due(now + 5 * S).count, 0)
        let (a, use) = Timing.recheckAction(cached: c, fresh: f, now: now + 6 * S, phase: .prefire)
        XCTAssertEqual(a, .show); XCTAssertTrue(s.resolve(c, a, use))
        XCTAssertEqual(s.due(now + 7 * S).count, 0)
    }

    func testMovedKeyWhileShowingNoSecondCard() {
        let ev = fx("meet"); let s = Scheduler(); s.update([ev])
        let now = start(ev) - 2 * M
        let c = s.due(now)[0]; s.resolve(c, .show, c)
        let f = moved(ev, 4)
        s.update([f])
        XCTAssertEqual(s.due(start(f) - 2 * M).count, 0)
        s.reschedule(f); s.closed(c)
        XCTAssertEqual(s.due(start(f) - 2 * M).map(Timing.key), [Timing.key(f)])
    }

    func testRecheckHungInflightResetsAfter20s() {
        let r = Rechecker(now: 0)
        XCTAssertNotNil(r.shouldStart(10))
        XCTAssertNil(r.shouldStart(30))
        XCTAssertNotNil(r.shouldStart(30.5))
        XCTAssertEqual(r.inflightSince, 30.5)
    }

    // ---- review fixes round 2
    func testRecheckSupersededReplyDropped() {
        let r = Rechecker(now: 0)
        let g1 = r.shouldStart(10)!
        let g2 = r.shouldStart(31)!
        XCTAssertNotEqual(g1, g2)
        XCTAssertTrue(r.accept(32, g2))
        XCTAssertFalse(r.accept(33, g1))
        XCTAssertEqual(r.nextCheck, 42)
    }

    func testLiveMovedAlreadyEndedCloses() {
        let ev = fx("meet"); let f = moved(ev, -10)
        let fend = Timing.times(f)!.end
        XCTAssertEqual(act(ev, f, fend, .live), .close)
        XCTAssertEqual(act(ev, f, fend + M, .live), .close)
    }

    func testCloseCardReleasesShowing() {
        // The REAL coordinator closeCard (Python: Controller.closeCard) releases `showing`.
        let ctl = controller()
        let ev = fx("meet"); ctl.pollResult([ev])
        let c0 = ctl.sched.due(start(ev) - 2 * M)[0]; ctl.sched.resolve(c0, .show, c0)
        XCTAssertTrue(ctl.sched.showing.contains(ev.id))
        let a = ctl.showCard(ev), b = ctl.showCard(fx("meet"))
        ctl.closeCard(a)
        XCTAssertFalse(ctl.sched.showing.contains(ev.id))
        XCTAssertTrue(a.closedCalled && a.rk.closed)
        XCTAssertTrue(ctl.cards.count == 1 && ctl.cards[0] === b)
        XCTAssertEqual(b.placed, [0])
    }

    func testLiveDoneDropsSupersededGeneration() {
        let ctl = controller()
        let c = ctl.showCard(fx("meet"))
        let g1 = c.rk.shouldStart(10)!; _ = c.rk.shouldStart(31)
        var gone = fx("meet"); gone.status = "cancelled"
        ctl.liveDone(c, g1, .event(gone))  // late gen1 reply saying cancelled
        XCTAssertTrue(ctl.cards.count == 1 && ctl.cards[0] === c)
        XCTAssertFalse(c.closedCalled)
    }
}
