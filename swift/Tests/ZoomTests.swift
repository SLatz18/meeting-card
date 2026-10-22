import XCTest
@testable import MeetingCardCore

/// Port of tests/test_zoom.py.
final class ZoomTests: XCTestCase {
    func testZoomFromConferenceDataAddon() {
        XCTAssertEqual(Links.joinLink(fx("zoom_addon")), VideoLink("zoom", "https://example.zoom.us/j/99999999999?pwd=abc.1&jst=2"))
    }
    func testMeetOnlyStillMeet() { XCTAssertEqual(Links.joinLink(fx("meet"))?.provider, "meet") }
    func testZoomInDescription() { XCTAssertEqual(Links.joinLink(fx("zoom"))?.provider, "zoom") }

    func testZoomLabel() {
        // Icon half of the Python test is AppKit drawing: checked in the 2b snapshot step.
        XCTAssertEqual(Links.labels["zoom"], "Join Zoom")
        XCTAssertEqual(CardModel(fx("zoom")).buttonTitle, "Join Zoom")
    }

    func testLookalikeHostIsNotZoom() {
        var ev = fx("zoom_location_plus_meet")
        ev.location = "https://notzoom.us/j/11111111111"
        ev.description = "see https://evilzoom.com/j/22222222222"
        XCTAssertEqual(Links.joinLink(ev)?.provider, "meet")
        XCTAssertNil(Links.joinLink(Event(description: "https://notzoom.us/j/1")))
    }

    func testRealZoomSubdomainsStillMatch() {
        XCTAssertEqual(Links.joinLink(Event(location: "https://acmecorp.zoom.us/j/94445556667?pwd=a.1&jst=2"))?.provider, "zoom")
        XCTAssertEqual(Links.joinLink(Event(description: "x https://zoom.us/j/123 y"))?.provider, "zoom")
        XCTAssertEqual(Links.joinLink(Event(description: "x https://agency.zoomgov.com/j/161 y"))?.provider, "zoom")
    }

    func testZoomOnlyInviteStillGetsJoin() {
        XCTAssertEqual(Links.joinLink(fx("zoom_addon"))?.provider, "zoom")
        XCTAssertEqual(Links.joinLink(fx("zoom"))?.provider, "zoom")
    }

    func testZoomURLStopsAtDelimiters() {
        XCTAssertEqual(Links.joinLink(Event(description: "a https://zoom.us/j/123?pwd=x.1&jst=2, then"))?.url,
                       "https://zoom.us/j/123?pwd=x.1&jst=2")
        let t = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_Ab%40thread.v2/0?context=%7b%22Tid%22%7d"
        XCTAssertEqual(Links.joinLink(Event(location: t + ", room 4"))?.url, t)
    }

    func testNonMeetingLocationDoesNotAddALink() {
        var ev = fx("meet")
        for loc in ["Conf Room 4B", "100 Main St, Springfield", "https://docs.google.com/document/d/abc/edit", "https://notzoom.us/j/111"] {
            ev.location = loc
            XCTAssertEqual(Links.joinLink(ev), VideoLink("meet", ev.hangoutLink!), loc)
        }
    }

    func testWebexSingle() {
        XCTAssertEqual(Links.joinLink(Event(location: "Webex: https://acme.webex.com/meet/jdoe")),
                       VideoLink("webex", "https://acme.webex.com/meet/jdoe"))
        XCTAssertEqual(Links.labels["webex"], "Join Webex")
    }
}
