import Foundation
import XCTest
@testable import MeetingCardCore

/// Provider-colored card outline: mapping from the REAL fixtures through CardModel.
final class CardBorderTests: XCTestCase {
    let aL = CardBorder.alphaLight, aD = CardBorder.alphaDark

    func cols(_ name: String, dark: Bool, enabled: Bool = true) -> [RGBA]? {
        CardBorder.colors(for: CardModel(fx(name)), dark: dark, enabled: enabled)
    }

    /// A webex invite (no fixture exists): the zoom fixture with a Webex link instead.
    func webexEvent() -> Event {
        var e = fx("zoom")
        e.location = "Webex"
        e.description = "Join: https://example.webex.com/meet/jdoe"
        return e
    }

    // 1
    func testMeetIsLoopClosedFourStopConic() {
        XCTAssertEqual(cols("meet", dark: false), [RGBA(hex: 0x34A853, aL), RGBA(hex: 0xF9AB00, aL), RGBA(hex: 0x4285F4, aL),
                                                   RGBA(hex: 0xEA4335, aL), RGBA(hex: 0x34A853, aL)])
        XCTAssertEqual(cols("meet", dark: true), [RGBA(hex: 0x34A853, aD), RGBA(hex: 0xFBBC04, aD), RGBA(hex: 0x4285F4, aD),
                                                  RGBA(hex: 0xEA4335, aD), RGBA(hex: 0x34A853, aD)])
    }

    // 2
    func testZoomAndTeamsAreSolid() {
        XCTAssertEqual(cols("zoom", dark: false), [RGBA(hex: 0x2D8CFF, aL)])
        XCTAssertEqual(cols("zoom", dark: true), [RGBA(hex: 0x2D8CFF, aD)])
        XCTAssertEqual(cols("teams", dark: false), [RGBA(hex: 0x5B5FC7, aL)])
        XCTAssertEqual(cols("teams", dark: true), [RGBA(hex: 0x7B83EB, aD)])
    }

    // 3
    func testWebex() {
        let m = CardModel(webexEvent())
        XCTAssertEqual(m.link?.provider, "webex")
        XCTAssertEqual(CardBorder.colors(for: m, dark: false), [RGBA(hex: 0x0099C2, aL), RGBA(hex: 0x4FA32F, aL), RGBA(hex: 0x0099C2, aL)])
        XCTAssertEqual(CardBorder.colors(for: m, dark: true), [RGBA(hex: 0x07C1E4, aD), RGBA(hex: 0x6CC04A, aD), RGBA(hex: 0x07C1E4, aD)])
    }

    // 4 + 5
    func testMultiNoLinkAndNoneHaveNoOutline() {
        for name in ["multilink", "zoom_location_plus_meet", "nolink", "none"] {
            for dark in [false, true] { XCTAssertNil(cols(name, dark: dark), "\(name) dark=\(dark)") }
        }
        XCTAssertEqual(CardModel(fx("multilink")).link?.provider, "calendar")
        XCTAssertTrue(CardModel(fx("zoom_location_plus_meet")).multi)   // multi-link card (no htmlLink in this fixture -> link nil)
        XCTAssertEqual(CardModel(fx("nolink")).link?.provider, "calendar")
        XCTAssertNil(CardModel(fx("none")).link)
    }

    // 6
    func testUnknownProviderAndNilLink() {
        XCTAssertNil(CardBorder.colors(for: VideoLink("skype", "https://join.skype.com/abc"), dark: false))
        XCTAssertNil(CardBorder.colors(for: VideoLink("skype", "https://join.skype.com/abc"), dark: true))
        XCTAssertNil(CardBorder.colors(for: nil as VideoLink?, dark: false))
    }

    // 7
    func testConstantOffMeansNoOutlineAnywhere() {
        XCTAssertTrue(CardBorder.enabled)
        for name in ["meet", "zoom", "teams", "multilink", "nolink", "none", "zoom_location_plus_meet"] {
            for dark in [false, true] { XCTAssertNil(cols(name, dark: dark, enabled: false), "\(name)") }
        }
        XCTAssertNil(CardBorder.colors(for: CardModel(webexEvent()), dark: false, enabled: false))
    }

    // 8
    func testTransitions() {
        let zoom = CardModel(fx("zoom")), meet = CardModel(fx("meet")), multi = CardModel(fx("multilink")), none = CardModel(fx("none"))
        for dark in [false, true] {
            let z = CardBorder.colors(for: zoom, dark: dark)
            XCTAssertNotNil(z)
            XCTAssertNotEqual(z, CardBorder.colors(for: meet, dark: dark), "zoom -> meet recolors")
            XCTAssertNil(CardBorder.colors(for: multi, dark: dark), "zoom -> multilink removes")
            XCTAssertNil(CardBorder.colors(for: none, dark: dark))
            XCTAssertNotNil(z, "none -> zoom adds")
        }
    }

    // 9
    func testContrastFloorOverCardFill() {
        var exempt = 0.0
        for provider in ["meet", "zoom", "teams", "webex"] {
            for dark in [false, true] {
                let fill = CardPalette.for(dark: dark).cardFill
                let stops = CardBorder.colors(for: VideoLink(provider, "x"), dark: dark)!
                for (i, s) in stops.enumerated() {
                    let r = RGBA.contrast(s.over(fill), fill)
                    if provider == "meet", !dark, i == 1 {     // Meet yellow on light: brand-faithful (CTO ruling)
                        exempt = r
                        XCTAssertGreaterThanOrEqual(r, 1.5, "meet yellow light")
                    } else {
                        XCTAssertGreaterThanOrEqual(r, CardBorder.floor, "\(provider) dark=\(dark) stop \(i) = \(r)")
                    }
                }
            }
        }
        XCTAssertEqual(exempt, 1.63, accuracy: 0.01)
    }

    // 10
    func testMultiStopListsCloseTheLoop() {
        for provider in ["meet", "webex"] {
            for dark in [false, true] {
                let s = CardBorder.colors(for: VideoLink(provider, "x"), dark: dark)!
                XCTAssertGreaterThan(s.count, 2)
                XCTAssertEqual(s.first, s.last, provider)
            }
        }
    }

    // 11
    func testIconsReadBrandConstantsNotLiterals() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("App/Icons.swift")
        let src = try String(contentsOf: url, encoding: .utf8).uppercased()
        for h in ["34A853", "FBBC04", "4285F4", "EA4335", "2D8CFF", "5B5FC7", "07C1E4", "6CC04A"] {
            XCTAssertFalse(src.contains(h), "Icons.swift has its own copy of \(h)")
        }
        XCTAssertTrue(src.contains("BRAND.MEETGREEN"))
    }
}
