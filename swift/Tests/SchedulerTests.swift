import XCTest
@testable import MeetingCardCore

/// Port of tests/test_scheduler.py.
final class SchedulerTests: XCTestCase {
    func setup() -> (Scheduler, Date, Date) {
        let s = Scheduler()
        s.update([fx("working_location"), fx("meet"), fx("declined")])
        let (st, en) = Timing.times(fx("meet"))!
        return (s, st, en)
    }

    func testFilterOnUpdate() { XCTAssertEqual(setup().0.cache.map { $0.id }, ["meet1"]) }

    func testFireOnce() {
        let (s, st, _) = setup()
        let got = s.due(st)
        XCTAssertEqual(got.map { $0.id }, ["meet1"])
        XCTAssertEqual(s.due(st + 1).count, 0)  // pending
        XCTAssertTrue(s.resolve(got[0], .show, got[0]))
        XCTAssertEqual(s.due(st + 3).count, 0)
        s.update([fx("meet")])
        XCTAssertEqual(s.due(st + 6).count, 0)
        XCTAssertFalse(s.resolve(got[0], .show, got[0]))  // second resolve dropped
    }

    func testRescheduledFiresAgain() {
        let (s, st, _) = setup()
        let c = s.due(st)[0]
        var ev = fx("meet"); ev.start?.dateTime = "2026-10-06T09:30:00-05:00"
        s.update([ev])
        XCTAssertTrue(s.resolve(c, .reschedule, ev))
        XCTAssertEqual(s.due(st + 5 * M).count, 1)
    }

    func testIgnoreSuppresses() {
        let (s, st, _) = setup()
        let ev = s.due(st)[0]
        XCTAssertTrue(s.resolve(ev, .show, ev))
        s.closed(ev)
        s.ignore(ev)
        s.fired.removeAll()
        s.update([fx("meet")])
        XCTAssertEqual(s.due(st + 10).count, 0)
    }

    func testGraceBoundary() {
        let (s, st, _) = setup()
        XCTAssertEqual(s.due(st - Timing.lead - 1).count, 0)
        XCTAssertEqual(s.due(st + 5 * M).count, 1)
        let (s2, _, _) = setup()
        XCTAssertEqual(s2.due(st + 5 * M + 1).count, 0)
    }

    func testEndedNotShown() {
        var ev = fx("meet"); ev.end?.dateTime = "2026-10-06T09:27:00-05:00"
        let s = Scheduler(); s.update([ev])
        XCTAssertEqual(s.due(start(ev) + 3 * M).count, 0)
    }

    func testFailureKeepsCache() {
        let (s, _, _) = setup()
        XCTAssertFalse(s.update(nil))
        XCTAssertEqual(s.cache.map { $0.id }, ["meet1"])
    }
}
