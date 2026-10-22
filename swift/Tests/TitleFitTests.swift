import XCTest
@testable import MeetingCardCore

/// v2.5 #4: a long card title cut off with no ellipsis and hid the countdown suffix. Only the
/// TITLE (incl. the fixture "DEMO · " prefix) truncates; " <countdown>" always shows whole.
final class TitleFitTests: XCTestCase {
    let chars: (String) -> Double = { Double($0.count) }

    func testLongTitleKeepsSuffixAndEllipsizesTitle() {
        let long = String(repeating: "mc-v24 Meet: click Join, wiggle mouse in+out ", count: 3).prefix(120)
        XCTAssertEqual(long.count, 120)
        for s in ["now", "in 2 min"] {
            let f = CardLayout.fitTitle(String(long), fixture: false, suffix: s, width: 40, measure: chars)
            XCTAssertTrue(f.title.hasSuffix("\u{2026}"), f.title)
            XCTAssertEqual(f.suffix, " " + s)
            XCTAssertLessThanOrEqual(chars(f.title + f.suffix), 40)
            XCTAssertEqual(chars(f.title + f.suffix), 40, "uses the room it has")
            XCTAssertTrue(f.title.hasPrefix("mc-v24 Meet"))
        }
    }

    func testShortTitleUntouched() {
        let f = CardLayout.fitTitle("Ops", fixture: false, suffix: "in 2 min", width: 40, measure: chars)
        XCTAssertEqual(f.title, "Ops"); XCTAssertEqual(f.suffix, " in 2 min")
        let d = CardLayout.fitTitle("Ops", fixture: true, suffix: "now", width: 40, measure: chars)
        XCTAssertEqual(d.title, "DEMO \u{00B7} Ops")
    }

    func testDemoPrefixCountsAsTitle() {
        let f = CardLayout.fitTitle(String(repeating: "x", count: 120), fixture: true, suffix: "now", width: 30, measure: chars)
        XCTAssertTrue(f.title.hasPrefix("DEMO \u{00B7} x"), f.title)
        XCTAssertTrue(f.title.hasSuffix("\u{2026}"))
        XCTAssertEqual(chars(f.title + f.suffix), 30)
    }

    func testNewlineTitleIsOneLine() {
        let f = CardLayout.fitTitle("Release\nplanning\t\n  sync", fixture: false, suffix: "now", width: 200, measure: chars)
        XCTAssertEqual(f.title, "Release planning sync")
        let g = CardLayout.fitTitle(String(repeating: "Release planning\n", count: 8), fixture: false, suffix: "now", width: 40, measure: chars)
        XCTAssertFalse(g.title.contains { $0.isNewline || $0 == "\t" }, g.title)
        XCTAssertTrue(g.title.hasSuffix("\u{2026}"))
    }

    func testAppTitleUsesFitAndSingleLine() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/CardPanel.swift"))
        XCTAssertTrue(src.contains("CardLayout.fitTitle(model.title"))
        XCTAssertTrue(src.contains("titleLabel.maximumNumberOfLines = 1"))
        XCTAssertTrue(src.contains("titleLabel.usesSingleLineMode = true"))
    }
}
