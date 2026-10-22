import XCTest
@testable import MeetingCardCore

/// Port of tests/test_events.py.
final class EventsTests: XCTestCase {
    func testWorkingLocationAllDaySkipped() { XCTAssertEqual(Timing.skipReason(fx("working_location")), "all-day") }
    func testMeetKept() { XCTAssertNil(Timing.skipReason(fx("meet"))) }
    func testDeclinedSkipped() { XCTAssertEqual(Timing.skipReason(fx("declined")), "declined") }

    func testOffsetWinsOverTimeZoneField() {
        let s = Timing.times(fx("declined"))!.start
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 6; c.hour = 17
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        XCTAssertEqual(s, cal.date(from: c))
    }

    func testCancelledAndTypes() {
        var ev = fx("meet"); ev.status = "cancelled"
        XCTAssertEqual(Timing.skipReason(ev), "cancelled")
        for t in ["focusTime", "outOfOffice", "workingLocation"] {
            var e = fx("meet"); e.eventType = t
            XCTAssertEqual(Timing.skipReason(e), "eventType=" + t)
        }
    }

    func testLinks() {
        XCTAssertEqual(Links.joinLink(fx("meet")), VideoLink("meet", "https://meet.google.com/abc-defg-hij"))
        var ev = fx("meet"); ev.hangoutLink = nil
        XCTAssertEqual(Links.joinLink(ev), VideoLink("meet", "https://meet.google.com/abc-defg-hij"))
        XCTAssertEqual(Links.joinLink(fx("zoom")), VideoLink("zoom", "https://example.zoom.us/j/1234567890?pwd=abc123"))
        var z = fx("zoom"); z.description = "https://agency.zoomgov.com/j/161234567"
        XCTAssertEqual(Links.joinLink(z), VideoLink("zoom", "https://agency.zoomgov.com/j/161234567"))
        let t = Links.joinLink(fx("teams"))!
        XCTAssertTrue(t.provider == "teams" && t.url.hasPrefix("https://teams.microsoft.com/l/meetup-join/"))
        XCTAssertNil(Links.joinLink(fx("none")))
    }

    func testFormatEnds() {
        // Fixed zone injected (Python used the Mac's local zone; same assertion shape).
        let tz = TimeZone(identifier: "America/Chicago")!
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        func at(_ h: Int, _ m: Int) -> Date {
            var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 6; c.hour = h; c.minute = m
            return cal.date(from: c)!
        }
        XCTAssertEqual(Timing.formatEnds(at(9, 55), timeZone: tz), "Ends 9:55 AM")
        XCTAssertEqual(Timing.formatEnds(at(12, 0), timeZone: tz), "Ends 12:00 PM")
        XCTAssertEqual(Timing.formatEnds(at(0, 30), timeZone: tz), "Ends 12:30 AM")
        XCTAssertEqual(Timing.formatEnds(at(23, 59), timeZone: tz), "Ends 11:59 PM")
        XCTAssertEqual(Timing.formatEnds(at(13, 5), timeZone: tz), "Ends 1:05 PM")
    }

    // ---- Swift-only (risk-driven)
    func testParseDTFractionalSecondsAndZ() {
        let a = Timing.parseDT("2026-10-06T17:00:00Z")!
        XCTAssertEqual(Timing.parseDT("2026-10-06T12:00:00-05:00"), a)
        XCTAssertEqual(Timing.parseDT("2026-10-06T17:00:00.500Z")!.timeIntervalSince(a), 0.5, accuracy: 1e-6)
        XCTAssertEqual(Timing.parseDT("2026-10-06T22:30:00+05:30"), a)
        XCTAssertNil(Timing.parseDT("2026-10-06T17:00:00"))   // naive: no offset
        XCTAssertNil(Timing.parseDT("garbage"))
        XCTAssertNil(Timing.parseDT("2026-02-30T10:00:00Z"))  // invalid day
    }

    func testBadDateTimeIsSkippedNotCrash() {
        var ev = fx("meet"); ev.start?.dateTime = "tomorrow-ish"
        XCTAssertEqual(Timing.skipReason(ev), "bad-dateTime")
        var e2 = fx("meet"); e2.end = nil
        XCTAssertEqual(Timing.skipReason(e2), "no-dateTime")
    }

    func testUnicodeDigitsSkippedNotCrash() {
        // codex P2: ICU \d matched Arabic-Indic digits, Int() returned nil, c.month! trapped.
        for bad in ["2026-\u{0661}\u{0660}-06T10:00:00Z", "\u{0662}026-10-06T10:00:00Z",
                    "2026-10-06T10:00:00+\u{0660}5:00", "2026-10-06T10:00:\u{0661}0Z"] {
            XCTAssertNil(Timing.parseDT(bad), bad)
            var ev = fx("meet"); ev.start?.dateTime = bad
            XCTAssertEqual(Timing.skipReason(ev), "bad-dateTime", bad)
        }
    }

    func testOutOfRangeFieldsRejectedLikeFromisoformat() {
        // codex P2: Calendar normalized these (month 13 -> next Jan) instead of failing.
        for bad in ["2026-13-01T10:00:00Z", "2026-10-06T10:60:00Z", "2026-10-06T10:00:60Z",
                    "2026-10-06T24:00:00Z", "2026-00-01T10:00:00Z", "2026-10-00T10:00:00Z"] {
            XCTAssertNil(Timing.parseDT(bad), bad)
            var ev = fx("meet"); ev.start?.dateTime = bad
            XCTAssertEqual(Timing.skipReason(ev), "bad-dateTime", bad)
        }
        XCTAssertNotNil(Timing.parseDT("2026-12-31T23:59:59Z"))
    }

    func testEmptySummaryRendersNoTitle() {
        var ev = fx("meet"); ev.summary = ""
        XCTAssertEqual(CardModel(ev).title, "(No title)")
        ev.summary = nil
        XCTAssertEqual(CardModel(ev).title, "(No title)")
    }

    func testMalformedItemSkippedNotPollFailure() throws {
        let body = #"{"items": [{"id": "ok1", "summary": "x"}, {"id": "bad1", "attendees": "nope"}, 7]}"#
        let logs = LogBox()
        let items = try gws(FakeRunner(out: body), logs).fetch()
        XCTAssertEqual(items?.map { $0.id }, ["ok1"])
        XCTAssertTrue(logs.lines.contains { $0.contains("bad1") })
        XCTAssertFalse(logs.lines.joined().contains("nope"))
    }

    func testUnicodeWordCharsMatchPython() {
        // Python 3 `\w` on str is Unicode-aware; ICU's is too.
        XCTAssertEqual(Links.joinLink(Event(description: "PMR https://zoom.us/my/jos\u{e9}.r\u{f6}om end")),
                       VideoLink("zoom", "https://zoom.us/my/jos\u{e9}.r\u{f6}om"))
    }

    func testHTMLUnescapeTable() {
        // Deliberately MINIMAL table (README: Known divergences). Rare/uppercase named entities
        // (&AMP; &colon; &sol;) and HTML5 numeric remaps (&#128;) stay undecoded, unlike Python.
        XCTAssertEqual(HTML.unescape("a&amp;b&lt;c&gt;d&quot;e&#39;f&apos;g&nbsp;h"), "a&b<c>d\"e'f'g\u{a0}h")
        XCTAssertEqual(HTML.unescape("&#8212;&#x2014;&#X2014;&#233"), "\u{2014}\u{2014}\u{2014}\u{e9}")
        XCTAssertEqual(HTML.unescape("&ampsa=D &copy; &bogus; & x"), "&sa=D &copy; &bogus; & x")
        XCTAssertEqual(HTML.unescape("&#0;"), "\u{FFFD}")
        XCTAssertEqual(HTML.unescape("&AMP; &colon; &sol;"), "&AMP; &colon; &sol;", "known limit, not parity")
    }

    func testAmpInsideTeamsAndZoomURLInHTMLDescriptionIsUnescapedInJoinURL() {
        // CTO ruling Q3: the URL Join opens is unescaped (Python parity).
        let t = "https://teams.microsoft.com/l/meetup-join/19%3ameeting_Q%40thread.v2/0?context=%7b%7d&x=1"
        let te = Event(description: "<a href=\"\(t.replacingOccurrences(of: "&", with: "&amp;"))\">Join</a>")
        XCTAssertEqual(Links.joinLink(te), VideoLink("teams", t))
        let z = "https://example.zoom.us/j/1234567890?pwd=abc.1&jst=2"
        let ze = Event(description: "<a href=\"\(z.replacingOccurrences(of: "&", with: "&amp;"))\">Zoom</a>")
        XCTAssertEqual(Links.joinLink(ze), VideoLink("zoom", z))
        XCTAssertEqual(CardModel(ze).link?.url, z)
    }
}
