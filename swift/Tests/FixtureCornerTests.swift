import XCTest
@testable import MeetingCardCore

/// Fixture (demo) cards sit bottom-LEFT and carry a "DEMO · " title prefix so they can never be
/// mistaken for (or overlap) a live card; live placement/title are unchanged.
final class FixtureCornerTests: XCTestCase {
    func testCornerByMode() {
        XCTAssertEqual(CardLayout.corner(fixture: false), .bottomRight)
        XCTAssertEqual(CardLayout.corner(fixture: true), .bottomLeft)
    }

    func testLiveOriginUnchanged() {
        let old = CardLayout.panelOrigin(offset: 30, minY: 80, maxX: 1512)
        let new = CardLayout.panelOrigin(offset: 30, minY: 80, minX: 0, maxX: 1512,
                                         corner: CardLayout.corner(fixture: false))
        XCTAssertEqual(new.x, old.x); XCTAssertEqual(new.y, old.y)
    }

    func testFixtureOriginBottomLeftSameMarginAndStack() {
        let o = CardLayout.panelOrigin(offset: 30, minY: 80, minX: 50, maxX: 1512,
                                       corner: CardLayout.corner(fixture: true))
        XCTAssertEqual(o.x, 50 + CardLayout.margin)   // card edge 14pt from the left edge
        XCTAssertEqual(o.y, CardLayout.panelOrigin(offset: 30, minY: 80, maxX: 1512).y)
    }

    func testDisplayTitle() {
        XCTAssertEqual(CardLayout.displayTitle("Standup", fixture: false), "Standup")
        XCTAssertEqual(CardLayout.displayTitle("Standup", fixture: true), "DEMO \u{00B7} Standup")
    }
}
