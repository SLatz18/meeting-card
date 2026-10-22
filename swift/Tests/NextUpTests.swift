import XCTest
@testable import MeetingCardCore

/// #11: "Next up" for back-to-back meetings. Card = fx("meet"): 9:25-9:55 AM at -05:00.
final class NextUpTests: XCTestCase {
    let tz = TimeZone(secondsFromGMT: -5 * 3600)!
    let card = fx("meet")

    /// A video event `after` minutes after the card's END (negative = overlaps), 30 min long.
    func nxt(_ id: String, _ title: String, after: Double, response: String? = "accepted") -> Event {
        var e = moved(fx("meet"), 30 + after)
        e.id = id; e.summary = title
        e.attendees = response.map { [Attendee(isSelf: true, responseStatus: $0)] }
        return e
    }
    func line(_ pool: [Event]) -> String? { NextUp.line(for: card, pool: pool, timeZone: tz) }

    func testBackToBackTenMinutesAfterShows() {
        XCTAssertEqual(line([nxt("n", "Team Standup", after: 10)]), "Next up: Team Standup @ 10:05 AM")
    }

    func testWindowEdgeFifteenInSixteenOut() {
        XCTAssertEqual(line([nxt("n", "Ops", after: 15)]), "Next up: Ops @ 10:10 AM")
        XCTAssertNil(line([nxt("n", "Ops", after: 16)]))
    }

    func testRightAtEndIsNotOverlap() {
        XCTAssertEqual(line([nxt("n", "Ops", after: 0)]), "Next up: Ops @ 9:55 AM")
    }

    func testOverlapSaysOverlaps() {
        XCTAssertEqual(line([nxt("n", "Ops", after: -10)]), "Next up: Ops @ 9:45 AM, overlaps")
    }

    func testStartingAtOrBeforeCardStartIsNotNext() {
        XCTAssertNil(line([nxt("n", "Same", after: -30)]), "same start")
        XCTAssertNil(line([nxt("n", "Earlier", after: -35)]), "already running")
    }

    func testResponseRule() {
        XCTAssertNotNil(line([nxt("n", "Z", after: 5, response: "accepted")]))
        XCTAssertNotNil(line([nxt("n", "Z", after: 5, response: "needsAction")]))
        XCTAssertNotNil(line([nxt("n", "Z", after: 5, response: nil)]), "no self attendee")
        XCTAssertNil(line([nxt("n", "Z", after: 5, response: "tentative")]), "OQ-8: tentative excluded")
        XCTAssertNil(line([nxt("n", "Z", after: 5, response: "declined")]))
    }

    func testSkippedKindsExcluded() {
        var allDay = nxt("a", "AllDay", after: 5); allDay.start = EventTime(date: "2026-10-06")
        var wl = nxt("w", "Office", after: 5); wl.eventType = "workingLocation"
        var cx = nxt("c", "Gone", after: 5); cx.status = "cancelled"
        XCTAssertNil(line([allDay])); XCTAssertNil(line([wl])); XCTAssertNil(line([cx]))
    }

    /// OQ-6 (2:15pm): the pool = events that would get a card.
    func testPoolIsExactlyCardWorthyEvents() {
        func noLink(_ selfMade: Bool) -> Event {
            var e = nxt("x", "Chat", after: 5)
            e.hangoutLink = nil; e.conferenceData = nil; e.location = nil; e.description = nil
            e.organizer = Organizer(isSelf: selfMade)
            return e
        }
        XCTAssertEqual(line([noLink(false)]), "Next up: Chat @ 10:00 AM", "someone else's no-link invite counts")
        XCTAssertNil(line([noLink(true)]), "a self-made no-link block does not")
    }

    func testEarliestWinsTiesByTitleThenId() {
        XCTAssertEqual(line([nxt("b", "Later", after: 10), nxt("a", "Sooner", after: 5)]),
                       "Next up: Sooner @ 10:00 AM")
        XCTAssertEqual(line([nxt("1", "Bravo", after: 5), nxt("2", "Alpha", after: 5)]),
                       "Next up: Alpha @ 10:00 AM")
        XCTAssertEqual(NextUp.next(for: card, pool: [nxt("z", "T", after: 5), nxt("y", "T", after: 5)])?.id, "y")
    }

    func testOwnIdExcluded() {
        var me = nxt("meet1", "Me again", after: 5); me.id = card.id
        XCTAssertNil(line([me]))
    }

    func testEmptyTitle() {
        XCTAssertEqual(line([nxt("n", "", after: 5)]), "Next up: (No title) @ 10:00 AM")
    }

    // MARK: coordinator wiring

    func testPollUpdatesLineOnlyOnChangeWithNoExtraCalls() {
        var gets = 0
        let ctl = Coordinator<FakeCard>(recheck: true, log: { _ in },
                                        makeCard: { e, _, _ in FakeCard(e) }, spawnGet: { _, _ in gets += 1 })
        let n = nxt("n", "Ops", after: 10)
        ctl.pollResult([n])
        let c = ctl.showCard(card)
        XCTAssertEqual(c.nextUps, ["Next up: Ops @ \(Timing.formatClock(start(n)))"], "line set at show")
        ctl.pollResult([n])
        XCTAssertEqual(c.nextUps.count, 1, "same poll: no redundant update")
        ctl.pollResult(nil)
        XCTAssertEqual(c.nextUps.count, 1, "failed poll keeps the line")
        ctl.pollResult([])
        XCTAssertEqual(c.nextUps.last, .some(nil), "gone from the list: line removed")
        XCTAssertNil(ctl.nextUp(c))
        XCTAssertEqual(gets, 0, "data comes from the list poll only")
    }

    func testTallerCardPushesCardsAboveUp() {
        let ctl = controller()
        var second = nxt("s", "Second", after: 60); second.summary = "Second"
        let low = ctl.showCard(card), high = ctl.showCard(second)
        XCTAssertEqual(high.slotsPlaced, [], "created at (1, H + gap)")
        ctl.pollResult([nxt("n", "Ops", after: 10), second])
        XCTAssertNotNil(ctl.nextUp(low))
        XCTAssertEqual(high.slotsPlaced.last,
                       CardSlot(1, offset: CardLayout.cardHeight(nextUp: true) + CardLayout.gap))
        ctl.pollResult([second])
        XCTAssertEqual(high.slotsPlaced.last, CardSlot(1, offset: CardLayout.H + CardLayout.gap), "shrinks back")
        // #11 review P2-2: the bottom card's slot never changes, but each grow/shrink re-places it
        // in place (a resize is a KeyGate placement).
        XCTAssertEqual(low.slotsPlaced, [CardSlot(0, offset: 0), CardSlot(0, offset: 0)], "resized in place, never moved")
    }

    func testLiveUpdateOfCardEndRecomputes() {
        var now = start(card)
        let ctl = Coordinator<FakeCard>(recheck: true, log: { _ in },
                                        makeCard: { e, _, _ in FakeCard(e) }, spawnGet: { _, _ in },
                                        clock: { now }, mono: { 100 })
        ctl.pollResult([nxt("n", "Ops", after: 20)])
        let c = ctl.showCard(card)
        XCTAssertNil(ctl.nextUp(c), "20 min after end: not back-to-back")
        var longer = card; longer.end?.dateTime = "2026-10-06T10:05:00-05:00"
        ctl.liveDone(c, c.rk.shouldStart(100)!, .event(longer))
        XCTAssertEqual(ctl.nextUp(c).map { $0.hasPrefix("Next up: Ops") }, true, "end moved 10 min later")
        now += 0
    }

    func testClosedCardForgetsLine() {
        let ctl = controller()
        ctl.pollResult([nxt("n", "Ops", after: 5)])
        let c = ctl.showCard(card)
        XCTAssertNotNil(ctl.nextUp(c))
        ctl.closeCard(c)
        XCTAssertNil(ctl.nextUp(c))
    }

    func testCardHeightAndOffsets() {
        XCTAssertEqual(CardLayout.cardHeight(nextUp: false), CardLayout.H)
        XCTAssertEqual(CardLayout.cardHeight(nextUp: true), CardLayout.H + 18)
        XCTAssertEqual(CardLayout.stackOffset(below: []), 0)
        XCTAssertEqual(CardLayout.stackOffset(below: [true, false]), CardLayout.H * 2 + 18 + 2 * CardLayout.gap)
        let o = CardLayout.panelOrigin(offset: 0, minY: 80, maxX: 1512)
        let p = CardLayout.panelOrigin(index: 0, minY: 80, maxX: 1512)
        XCTAssertEqual(o.x, p.x); XCTAssertEqual(o.y, p.y)
    }
}
