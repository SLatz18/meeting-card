import XCTest
@testable import MeetingCardCore

/// #17 (Scott 10:18pm 2026-10-06): "Next up: <title> @ <time>", styled apart from the Ends line,
/// long titles truncate with an ellipsis so " @ <time>" always shows.
final class NextUpStyleTests: XCTestCase {
    let tz = TimeZone(secondsFromGMT: -5 * 3600)!
    let card = fx("meet")
    func nxt(_ title: String, after mins: Double) -> Event {
        var e = moved(card, 30 + mins); e.id = "n"; e.summary = title
        e.attendees = [Attendee(isSelf: true, responseStatus: "accepted")]; return e
    }
    func parts(_ e: Event) -> NextUp.Parts? { NextUp.parts(for: card, pool: [e], timeZone: tz) }
    /// One unit per character: a deterministic stand-in for the font metric.
    let chars: (String) -> Double = { Double($0.count) }

    func testFormatUsesAtSignAnd12Hour() {
        let p = parts(nxt("Team Standup", after: 10))!
        XCTAssertEqual(p.line, "Next up: Team Standup @ 10:05 AM")
        XCTAssertEqual(p.title, "Team Standup")
        XCTAssertEqual(p.suffix, " @ 10:05 AM")
        XCTAssertFalse(p.line.contains(" at "))
        XCTAssertEqual(parts(nxt("Late", after: 15 + 60 * 3))?.line, nil, "outside the window")
    }

    func testPMClock() {
        var c = card; c.id = "c"
        let late = moved(c, 4 * 60)   // 1:25-1:55 PM
        var n = moved(late, 40); n.id = "n"; n.summary = "Afternoon"
        n.attendees = [Attendee(isSelf: true, responseStatus: "accepted")]
        XCTAssertEqual(NextUp.parts(for: late, pool: [n], timeZone: tz)?.line, "Next up: Afternoon @ 2:05 PM")
    }

    func testOverlapsSuffixKeptAfterTime() {
        let p = parts(nxt("Ops", after: -10))!
        XCTAssertEqual(p.line, "Next up: Ops @ 9:45 AM, overlaps")
        XCTAssertEqual(p.suffix, " @ 9:45 AM, overlaps")
    }

    func testShortTitleUnchanged() {
        let p = parts(nxt("Ops", after: 10))!
        XCTAssertEqual(NextUp.fit(p, width: 100, measure: chars), p.line)
    }

    func testLongTitleTruncatesTitleNotTime() {
        let long = String(repeating: "Quarterly business review ", count: 8)
        let p = parts(nxt(long, after: -10))!
        let s = NextUp.fit(p, width: 50, measure: chars)
        XCTAssertLessThanOrEqual(s.count, 50)
        XCTAssertTrue(s.hasPrefix("Next up: Quarterly"))
        XCTAssertTrue(s.hasSuffix("\u{2026} @ 9:45 AM, overlaps"), s)
        XCTAssertEqual(s.count, 50, "uses the room it has")
        // Exactly-fits boundary: no ellipsis.
        XCTAssertEqual(NextUp.fit(p, width: chars(p.line), measure: chars), p.line)
        XCTAssertTrue(NextUp.fit(p, width: chars(p.line) - 1, measure: chars).hasSuffix("\u{2026} @ 9:45 AM, overlaps"))
    }

    func testNoRoomForTitleStillShowsTime() {
        let p = parts(nxt("Something long", after: 10))!
        XCTAssertEqual(NextUp.fit(p, width: 5, measure: chars), "Next up: \u{2026} @ 10:05 AM")
    }

    /// Distinct color from the Ends line (secondaryLabelColor), >= 4.5:1 on the card in both modes.
    /// Measured: light #0A5CC2 on #F4F4F4 = 5.75:1; dark #64A8FF on #2C2C2E = 5.70:1.
    func testNextUpColorContrast() {
        let l = CardPalette.for(dark: false), d = CardPalette.for(dark: true)
        XCTAssertEqual(l.nextUp, RGBA(hex: 0x0A5CC2))
        XCTAssertEqual(d.nextUp, RGBA(hex: 0x64A8FF))
        XCTAssertEqual(RGBA.contrast(l.nextUp, l.cardFill), 5.75, accuracy: 0.01)
        XCTAssertEqual(RGBA.contrast(d.nextUp, d.cardFill), 5.70, accuracy: 0.01)
        for p in [l, d] { XCTAssertGreaterThanOrEqual(RGBA.contrast(p.nextUp, p.cardFill), 4.5, "dark=\(p.dark)") }
    }

    /// App wiring (hostless tests can't run AppKit): the line uses the palette color and Core's fit.
    func testAppDrawsNextUpWithPaletteColorAndFit() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/CardPanel.swift"))
        XCTAssertTrue(src.contains("NextUp.fit(nextUp"))
        XCTAssertTrue(src.contains("Card.ns(palette.nextUp)"))
    }

    /// Codex P2 (0ef30ab): newlines in the title rendered multiline and hid " @ <time>".
    func testMultilineTitleCollapsesToOneLine() {
        let p = parts(nxt(String(repeating: "Release planning\n", count: 5), after: 10))!
        XCTAssertFalse(p.title.contains { $0.isNewline || $0 == "\t" }, p.title)
        XCTAssertFalse(p.title.contains("  "))
        XCTAssertEqual(p.title, Array(repeating: "Release planning", count: 5).joined(separator: " "))
        let s = NextUp.fit(p, width: 50, measure: chars)
        XCTAssertFalse(s.contains { $0.isNewline }); XCTAssertTrue(s.hasSuffix(" @ 10:05 AM"), s)
        XCTAssertEqual(parts(nxt(" \t\r\n ", after: 10))?.title, "(No title)")
    }

    func testAppNextUpLabelIsSingleLine() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/CardPanel.swift"))
        XCTAssertTrue(src.contains("maximumNumberOfLines = 1"))
    }
}
