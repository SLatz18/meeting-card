import XCTest
@testable import MeetingCardCore

/// Swift-side wiring tests for the controller logic (Python covered these through the
/// live app; here the tick loop is pure and driven by an injected clock).
final class CoordinatorTests: XCTestCase {
    final class Rig {
        var now: Date
        var mono: TimeInterval = 0
        var gets: [(String?, (GetOutcome) -> Void)] = []
        var made: [FakeCard] = []
        var retain = true
        var weakMade: [() -> FakeCard?] = []
        var states = 0
        let logs = LogBox()
        var ctl: Coordinator<FakeCard>!
        init(now: Date, recheck: Bool = true, retain: Bool = true) {
            self.now = now; self.retain = retain
            ctl = Coordinator<FakeCard>(
                recheck: recheck, log: { [logs] in logs.add($0) },
                makeCard: { [unowned self] ev, _, _ in let c = FakeCard(ev, rk: Rechecker(now: self.mono)); if self.retain { self.made.append(c) }; self.weakMade.append { [weak c] in c }; return c },
                spawnGet: { [unowned self] id, done in self.gets.append((id, done)) },
                writeState: { [unowned self] _ in self.states += 1 },
                clock: { [unowned self] in self.now }, mono: { [unowned self] in self.mono })
        }
        func advance(_ s: TimeInterval) { now += s; mono += s }
    }

    func testPrefireSuccessShowsOneCardAndPollCannotDouble() {
        let ev = fx("meet")
        let r = Rig(now: start(ev) - 2 * M)
        r.ctl.pollResult([ev])
        r.ctl.tick()
        XCTAssertEqual(r.gets.count, 1)
        r.gets[0].1(.event(ev))
        XCTAssertEqual(r.ctl.cards.count, 1)
        r.ctl.pollResult([ev]); r.advance(1); r.ctl.tick()
        XCTAssertEqual(r.made.count, 1, "one card per id")
        XCTAssertEqual(r.states, 1)
    }

    func testFailedPrefireShowsCachedAndFailedLiveKeepsCard() {
        let ev = fx("meet")
        let r = Rig(now: start(ev) - 2 * M)
        r.ctl.pollResult([ev]); r.ctl.tick()
        r.gets[0].1(.failed)
        XCTAssertEqual(r.ctl.cards.count, 1)
        r.advance(10); r.ctl.tick()
        XCTAssertEqual(r.gets.count, 2, "live recheck started after 10 s")
        r.gets[1].1(.failed)
        XCTAssertEqual(r.ctl.cards.count, 1, "a failed check never closes a card")
        XCTAssertFalse(r.made[0].closedCalled)
    }

    func testStalePrefireShowsCachedAndLateReplyDropped() {
        let ev = fx("meet")
        let r = Rig(now: start(ev) - 2 * M)
        r.ctl.pollResult([ev]); r.ctl.tick()
        r.advance(21); r.ctl.tick()
        XCTAssertEqual(r.ctl.cards.count, 1)
        r.gets[0].1(.event(ev))  // the hung get finally answers
        XCTAssertEqual(r.made.count, 1)
        XCTAssertTrue(r.logs.lines.contains { $0.contains("late result dropped") })
    }

    func testLiveKeepsUntilEndThenAutoCloses() {
        let ev = fx("meet")
        let r = Rig(now: start(ev) - 2 * M, recheck: false)
        r.ctl.pollResult([ev]); r.ctl.tick()
        XCTAssertEqual(r.ctl.cards.count, 1)
        r.now = start(ev) + 20 * M; r.ctl.tick()
        XCTAssertEqual(r.ctl.cards.count, 1, "stays past the 5 min grace")
        r.now = Timing.times(ev)!.end; r.ctl.tick()
        XCTAssertEqual(r.ctl.cards.count, 0)
        XCTAssertTrue(r.made[0].closedCalled)
    }

    func testFatalStopsAllFurtherGwsCalls() {
        let ev = fx("meet")
        let r = Rig(now: start(ev) - 2 * M)
        r.ctl.pollResult([ev]); r.ctl.tick()
        r.gets[0].1(.fatal)
        XCTAssertTrue(r.ctl.stopped)
        XCTAssertEqual(r.ctl.cards.count, 1, "fatal = failed check: card still shows")
        for _ in 0..<5 { r.advance(11); r.ctl.tick() }
        XCTAssertEqual(r.gets.count, 1, "no gws calls after the credential-deletion message")
    }

    func testLiveUpdateRefreshesInPlace() {
        let ev = fx("meet")
        let r = Rig(now: start(ev) - 2 * M)
        r.ctl.pollResult([ev]); r.ctl.tick(); r.gets[0].1(.event(ev))
        r.advance(10); r.ctl.tick()
        var t = ev; t.summary = "Renamed"
        r.gets[1].1(.event(t))
        XCTAssertEqual(r.made.count, 1)
        XCTAssertEqual(r.made[0].refreshed.map { $0.summary }, ["Renamed"])
        XCTAssertEqual(r.states, 2)
    }

    func testJoinAndIgnoreCloseAndSuppress() {
        let ev = fx("meet")
        let r = Rig(now: start(ev) - 2 * M, recheck: false)
        r.ctl.pollResult([ev]); r.ctl.tick()
        XCTAssertEqual(r.ctl.join(r.made[0]), "https://meet.google.com/abc-defg-hij")
        XCTAssertEqual(r.ctl.cards.count, 1, "#4: stays up in Opening... until the meeting is up")
        XCTAssertTrue(r.ctl.isOpening(r.made[0]))
        XCTAssertTrue(r.ctl.sched.ignored.contains(Timing.key(ev)))
        var none = fx("none"); none.location = nil  // #13: blank location + no organizer = "No video link" card, no htmlLink = no button
        let r2 = Rig(now: start(none) - 2 * M, recheck: false)
        r2.ctl.pollResult([none]); r2.ctl.tick()
        XCTAssertNil(r2.ctl.join(r2.made[0]), "no link: Join is a no-op")
        XCTAssertEqual(r2.ctl.cards.count, 1)
        r2.ctl.ignore(r2.made[0])
        XCTAssertEqual(r2.ctl.cards.count, 0)
        r2.ctl.sched.fired.removeAll(); r2.advance(1); r2.ctl.tick()
        XCTAssertEqual(r2.made.count, 1, "ignored stays ignored")
    }

    func testFatalAfterCardClosedAndReleasedStillStops() {
        // codex P1: the live-get callback bailed on the dead weak card BEFORE noteFatal.
        let ev = fx("meet")
        let r = Rig(now: start(ev) - 2 * M, retain: false)
        r.ctl.pollResult([ev]); r.ctl.tick()
        r.gets[0].1(.failed)                     // card shows from cache
        r.advance(10); r.ctl.tick()
        XCTAssertEqual(r.gets.count, 2, "live get in flight")
        r.ctl.ignore(r.ctl.cards[0])             // Scott closes the card mid-get
        XCTAssertNil(r.weakMade[0](), "card actually released")
        r.gets[1].1(.fatal)
        XCTAssertTrue(r.ctl.stopped, "fatal stops gws regardless of card lifetime")
        var later = moved(ev, 30); later.id = "later"
        r.ctl.pollResult([later]); r.now = start(later) - 2 * M; r.ctl.tick()
        for _ in 0..<3 { r.advance(11); r.ctl.tick() }
        XCTAssertEqual(r.gets.count, 2, "no gws calls after the credential-deletion message")
    }
}
