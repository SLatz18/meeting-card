import XCTest
@testable import MeetingCardCore

/// Port of tests/test_multilink.py: dedupe by MEETING IDENTITY; 2+ distinct = flag.
final class MultilinkTests: XCTestCase {
    let zoomA = "https://acmecorp.zoom.us/j/91112223334?pwd=Abc.1&jst=2"
    func ep(_ t: String, _ u: String) -> EntryPoint { EntryPoint(entryPointType: t, uri: u) }

    func testMeetPlusDifferentZoomFlags() {
        let ev = fx("zoom_location_plus_meet")
        XCTAssertNil(Links.joinLink(ev))
        XCTAssertEqual(Links.videoLinks(ev).map { $0.provider }, ["zoom", "meet"])
    }

    func testZoomAddonRepeatedIsOne() {
        let ev = Event(location: zoomA,
                       conferenceData: ConferenceData(entryPoints: [
                           ep("video", zoomA), ep("phone", "tel:8339284609,,91112223334#"),
                           ep("sip", "sip:91112223334@zoomcrc.com"),
                           ep("more", "https://www.google.com/url?q=https://applications.zoom.us/addon/x")]),
                       description: "Join Zoom Meeting\nhttps://acmecorp.zoom.us/j/91112223334?pwd=Abc.1&jst=2\n"
                           + "Meeting ID: 911 1222 3334\nOne tap mobile +16699009128,,91112223334#")
        XCTAssertEqual(Links.videoLinks(ev), [VideoLink("zoom", zoomA)])
        XCTAssertEqual(Links.joinLink(ev), VideoLink("zoom", zoomA))
    }

    func testSameZoomAnySubdomainOrPwdIsOne() {
        let ev = Event(location: "https://zoom.us/j/91112223334",
                       description: "https://us02web.zoom.us/j/91112223334?pwd=zzz.9 and " + zoomA)
        XCTAssertEqual(Links.videoLinks(ev).count, 1)
    }

    func testMeetHangoutPlusSameMeetInDescriptionIsOne() {
        var ev = fx("meet")
        let url = ev.hangoutLink!
        ev.description = "Join with Google Meet: \(url.uppercased().replacingOccurrences(of: "HTTPS", with: "https"))\nOr dial: +1 470-839-8143 PIN: 453108780#"
        XCTAssertEqual(Links.videoLinks(ev).count, 1)
        XCTAssertEqual(Links.joinLink(ev), VideoLink("meet", url))
    }

    func testZoomWithDialInTextIsSingle() {
        let ev = Event(description: "Join: https://example.zoom.us/j/1234567890?pwd=abc\n"
                       + "Dial by your location +1 312 626 6799 US (Chicago)\ntel:+13126266799,,1234567890#")
        XCTAssertEqual(Links.joinLink(ev), VideoLink("zoom", "https://example.zoom.us/j/1234567890?pwd=abc"))
    }

    func testTwoDifferentZoomMeetingsFlag() {
        let ev = Event(location: "https://zoom.us/j/111111111", description: "new link: https://zoom.us/j/222222222")
        XCTAssertNil(Links.joinLink(ev)); XCTAssertEqual(Links.videoLinks(ev).count, 2)
    }

    func testTeamsSameJoinURLIsOneEvenHTMLEscaped() {
        let t = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_Ab%40thread.v2/0?context=%7b%22Tid%22%7d"
        let ev = Event(location: "Microsoft Teams Meeting",
                       conferenceData: ConferenceData(entryPoints: [ep("video", t)]),
                       description: "<a href=\"\(t.replacingOccurrences(of: "&", with: "&amp;"))\">Join</a> or paste \(t)")
        XCTAssertEqual(Links.joinLink(ev), VideoLink("teams", t))
    }

    func testTeamsPlusZoomFlags() {
        let t = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_Ab%40thread.v2/0"
        let ev = Event(location: t, description: "backup https://zoom.us/j/333333333")
        XCTAssertNil(Links.joinLink(ev)); XCTAssertEqual(Links.videoLinks(ev).count, 2)
    }

    func testNoLinksUnchanged() {
        XCTAssertEqual(Links.videoLinks(Event(location: "Conf Room 4B", description: "agenda https://docs.google.com/x")), [])
        XCTAssertNil(Links.joinLink(Event(location: "Conf Room 4B")))
    }

    // --- codex xhigh review of 3924b9e
    let teams = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_NzE3YTA5Ab%40thread.v2/0?context=%7b%22Tid%22%3a%2272%22%7d&amp;x=1"

    func testTeamsHTMLEscapedQueryAndGoogleRedirectDedupe() {
        let plain = teams.replacingOccurrences(of: "&amp;", with: "&")
        let wrapped = "https://www.google.com/url?q=https://teams.microsoft.com/l/meetup-join/19%253ameeting_NzE3YTA5Ab%2540thread.v2/0%3Fcontext%3D1"
            + "&amp;sa=D&amp;source=calendar"
        let ev = Event(location: "Microsoft Teams Meeting",
                       description: "<a href=\"\(teams)\">Join</a> \(plain) <a href=\"\(wrapped)\">x</a>")
        let link = Links.joinLink(ev)
        XCTAssertEqual(link?.provider, "teams")
        XCTAssertFalse(link!.url.contains("&amp"), link!.url)  // the URL Join opens must be unescaped
    }

    func testTeamsEquivalentPercentEncodingIsOne() {
        let a = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_Ab%40thread.v2/0"
        let b = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_%41b%40thread.v2/0"
        XCTAssertEqual(Links.videoLinks(Event(location: a, description: b)).count, 1)
    }

    func testTeamsPathsDifferingOnlyByCaseAreTwo() {
        let a = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_Ab%40thread.v2/0"
        let b = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_aB%40thread.v2/0"
        XCTAssertEqual(Links.videoLinks(Event(location: a, description: b)).count, 2)
    }

    func testZoomPersonalRoomAndWebinarCount() {
        var ev = fx("meet")
        ev.location = "https://acmecorp.zoom.us/my/jdoe"
        XCTAssertNil(Links.joinLink(ev)); XCTAssertEqual(Links.videoLinks(ev).count, 2)
        XCTAssertEqual(Links.joinLink(Event(description: "PMR https://zoom.us/my/jdoe.room")),
                       VideoLink("zoom", "https://zoom.us/my/jdoe.room"))
        XCTAssertEqual(Links.joinLink(Event(description: "webinar https://acme.zoom.us/w/98765432101?tk=abc"))?.provider, "zoom")
    }

    func testNonMeetingVideoEntryPointsIgnored() {
        var ev = fx("meet")
        for uri in ["https://notzoom.us/j/123", "https://applications.zoom.us/addon/x"] {
            ev.conferenceData = ConferenceData(entryPoints: [ep("video", ev.hangoutLink!), ep("video", uri)])
            XCTAssertEqual(Links.joinLink(ev), VideoLink("meet", ev.hangoutLink!), uri)
        }
    }

    func testMeetQueryVariantsAreOne() {
        var ev = fx("meet")
        let url = ev.hangoutLink!
        ev.description = "\(url)?authuser=0 and \(url)?hl=en&amp;pli=1"
        XCTAssertEqual(Links.joinLink(ev), VideoLink("meet", url))
    }

    // Card side of the flag: 2+ links -> calendar button + muted line; Python card.refresh.
    func testMultilinkCardModelOffersCalendar() {
        let m = CardModel(fx("multilink"))
        XCTAssertTrue(m.multi)
        XCTAssertEqual(m.link, VideoLink("calendar", "https://www.google.com/calendar/event?eid=TEST_MULTILINK"))
        XCTAssertEqual(m.buttonTitle, "Open in Calendar")
        XCTAssertEqual(m.flag, "2 video links in this invite")
        var noHtml = fx("multilink"); noHtml.htmlLink = nil
        XCTAssertNil(CardModel(noHtml).link)
        var emptyHtml = fx("multilink"); emptyHtml.htmlLink = ""
        XCTAssertNil(CardModel(emptyHtml).link, "empty htmlLink = no Open in Calendar button")
        XCTAssertEqual(CardModel(emptyHtml).flag, "2 video links in this invite")
        XCTAssertEqual(CardModel(fx("meet")).buttonTitle, "Join Meet")
        XCTAssertNil(CardModel(fx("none")).link)
    }
}
