import XCTest
@testable import MeetingCardCore

/// #13 review (codex P2 x4): the fresh single-event result wins the cache, due() never offers a
/// skipped cached copy, a live no-video close unfires every key for the id, and pre-fire replies
/// must match the request token. Each test replays codex's exact sequence.
final class NoVideoCacheTests: XCTestCase {
    typealias Rig = CoordinatorTests.Rig

    func selfMeet() -> Event { var ev = fx("meet"); ev.organizer = Organizer(isSelf: true); return ev }
    func noLink(_ ev: Event) -> Event { var e = ev; e.hangoutLink = nil; e.conferenceData = nil; return e }

    /// Tick n seconds, answering every new get with `reply`.
    func run(_ r: Rig, _ n: Int, reply: GetOutcome) {
        for _ in 0..<n {
            r.advance(1)
            let before = r.gets.count
            r.ctl.tick()
            for g in r.gets[before...] { g.1(reply) }
        }
    }

    func liveCard(_ ev: Event) -> Rig {
        let r = Rig(now: start(ev) - 2 * M)
        r.ctl.pollResult([ev]); r.ctl.tick()
        r.gets.last!.1(.event(ev))
        XCTAssertEqual(r.ctl.cards.count, 1)
        r.advance(10); r.ctl.tick()
        return r
    }

    /// Advance until the live card issues its next re-check get.
    func nextLiveGet(_ r: Rig) {
        let before = r.gets.count
        for _ in 0..<60 where r.gets.count == before { r.advance(1); r.ctl.tick() }
        XCTAssertEqual(r.gets.count, before + 1, "live re-check issued")
    }

    // Finding 1: live no-video close, then a FAILED get must not show the discarded Join card.
    func testFailedGetAfterNoVideoCloseShowsNoCard() {
        let ev = selfMeet()
        let r = liveCard(ev)
        r.gets.last!.1(.event(noLink(ev)))
        XCTAssertEqual(r.ctl.cards.count, 0)
        let gets = r.gets.count
        run(r, 30, reply: .failed)
        XCTAssertEqual(r.ctl.cards.count, 0, "failed get after a no-video close shows NO card")
        XCTAssertEqual(r.made.count, 1)
        XCTAssertEqual(r.gets.count, gets, "no gets until a successful poll")
    }

    // Finding 2: a poll moves the start while the pre-fire get is pending; the no-video reply must
    // cover the NEW key too (no second get, no excluded card on a failed get).
    func testPollMovesStartWhileGetPending() {
        let ev = selfMeet()
        let r = Rig(now: start(ev) - 2 * M)
        r.ctl.pollResult([ev]); r.ctl.tick()
        XCTAssertEqual(r.gets.count, 1)
        let ev2 = moved(ev, -1)  // still inside the appear window
        r.ctl.pollResult([ev2]); r.advance(1); r.ctl.tick()
        XCTAssertEqual(r.gets.count, 1, "same id pending: no second get")
        r.gets[0].1(.event(noLink(ev2)))
        run(r, 30, reply: .failed)
        XCTAssertEqual(r.gets.count, 1, "moved key not eligible after a no-video reply")
        XCTAssertEqual(r.ctl.cards.count, 0)
    }

    // Finding 3: a late reply after the timeout fallback must not resolve a NEWER request.
    func testLateReplyCannotResolveNewerRequest() {
        let ev = selfMeet()
        let r = Rig(now: start(ev) - 2 * M)
        r.ctl.pollResult([ev]); r.ctl.tick()
        let late = r.gets[0].1
        r.advance(Scheduler.pendingMax + 1); r.ctl.tick()  // stale -> fallback shows cached card
        XCTAssertEqual(r.ctl.cards.count, 1)
        nextLiveGet(r)
        r.gets.last!.1(.event(noLink(ev)))                 // live no-video close
        XCTAssertEqual(r.ctl.cards.count, 0)
        r.ctl.pollResult([ev]); r.advance(1); r.ctl.tick() // link restored -> newer request
        let newer = r.gets.count - 1
        XCTAssertEqual(r.gets[newer].0, ev.id)
        late(.event(ev))                                   // superseded reply: dropped
        XCTAssertEqual(r.ctl.cards.count, 0, "late reply must not resurrect a card")
        r.gets[newer].1(.event(ev))
        XCTAssertEqual(r.ctl.cards.count, 1, "newer reply is not dropped")
    }

    // Finding 4: rekey A->B, no-video close at B, restore link + start A: A must fire again.
    func testNoVideoCloseUnfiresEveryKeyForTheId() {
        let a = selfMeet()
        let r = liveCard(a)
        let b = moved(a, -1)
        r.gets.last!.1(.event(b))  // live update: rekey A -> B
        XCTAssertEqual(r.ctl.cards.count, 1)
        XCTAssertEqual(r.ctl.cards[0].ev.start?.dateTime, b.start?.dateTime)
        nextLiveGet(r)
        r.gets.last!.1(.event(noLink(b)))
        XCTAssertEqual(r.ctl.cards.count, 0)
        let before = r.gets.count
        r.ctl.pollResult([a]); r.advance(1); r.ctl.tick()
        XCTAssertEqual(r.gets.count, before + 1, "start A re-offered after the poll")
        guard r.gets.count == before + 1 else { return }
        r.gets.last!.1(.event(a))
        XCTAssertEqual(r.ctl.cards.count, 1)
    }

    // No-spam bound: a list that keeps claiming a link the get denies costs ONE get per poll.
    func testAtMostOneGetPerSuccessfulPoll() {
        let ev = selfMeet()
        let r = Rig(now: start(ev) - 2 * M)
        r.ctl.pollResult([ev]); r.ctl.tick()
        r.gets[0].1(.event(noLink(ev)))
        for round in 1...3 {
            run(r, 20, reply: .event(noLink(ev)))
            XCTAssertEqual(r.gets.count, round, "no gets between polls")
            r.ctl.pollResult(nil)
            run(r, 5, reply: .event(noLink(ev)))
            XCTAssertEqual(r.gets.count, round, "a failed poll buys no get")
            r.ctl.pollResult([ev])
            run(r, 20, reply: .event(noLink(ev)))
            XCTAssertEqual(r.gets.count, round + 1, "exactly one get after a successful poll")
        }
        XCTAssertEqual(r.ctl.cards.count, 0)
    }
}
