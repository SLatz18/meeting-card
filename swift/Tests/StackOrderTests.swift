import XCTest
@testable import MeetingCardCore

/// #8: stacked cards sort by a fixed key (start, then title, then id) so same-start cards
/// can't shuffle on re-stack. Index 0 = bottom (closest to the corner).
final class StackOrderTests: XCTestCase {
    func ev(_ id: String, _ title: String, _ shift: Double = 0) -> Event {
        var e = moved(fx("meet"), shift); e.id = id; e.summary = title; return e
    }
    func order(_ ctl: Coordinator<FakeCard>) -> [String] { ctl.cards.map { $0.ev.id ?? "nil" } }

    func testSameStartSortsByTitleWhicheverFiresFirst() {
        for flip in [false, true] {
            let ctl = controller()
            let a = ev("z-id", "Alpha"), b = ev("a-id", "Bravo")
            for e in flip ? [a, b] : [b, a] { ctl.showCard(e) }
            XCTAssertEqual(order(ctl), ["z-id", "a-id"], "title order, flip=\(flip)")
        }
    }

    func testSameStartSameTitleSortsById() {
        let ctl = controller()
        ctl.showCard(ev("id-2", "Same")); ctl.showCard(ev("id-1", "Same"))
        XCTAssertEqual(order(ctl), ["id-1", "id-2"])
    }

    func testStartBeatsTitle() {
        let ctl = controller()
        ctl.showCard(ev("late", "Alpha", 1)); ctl.showCard(ev("early", "Zulu", 0))
        XCTAssertEqual(order(ctl), ["early", "late"])
    }

    func testNewCardSlidingBelowRePlacesOnlyMovedCards() {
        var madeAt: [String: CardSlot] = [:]
        let ctl = Coordinator<FakeCard>(recheck: false, log: { _ in },
                                        makeCard: { e, slot, _ in madeAt[e.id!] = slot; return FakeCard(e) },
                                        spawnGet: { _, _ in })
        let b = ctl.showCard(ev("b", "Bravo"))
        let c = ctl.showCard(ev("c", "Charlie"))
        XCTAssertEqual(b.placed, [], "already in its slot: no re-place (a re-place disarms keys)")
        XCTAssertEqual(c.placed, [], "created at its own slot")
        let a = ctl.showCard(ev("a", "Alpha"))
        XCTAssertEqual(madeAt["a"]?.index, 0, "new card is created directly in its sorted slot")
        XCTAssertEqual(a.placed, [], "no show-then-move")
        XCTAssertEqual(b.placed, [1]); XCTAssertEqual(c.placed, [2])
    }

    func testMovedStartUpdateReSorts() {
        let x = ev("x", "Xray", 0), y = ev("y", "Yankee", 1)
        var now = start(x)
        let ctl = Coordinator<FakeCard>(recheck: true, log: { _ in },
                                        makeCard: { e, _, _ in FakeCard(e) }, spawnGet: { _, _ in },
                                        clock: { now }, mono: { 100 })
        let cx = ctl.showCard(x); ctl.showCard(y)
        XCTAssertEqual(order(ctl), ["x", "y"])
        // Live recheck: x moved +2 min (start - lead == now) -> .update, so x now starts after y.
        let g = cx.rk.shouldStart(100)!
        ctl.liveDone(cx, g, .event(moved(x, 2)))
        XCTAssertEqual(cx.ev.start?.dateTime, moved(x, 2).start?.dateTime, "update applied")
        XCTAssertEqual(order(ctl), ["y", "x"])
        XCTAssertEqual(cx.placed, [1])
        now += 0
    }

    func testStackOrderKeyNilsSortAsEmpty() {
        var a = ev("b", "T"); a.summary = nil
        let b = ev("a", "T")
        XCTAssertTrue(Coordinator<FakeCard>.stackOrder(a, b), "nil title sorts as empty, before T")
    }
}
