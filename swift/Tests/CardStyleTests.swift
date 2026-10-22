import XCTest
@testable import MeetingCardCore

/// #12: card geometry, stack gap, per-appearance palette, Return/Esc gating.
final class CardStyleTests: XCTestCase {
    // MARK: layout

    /// Panel frame == card rect, card edge 14pt in.
    func testPanelEqualsCardRect() {
        XCTAssertEqual(CardLayout.panelSize.w, CardLayout.W)
        XCTAssertEqual(CardLayout.panelSize.h, CardLayout.H)
        let o = CardLayout.panelOrigin(index: 0, minY: 80, maxX: 1512)
        XCTAssertEqual(o.x + CardLayout.W, 1512 - 14)
        XCTAssertEqual(o.y, 80 + 14)
        XCTAssertTrue(CardLayout.cardContains(x: 0, y: 0))
        XCTAssertTrue(CardLayout.cardContains(x: CardLayout.W, y: CardLayout.H))
    }

    func testCardEdgeStaysAt14ptMargin() {
        let vf = (minX: 0.0, minY: 80.0, maxX: 1512.0)
        let o = CardLayout.panelOrigin(index: 0, minY: vf.minY, maxX: vf.maxX)
        XCTAssertEqual(o.x + CardLayout.W, vf.maxX - 14)
        XCTAssertEqual(o.y, vf.minY + 14)
    }

    func testStackGapIs20ptBetweenCardEdges() {
        XCTAssertEqual(CardLayout.gap, 20)
        let a = CardLayout.panelOrigin(index: 0, minY: 0, maxX: 1000)
        let b = CardLayout.panelOrigin(index: 1, minY: 0, maxX: 1000)
        let c = CardLayout.panelOrigin(index: 2, minY: 0, maxX: 1000)
        XCTAssertEqual(b.y - (a.y + CardLayout.panelSize.h), 20, "panels 20pt apart, never overlap")
        XCTAssertEqual(c.y - b.y, b.y - a.y)
        XCTAssertEqual(a.x, b.x)
    }

    // MARK: palette

    func testPaletteDiffersPerAppearanceAndJoinPillInverts() {
        let l = CardPalette.for(dark: false), d = CardPalette.for(dark: true)
        XCTAssertNotEqual(l.cardFill, d.cardFill)
        XCTAssertLessThan(l.joinFill.luminance, 0.1, "light mode: dark pill")
        XCTAssertGreaterThan(d.joinFill.luminance, 0.7, "dark mode: light pill")
        XCTAssertGreaterThan(RGBA.contrast(l.joinText, l.joinFill), 7)
        XCTAssertGreaterThan(RGBA.contrast(d.joinText, d.joinFill), 7)
        XCTAssertGreaterThan(d.cardFill.luminance, 0, "not pure black")
        XCTAssertLessThan(d.cardFill.luminance, 0.05)
    }

    func testIgnoreIsVisiblyFilledInBothAppearances() {
        for dark in [false, true] {
            let p = CardPalette.for(dark: dark)
            let fill = p.ignoreFill(.normal).over(p.cardFill)
            // Issue #12: old #EAEAEA on #F4F4F4 was ~1.1:1. Want a shape that reads as a button.
            XCTAssertGreaterThan(RGBA.contrast(fill, p.cardFill), 1.25, "dark=\(dark)")
            XCTAssertGreaterThan(p.hairline.a, 0, "dark=\(dark)")
        }
    }

    func testHoverAndPressedAreDistinctForBothButtonsAndAppearances() {
        for dark in [false, true] {
            let p = CardPalette.for(dark: dark)
            for f in [p.ignoreFill, p.joinFillState] {
                let n = f(.normal).over(p.cardFill), h = f(.hover).over(p.cardFill), pr = f(.pressed).over(p.cardFill)
                XCTAssertNotEqual(n, h, "dark=\(dark)"); XCTAssertNotEqual(h, pr, "dark=\(dark)"); XCTAssertNotEqual(n, pr, "dark=\(dark)")
            }
        }
    }

    func testAmberFlagContrastAtLeast4p5InBothAppearances() {
        for dark in [false, true] {
            let p = CardPalette.for(dark: dark)
            XCTAssertGreaterThanOrEqual(RGBA.contrast(p.flag, p.cardFill), 4.5, "dark=\(dark)")
        }
    }

    func testContrastMath() {
        XCTAssertEqual(RGBA.contrast(RGBA(hex: 0x000000), RGBA(hex: 0xFFFFFF)), 21, accuracy: 0.01)
        XCTAssertEqual(RGBA.contrast(RGBA(hex: 0x777777), RGBA(hex: 0x777777)), 1, accuracy: 0.001)
    }

    // MARK: keys

    func testNoKeysOnAppear() {
        var g = KeyGate(hoverKeys: true)
        XCTAssertEqual(g.handle(.appear(cursor: .init(x: 0, y: 0))), .none)
        XCTAssertFalse(g.armed)
        XCTAssertNil(g.action(keyCode: 36)); XCTAssertNil(g.action(keyCode: 53))
    }

    func testClickArmsReturnAndEsc() {
        var g = KeyGate(hoverKeys: false)
        _ = g.handle(.appear(cursor: .init(x: 0, y: 0)))
        _ = g.handle(.click(inCard: true))
        XCTAssertEqual(g.action(keyCode: 36), .join)   // Return
        XCTAssertEqual(g.action(keyCode: 76), .join)   // keypad Enter
        XCTAssertEqual(g.action(keyCode: 53), .ignore) // Esc
        XCTAssertNil(g.action(keyCode: 0))             // 'a' is not ours
    }

    func testHoverArmsAndMakesKeyOnlyWhenHoverKeysOn() {
        var on = KeyGate(hoverKeys: true)
        XCTAssertEqual(on.handle(.hoverEnter(cursor: .init(x: 5, y: 5), inCard: true)), .makeKey)
        XCTAssertEqual(on.action(keyCode: 36), .join)
        var off = KeyGate(hoverKeys: false)
        XCTAssertEqual(off.handle(.hoverEnter(cursor: .init(x: 5, y: 5), inCard: true)), .none)
        XCTAssertNil(off.action(keyCode: 36))
        XCTAssertEqual(off.handle(.hoverExit), .none)
    }

    func testHoverExitDisarmsAndHandsFocusBack() {
        var g = KeyGate(hoverKeys: true)
        _ = g.handle(.hoverEnter(cursor: .init(x: 5, y: 5), inCard: true))
        XCTAssertEqual(g.handle(.hoverExit), .releaseKey)
        XCTAssertFalse(g.armed)
        XCTAssertNil(g.action(keyCode: 53))
        // A click while hovered, then exit: still give focus back (Scott has moved on).
        _ = g.handle(.hoverEnter(cursor: .init(x: 5, y: 5), inCard: true)); _ = g.handle(.click(inCard: true))
        XCTAssertEqual(g.handle(.hoverExit), .releaseKey)
        XCTAssertFalse(g.armed)
    }

    func testExitWithoutArmingDoesNothing() {
        var g = KeyGate(hoverKeys: true)
        _ = g.handle(.appear(cursor: .init(x: 0, y: 0)))
        XCTAssertEqual(g.handle(.hoverExit), .none)
        _ = g.handle(.hoverEnter(cursor: .init(x: 5, y: 5), inCard: true)); _ = g.handle(.resigned)
        XCTAssertEqual(g.handle(.hoverExit), .none, "already resigned: nothing to hand back")
    }

    func testResignDisarms() {
        var g = KeyGate(hoverKeys: false)
        _ = g.handle(.click(inCard: true))
        XCTAssertEqual(g.handle(.resigned), .none)
        XCTAssertNil(g.action(keyCode: 36))
    }

    func testHoverKeysDefaultOn() {
        XCTAssertTrue(KeyGate.hoverKeysDefault)
    }

    // MARK: #12 review (pointer-moved gate, off-card pointer, give-back race)

    static let p0 = KeyGate.Point(x: 1000, y: 200), p1 = KeyGate.Point(x: 1003, y: 201)

    /// P1: AppKit's hover-enter for a panel appearing under a resting cursor must not arm keys.
    func testAppearUnderRestingCursorDoesNotArm() {
        var g = KeyGate(hoverKeys: true)
        _ = g.handle(.appear(cursor: Self.p0))
        XCTAssertEqual(g.handle(.hoverEnter(cursor: Self.p0, inCard: true)), .none)
        XCTAssertFalse(g.armed)
        XCTAssertFalse(g.pointerMovedSincePlacement)
    }

    /// P1: a re-stack that slides the card under an unmoved cursor must not arm either.
    func testReplaceUnderRestingCursorDoesNotArm() {
        var g = KeyGate(hoverKeys: true)
        _ = g.handle(.appear(cursor: KeyGate.Point(x: 0, y: 0)))
        _ = g.handle(.placed(cursor: Self.p0))
        XCTAssertEqual(g.handle(.hoverEnter(cursor: Self.p0, inCard: true)), .none)
        XCTAssertEqual(g.handle(.moved(cursor: Self.p0, inCard: true)), .none)
        XCTAssertFalse(g.armed)
    }

    /// Real movement inside the card (enter or mouseMoved) after placement arms.
    func testMoveInsideCardArms() {
        var g = KeyGate(hoverKeys: true)
        _ = g.handle(.appear(cursor: Self.p0))
        _ = g.handle(.hoverEnter(cursor: Self.p0, inCard: true))
        XCTAssertEqual(g.handle(.moved(cursor: Self.p1, inCard: true)), .makeKey)
        XCTAssertTrue(g.armed)
        XCTAssertEqual(g.handle(.moved(cursor: Self.p0, inCard: true)), .none, "already armed: one makeKey")
        var h = KeyGate(hoverKeys: true)
        _ = h.handle(.appear(cursor: Self.p0))
        XCTAssertEqual(h.handle(.hoverEnter(cursor: Self.p1, inCard: true)), .makeKey)
    }

    /// P2: hover and clicks off the card (spurious hover-enter, clicks outside the card rect)
    /// never arm; card clicks still do.
    func testPointerOffCardNeverArms() {
        var g = KeyGate(hoverKeys: true)
        _ = g.handle(.appear(cursor: Self.p0))
        XCTAssertEqual(g.handle(.moved(cursor: Self.p1, inCard: false)), .none)
        XCTAssertEqual(g.handle(.hoverEnter(cursor: Self.p1, inCard: false)), .none)
        _ = g.handle(.click(inCard: false))
        XCTAssertFalse(g.armed)
        XCTAssertNil(g.action(keyCode: 36))
        _ = g.handle(.click(inCard: true))
        XCTAssertTrue(g.armed)
    }

    func testCardContainsOnlyCardRect() {
        XCTAssertTrue(CardLayout.cardContains(x: 1, y: 1))
        XCTAssertTrue(CardLayout.cardContains(x: CardLayout.W - 1, y: CardLayout.H - 1))
        XCTAssertFalse(CardLayout.cardContains(x: -1, y: 50))
        XCTAssertFalse(CardLayout.cardContains(x: 50, y: -0.5))
        XCTAssertFalse(CardLayout.cardContains(x: CardLayout.W + 1, y: 50))
        XCTAssertFalse(CardLayout.cardContains(x: 50, y: CardLayout.H + 1))
    }

    /// P2: exit then re-enter inside the 50ms give-back window: the delayed fallback must not act.
    func testReenterBeforeGiveBackKeepsKeys() {
        var g = KeyGate(hoverKeys: true)
        _ = g.handle(.appear(cursor: Self.p0))
        XCTAssertEqual(g.handle(.moved(cursor: Self.p1, inCard: true)), .makeKey)
        XCTAssertEqual(g.handle(.hoverExit), .releaseKey)
        XCTAssertTrue(g.shouldGiveBackFocus, "disarmed: the pending give-back may act")
        XCTAssertEqual(g.handle(.hoverEnter(cursor: Self.p0, inCard: true)), .makeKey)
        XCTAssertTrue(g.armed)
        XCTAssertFalse(g.shouldGiveBackFocus, "re-armed: the pending give-back must not order out")
        // A click re-arms too.
        _ = g.handle(.hoverExit)
        _ = g.handle(.click(inCard: true))
        XCTAssertFalse(g.shouldGiveBackFocus)
    }

    // MARK: #12 review round 2

    /// P2: appear -> moved (armed) -> placed must DISARM and hand focus back (hover-exit path).
    func testPlacedDisarmsAndGivesFocusBack() {
        var g = KeyGate(hoverKeys: true)
        _ = g.handle(.appear(cursor: Self.p0))
        XCTAssertEqual(g.handle(.moved(cursor: Self.p1, inCard: true)), .makeKey)
        XCTAssertEqual(g.handle(.placed(cursor: Self.p1)), .releaseKey)
        XCTAssertFalse(g.armed)
        XCTAssertNil(g.action(keyCode: 36), "stale arming after re-place must not Join")
        XCTAssertTrue(g.shouldGiveBackFocus)
        // Click-armed (hover off) also disarms on re-place.
        var c = KeyGate(hoverKeys: false)
        _ = c.handle(.click(inCard: true))
        XCTAssertEqual(c.handle(.placed(cursor: Self.p0)), .releaseKey)
        XCTAssertNil(c.action(keyCode: 36))
        // Unarmed re-place: nothing to hand back.
        XCTAssertEqual(c.handle(.placed(cursor: Self.p1)), .none)
    }

    /// P2: the panel may become key ONLY while the gate is armed; an off-card click never makes it key.
    func testOffCardClickCannotMakePanelKey() throws {
        var g = KeyGate(hoverKeys: true)
        _ = g.handle(.appear(cursor: Self.p0))
        XCTAssertFalse(g.allowsKey)
        XCTAssertEqual(g.handle(.click(inCard: false)), .none)
        XCTAssertFalse(g.allowsKey, "off-card click: AppKit must not be allowed to make the panel key")
        // A card click arms FIRST, then asks for key (becomesKeyOnlyIfNeeded: AppKit won't do it).
        XCTAssertEqual(g.handle(.click(inCard: true)), .makeKey)
        XCTAssertTrue(g.allowsKey)
        _ = g.handle(.resigned)
        XCTAssertFalse(g.allowsKey)
        // Wiring (hostless tests can't load AppKit panels): canBecomeKey must ask the gate, and
        // AppKit's default click-to-key must be off.
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/CardPanel.swift"))
        XCTAssertTrue(src.contains("override var canBecomeKey: Bool { allowsKey?() ?? false }"))
        XCTAssertFalse(src.contains("override var canBecomeKey: Bool { true }"))
        XCTAssertTrue(src.contains("panel.becomesKeyOnlyIfNeeded = true"))
        XCTAssertTrue(src.contains("panel.allowsKey = { [weak self] in self?.gate.allowsKey ?? false }"))
    }
}
