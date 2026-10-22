import XCTest
@testable import MeetingCardCore

/// Issue #13: video cards + "No video link" cards for others' link-less, location-less invites.
final class NoVideoTests: XCTestCase {
    /// A timed event with no video link (from the meet fixture, links stripped).
    func bare(organizerSelf: Bool?, location: String? = nil, organizer: Bool = true) -> Event {
        var ev = fx("meet")
        ev.id = "nv1"
        ev.hangoutLink = nil
        ev.conferenceData = nil
        ev.description = nil
        ev.location = location
        ev.htmlLink = "https://www.google.com/calendar/event?eid=nv1"
        ev.organizer = organizer ? Organizer(isSelf: organizerSelf, email: "o@example.com") : nil
        return ev
    }

    // (a) self-organized, no link -> skip no-video
    func testSelfNoLinkSkipped() {
        XCTAssertNil(Timing.cardKind(bare(organizerSelf: true)))
        XCTAssertEqual(Timing.skipReason(bare(organizerSelf: true)), "no-video")
    }

    // (b) other organizer, no link, no location -> No video link card
    func testOtherNoLinkNoLocationCard() {
        let ev = bare(organizerSelf: false)
        XCTAssertEqual(Timing.cardKind(ev), .noLink)
        XCTAssertNil(Timing.skipReason(ev))
        let m = CardModel(ev)
        XCTAssertEqual(m.flag, "No video link")
        XCTAssertEqual(m.buttonTitle, "Open in Calendar")
        XCTAssertEqual(m.link?.url, ev.htmlLink)
        XCTAssertFalse(m.multi)
    }

    // (c) other, no link, with a location -> skip
    func testOtherNoLinkWithLocationSkipped() {
        XCTAssertEqual(Timing.skipReason(bare(organizerSelf: false, location: "Room 5")), "no-video")
    }

    // (d) whitespace-only location counts as blank
    func testWhitespaceLocationIsBlank() {
        XCTAssertEqual(Timing.cardKind(bare(organizerSelf: false, location: " \t\n ")), .noLink)
    }

    // (e) organizer missing / self missing -> someone else
    func testMissingOrganizerIsSomeoneElse() {
        XCTAssertEqual(Timing.cardKind(bare(organizerSelf: nil, organizer: false)), .noLink)
        XCTAssertEqual(Timing.cardKind(bare(organizerSelf: nil)), .noLink)
    }

    // (f) noLink + no htmlLink -> flag, no button
    func testNoLinkWithoutHtmlLinkHasNoButton() {
        var ev = bare(organizerSelf: false)
        ev.htmlLink = ""
        let m = CardModel(ev)
        XCTAssertEqual(m.flag, "No video link")
        XCTAssertNil(m.link)
        XCTAssertNil(m.buttonTitle)
    }

    // htmlLink alone is never a video link
    func testHtmlLinkIsNotAVideoLink() {
        var ev = bare(organizerSelf: true)
        ev.htmlLink = "https://meet.google.com/abc-defg-hij"
        XCTAssertEqual(Timing.skipReason(ev), "no-video")
    }

    // (l) 1 link / 2+ links unchanged
    func testVideoKindsUnchanged() {
        var one = fx("meet"); one.organizer = Organizer(isSelf: true)
        XCTAssertEqual(Timing.cardKind(one), .join(VideoLink("meet", "https://meet.google.com/abc-defg-hij")))
        XCTAssertNil(CardModel(one).flag)
        XCTAssertEqual(CardModel(one).buttonTitle, "Join Meet")
        var two = fx("multilink"); two.organizer = Organizer(isSelf: true)
        if case .multi(let ls) = Timing.cardKind(two) { XCTAssertGreaterThanOrEqual(ls.count, 2) } else { XCTFail("multi") }
        XCTAssertNotNil(CardModel(two).flag)
    }

    // (k) earlier skips keep their reason
    func testEarlierSkipsWin() {
        var ev = bare(organizerSelf: true); ev.status = "cancelled"
        XCTAssertEqual(Timing.skipReason(ev), "cancelled")
        XCTAssertEqual(Timing.skipReason(fx("working_location")), "all-day")
        XCTAssertEqual(Timing.skipReason(fx("declined")), "declined")
    }

    func testOrganizerDecodes() {
        let ev = try! Event.decode(Data(#"{"organizer": {"email": "me@x.com", "self": true}}"#.utf8))
        XCTAssertEqual(ev.organizer?.isSelf, true)
        XCTAssertEqual(ev.organizer?.email, "me@x.com")
    }

    func testListPollDropsNoVideo() {
        let logs = LogBox()
        let s = Scheduler(log: { logs.add($0) })
        s.update([bare(organizerSelf: true), bare(organizerSelf: false, location: "HQ")])
        XCTAssertEqual(s.cache.count, 0)
        XCTAssertTrue(logs.lines.contains("skip nv1: no-video"))
    }

    // MARK: live flips (coordinator)

    typealias Rig = CoordinatorTests.Rig

    func liveCard(_ ev: Event) -> Rig {
        let r = Rig(now: start(ev) - 2 * M)
        r.ctl.pollResult([ev]); r.ctl.tick()
        r.gets.last!.1(.event(ev))
        XCTAssertEqual(r.ctl.cards.count, 1)
        r.advance(10); r.ctl.tick()
        return r
    }

    // (g) link added in flight -> update, model becomes Join
    func testLinkAddedFlipsNoLinkToJoin() {
        let ev = bare(organizerSelf: false)
        let r = liveCard(ev)
        var withLink = ev; withLink.hangoutLink = "https://meet.google.com/abc-defg-hij"
        r.gets.last!.1(.event(withLink))
        XCTAssertEqual(r.ctl.cards.count, 1)
        XCTAssertEqual(r.made[0].refreshed.count, 1)
        XCTAssertEqual(CardModel(r.made[0].ev).buttonTitle, "Join Meet")
        XCTAssertNil(CardModel(r.made[0].ev).flag)
    }

    // (h) link removed, rule 2 holds -> update to No video link
    func testLinkRemovedFlipsToNoLink() {
        var ev = fx("meet"); ev.organizer = Organizer(isSelf: false)
        ev.htmlLink = "https://www.google.com/calendar/event?eid=x"
        let r = liveCard(ev)
        var gone = ev; gone.hangoutLink = nil; gone.conferenceData = nil
        r.gets.last!.1(.event(gone))
        XCTAssertEqual(r.ctl.cards.count, 1)
        XCTAssertFalse(r.made[0].closedCalled)
        XCTAssertEqual(CardModel(r.made[0].ev).flag, "No video link")
    }

    // (i) link removed, self-organized -> close; key unfired so a re-added link can fire again
    func testLinkRemovedSelfCloses() {
        var ev = fx("meet"); ev.organizer = Organizer(isSelf: true)
        let r = liveCard(ev)
        var gone = ev; gone.hangoutLink = nil; gone.conferenceData = nil
        r.gets.last!.1(.event(gone))
        XCTAssertEqual(r.ctl.cards.count, 0)
        XCTAssertTrue(r.made[0].closedCalled)
        XCTAssertFalse(r.ctl.sched.fired.contains(Timing.key(ev)), "no-video close is not fired")
        // link re-added: next list poll re-offers it inside the appear window
        let before = r.gets.count
        r.ctl.pollResult([ev]); r.advance(1); r.ctl.tick()
        XCTAssertEqual(r.gets.count, before + 1, "re-offered after the poll")
        guard r.gets.count == before + 1 else { return }
        r.gets.last!.1(.event(ev))
        XCTAssertEqual(r.ctl.cards.count, 1)
        XCTAssertEqual(r.made.count, 2)
    }

    // (i') link removed, other organizer but has a location -> close
    func testLinkRemovedWithLocationCloses() {
        var ev = fx("meet"); ev.organizer = Organizer(isSelf: false); ev.location = "Room 5"
        let r = liveCard(ev)
        var gone = ev; gone.hangoutLink = nil; gone.conferenceData = nil
        r.gets.last!.1(.event(gone))
        XCTAssertEqual(r.ctl.cards.count, 0)
    }

    // (j) pre-fire no-video: fresh copy cached + never offered (no per-tick gets) until the next good list poll, then fires
    func testPrefireNoVideoParksThenFiresAfterPoll() {
        var ev = fx("meet"); ev.organizer = Organizer(isSelf: true)
        let r = Rig(now: start(ev) - 2 * M)
        r.ctl.pollResult([ev]); r.ctl.tick()
        XCTAssertEqual(r.gets.count, 1)
        var gone = ev; gone.hangoutLink = nil; gone.conferenceData = nil
        r.gets[0].1(.event(gone))
        XCTAssertEqual(r.ctl.cards.count, 0)
        XCTAssertFalse(r.ctl.sched.fired.contains(Timing.key(ev)))
        for _ in 0..<59 { r.advance(1); r.ctl.tick() }
        XCTAssertEqual(r.gets.count, 1, "no gets until the next list poll")
        r.ctl.pollResult(nil); r.advance(1); r.ctl.tick()
        XCTAssertEqual(r.gets.count, 1, "a FAILED poll does not re-offer")
        r.ctl.pollResult([ev]); r.advance(1); r.ctl.tick()  // link back in the list
        XCTAssertEqual(r.gets.count, 2, "one get after the poll")
        guard r.gets.count == 2 else { return }
        r.gets[1].1(.event(ev))
        XCTAssertEqual(r.ctl.cards.count, 1)
    }

    // other pre-fire skips still mark fired (unchanged)
    func testPrefireCancelledStillFired() {
        let ev = fx("meet")
        let r = Rig(now: start(ev) - 2 * M)
        r.ctl.pollResult([ev]); r.ctl.tick()
        var c = ev; c.status = "cancelled"
        r.gets[0].1(.event(c))
        XCTAssertTrue(r.ctl.sched.fired.contains(Timing.key(ev)))
    }
}
