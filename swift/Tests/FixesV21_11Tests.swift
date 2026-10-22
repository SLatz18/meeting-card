import XCTest
@testable import MeetingCardCore

/// #11 review fixes (codex on c9adaed). Card A = fx("meet") 9:25-9:55 AM; B starts 10 min after A ends.
final class FixesV21_11Tests: XCTestCase {
    let a = fx("meet")
    var b: Event {
        var e = moved(fx("meet"), 40); e.id = "b"; e.summary = "Bravo"
        e.attendees = [Attendee(isSelf: true, responseStatus: "accepted")]
        return e
    }
    func ctl(_ gets: UnsafeMutablePointer<Int>? = nil) -> Coordinator<FakeCard> {
        Coordinator<FakeCard>(recheck: true, log: { _ in },
                              makeCard: { e, _, _ in FakeCard(e) },
                              spawnGet: { _, _ in gets?.pointee += 1 },
                              clock: { start(fx("meet")) }, mono: { 100 })
    }

    // MARK: P2-1 a cache change from a re-check refreshes Next up on EVERY card

    func testLiveCancelOfBClearsALineWithoutPoll() {
        let c = ctl()
        c.pollResult([a, b])
        let ca = c.showCard(a), cb = c.showCard(b)
        XCTAssertEqual(c.nextUp(ca)?.hasPrefix("Next up: Bravo"), true)
        var gone = b; gone.status = "cancelled"
        c.liveDone(cb, cb.rk.shouldStart(100)!, .event(gone))
        XCTAssertTrue(cb.closedCalled)
        XCTAssertNil(c.nextUp(ca), "B cancelled: A's line clears without a poll")
        XCTAssertEqual(ca.nextUps.last, .some(nil))
    }

    func testLiveRenameOfBRenamesALine() {
        let c = ctl()
        c.pollResult([a, b])
        let ca = c.showCard(a), cb = c.showCard(b)
        var renamed = b; renamed.summary = "Bravo 2"
        c.liveDone(cb, cb.rk.shouldStart(100)!, .event(renamed))
        XCTAssertEqual(c.nextUp(ca)?.hasPrefix("Next up: Bravo 2 @"), true)
    }

    func testPrefireCancelOfBClearsALine() {
        var gets = 0
        let c = ctl(&gets)
        c.pollResult([a, b])
        let ca = c.showCard(a)
        XCTAssertNotNil(c.nextUp(ca))
        let due = c.sched.due(start(b))
        XCTAssertEqual(due.map { $0.id }, ["b"])
        var gone = b; gone.status = "cancelled"
        c.prefireDone(b, .event(gone), token: c.sched.token(b))
        XCTAssertNil(c.nextUp(ca), "pre-fire skip replaced the cached B: A's line clears")
        XCTAssertEqual(gets, 0, "no extra gws calls")
    }

    func testUnchangedRecheckDeliversNothingNew() {
        let c = ctl()
        c.pollResult([a, b])
        let ca = c.showCard(a), cb = c.showCard(b)
        let n = ca.nextUps.count
        var later = b; later.end?.dateTime = "2026-10-06T10:45:00-05:00"   // B's end moved: A's line same
        c.liveDone(cb, cb.rk.shouldStart(100)!, .event(later))
        XCTAssertEqual(ca.nextUps.count, n, "change-only delivery")
    }

    // MARK: P2-2 a resize is a placement for the KeyGate

    /// A card wired like the App's: place() feeds `.placed(cursor:)` through KeyGate.step/apply.
    final class GateCard: CardHandle, KeySurface {
        var ev: Event; let rk = Rechecker(now: 0)
        var gate = KeyGate(hoverKeys: true)
        var cursor: () -> KeyGate.Point
        var calls: [String] = []
        init(_ ev: Event, cursor: @escaping () -> KeyGate.Point) {
            self.ev = ev; self.cursor = cursor
            KeyGate.apply(gate.step(.appear(cursor: cursor())), to: self)
        }
        func close() {}
        func place(_ s: CardSlot) { KeyGate.apply(gate.step(.placed(cursor: cursor())), to: self) }
        func setNextUp(_ line: NextUp.Parts?) {}
        func refresh(_ ev: Event, now: Date) { self.ev = ev }
        func setNow(_ now: Date) {}
        func setOpening(_ on: Bool) {}
        func makeKey() { calls.append("makeKey") }
        func releaseKey() { calls.append("releaseKey") }
        func cancelGiveBack() { calls.append("cancelGiveBack") }
    }

    func testGrowUnderUnmovedCursorArmsNoKeys() {
        var cur = KeyGate.Point(x: 1000, y: 100)
        var made: [GateCard] = []
        let c = Coordinator<GateCard>(recheck: false, log: { _ in },
                                      makeCard: { e, _, _ in let g = GateCard(e, cursor: { cur }); made.append(g); return g },
                                      spawnGet: { _, _ in })
        c.pollResult([])
        let card = c.showCard(a)
        cur = KeyGate.Point(x: 1000, y: 230)            // Scott parks the cursor just above the card
        c.pollResult([a, b])                            // card A grows 18pt up under the resting cursor
        XCTAssertNotNil(c.nextUp(card))
        KeyGate.apply(card.gate.step(.hoverEnter(cursor: cur, inCard: true)), to: card)   // AppKit enter
        XCTAssertFalse(card.gate.armed, "grow under an unmoved cursor: no keys")
        XCTAssertEqual(card.calls, [])
        KeyGate.apply(card.gate.step(.moved(cursor: KeyGate.Point(x: 1001, y: 230), inCard: true)), to: card)
        XCTAssertTrue(card.gate.armed, "a real movement still arms")
        c.pollResult([a])                               // shrink while armed = placement: keys go back
        XCTAssertFalse(card.gate.armed)
        XCTAssertEqual(card.calls.last, "releaseKey")
    }

    // MARK: P2-3 click hit-testing uses the card's CURRENT height

    func testTallCardClickInAddedBandArms() {
        let h = CardLayout.cardHeight(nextUp: true)
        XCTAssertEqual(h, 144)
        XCTAssertTrue(CardLayout.cardContains(x: 200, y: 135, height: h), "the added 18pt arms by click")
        XCTAssertFalse(CardLayout.cardContains(x: 200, y: 145, height: h), "beyond the card: no")
        XCTAssertFalse(CardLayout.cardContains(x: 200, y: 135, height: CardLayout.H), "a 126pt card: still no")
        XCTAssertTrue(CardLayout.cardContains(x: 200, y: 100), "default = base height")
    }
}
