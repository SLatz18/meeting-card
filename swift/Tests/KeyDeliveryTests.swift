import XCTest
@testable import MeetingCardCore

/// codex #12 P2: what a KeyGate effect DOES (makeKey / releaseKey / cancel the give-back) is
/// decided in Core (`KeyGate.step` + `KeyGate.apply`), and the App's pointer/click/place/show/resign paths all
/// go through it, so dropping an effect turns a test red.
final class KeyDeliveryTests: XCTestCase {
    final class Surface: KeySurface {
        var calls: [String] = []
        func makeKey() { calls.append("makeKey") }
        func releaseKey() { calls.append("releaseKey") }
        func cancelGiveBack() { calls.append("cancelGiveBack") }
    }
    static let p0 = KeyGate.Point(x: 1000, y: 200)

    func testCardClickYieldsMakeKey() {
        var g = KeyGate(hoverKeys: true); let s = Surface()
        KeyGate.apply(g.step(.appear(cursor: Self.p0)), to: s)
        XCTAssertEqual(s.calls, [])
        KeyGate.apply(g.step(.click(inCard: true)), to: s)
        XCTAssertEqual(s.calls, ["cancelGiveBack", "makeKey"])
        XCTAssertTrue(g.armed)
    }

    func testOffCardClickDeliversNothing() {
        var g = KeyGate(hoverKeys: true); let s = Surface()
        KeyGate.apply(g.step(.appear(cursor: Self.p0)), to: s)
        KeyGate.apply(g.step(.click(inCard: false)), to: s)
        XCTAssertEqual(s.calls, [])
    }

    func testRePlaceWhileArmedYieldsReleaseKey() {
        var g = KeyGate(hoverKeys: false); let s = Surface()
        KeyGate.apply(g.step(.click(inCard: true)), to: s)
        s.calls = []
        KeyGate.apply(g.step(.placed(cursor: Self.p0)), to: s)
        XCTAssertEqual(s.calls, ["releaseKey"])
        XCTAssertFalse(g.armed)
        s.calls = []
        KeyGate.apply(g.step(.placed(cursor: Self.p0)), to: s)
        XCTAssertEqual(s.calls, [], "unarmed re-place: nothing to hand back")
    }

    func testHoverExitYieldsReleaseKey() {
        var g = KeyGate(hoverKeys: true); let s = Surface()
        KeyGate.apply(g.step(.hoverEnter(cursor: Self.p0, inCard: true)), to: s)
        XCTAssertEqual(s.calls, ["cancelGiveBack", "makeKey"])
        s.calls = []
        KeyGate.apply(g.step(.hoverExit), to: s)
        XCTAssertEqual(s.calls, ["releaseKey"])
    }

    /// A click while already armed (hover-armed, give-back pending) cancels the give-back.
    func testClickWhileArmedCancelsGiveBack() {
        var g = KeyGate(hoverKeys: true); let s = Surface()
        KeyGate.apply(g.step(.hoverEnter(cursor: Self.p0, inCard: true)), to: s)
        s.calls = []
        KeyGate.apply(g.step(.click(inCard: true)), to: s)
        XCTAssertEqual(s.calls, ["cancelGiveBack"])
    }

    /// Wiring: the App layer has no effect switch of its own; every gate event goes through step + apply.
    func testAppRoutesEveryGateEventThroughDeliver() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("App/CardPanel.swift"))
        XCTAssertFalse(src.contains("gate.handle("), "App must call KeyGate.apply(gate.step(...)), never gate.handle")
        XCTAssertFalse(src.contains("case .makeKey"), "effect delivery belongs to Core")
        XCTAssertTrue(src.contains("extension Card: KeySurface"))
        for ev in ["gateStep(e)", "gateStep(.click(inCard: inCard))",
                   "gateStep(.placed(cursor: CardRootView.globalCursor))",
                   "gateStep(.appear(cursor: CardRootView.globalCursor))",
                   "self.gateStep(.resigned)", "let calls = gate.step(e)", "KeyGate.apply(calls, to: self)"] {
            XCTAssertTrue(src.contains(ev), "missing wiring: \(ev)")
        }
    }
}
