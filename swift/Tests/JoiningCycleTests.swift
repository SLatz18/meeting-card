import XCTest
@testable import MeetingCardCore

/// v2.4 addendum (Scott 8:40am repro): Join click -> pointer exits while "Joining..." -> flash.
/// Drives click -> exit -> re-enter -> exit cycles DURING Joining through the real Coordinator and a
/// card double wired like the App's Card (gate step/apply, openingTitle, opening-only logging).
final class JoiningCycleTests: XCTestCase {
    static let inside = KeyGate.Point(x: 1000, y: 200), elsewhere = KeyGate.Point(x: 1040, y: 210)

    final class JoinCard: CardHandle, KeySurface {
        var ev: Event; let rk = Rechecker(now: 0)
        var gate = KeyGate(hoverKeys: true)
        var isOpening = false
        var title: String?
        var calls: [String] = []          // place / makeKey / releaseKey / cancelGiveBack / orderOut
        var titles: [String] = []         // every visible Join-title set
        var logs: [String] = []
        init(_ ev: Event) { self.ev = ev; title = CardModel(ev).openingTitle(false) }
        func gateStep(_ e: KeyGate.Event) {   // = Card.gateStep
            let before = gate
            let c = gate.step(e)
            if let l = KeyGate.openingLog(id: ev.id ?? "nil", before: before, after: gate, event: e) { logs.append(l) }
            KeyGate.apply(c, to: self)
        }
        func setTitle(_ t: String?) {
            title = t; if let t { titles.append(t); if isOpening { logs.append(KeyGate.openingTitleLog(id: ev.id ?? "nil", title: t)) } }
        }
        func close() { calls.append("orderOut") }
        func place(_ s: CardSlot) { calls.append("place"); gateStep(.placed(cursor: JoiningCycleTests.inside)) }
        func setNextUp(_ line: NextUp.Parts?) {}
        func refresh(_ ev: Event, now: Date) { self.ev = ev; setTitle(CardModel(ev).openingTitle(isOpening)) }
        func setNow(_ now: Date) {}
        func setOpening(_ on: Bool) {
            isOpening = on
            gateStep(.opening(on))
            setTitle(CardModel(ev).openingTitle(on))
        }
        func makeKey() { calls.append("makeKey") }
        func releaseKey() { calls.append("releaseKey") }
        func cancelGiveBack() { calls.append("cancelGiveBack") }
    }

    func testClickExitReenterCyclesDuringJoiningStayQuiet() {
        var made: [JoinCard] = []
        let ctl = Coordinator<JoinCard>(recheck: false, log: { _ in },
                                        makeCard: { e, _, _ in let c = JoinCard(e); made.append(c); return c },
                                        spawnGet: { _, _ in }, clock: { start(fx("zoom")) - 60 }, mono: { 0 })
        ctl.pollResult([fx("zoom")]); ctl.tick()
        let c = made[0]
        c.gateStep(.appear(cursor: Self.elsewhere))
        // Scott's Join click: pointer moves in, click arms (makeKey), then Join -> Joining.
        c.gateStep(.hoverEnter(cursor: Self.inside, inCard: true))
        c.gateStep(.click(inCard: true))
        XCTAssertNotNil(ctl.join(c))
        XCTAssertTrue(c.isOpening)
        XCTAssertEqual(c.title, "Joining\u{2026}")
        XCTAssertEqual(c.calls.last, "releaseKey", "Join hands key back once")
        c.calls = []; c.titles = []
        for i in 0..<4 {
            c.gateStep(.click(inCard: true))
            c.gateStep(.hoverExit)
            c.gateStep(.hoverEnter(cursor: i % 2 == 0 ? Self.inside : Self.elsewhere, inCard: true))
            c.gateStep(.moved(cursor: Self.elsewhere, inCard: true))
            c.gateStep(.hoverExit)
            XCTAssertEqual(c.title, "Joining\u{2026}", "visible title stays Joining... (cycle \(i))")
        }
        XCTAssertEqual(c.calls, [], "no place / order-out / makeKey / releaseKey during Joining cycles")
        XCTAssertTrue(c.titles.allSatisfy { $0 == "Joining\u{2026}" })
        XCTAssertTrue(ctl.isOpening(c))
        XCTAssertFalse(c.gate.armed)
        // v2.5 logging: only real gate state changes + title sets; the gate stays opening:idle, so
        // the cycles add nothing.
        let id = c.ev.id ?? "nil"
        XCTAssertEqual(c.logs, ["opening \(id): gate armed->opening:idle (opening-on)",
                                "opening \(id): title \"Joining\u{2026}\""], "\(c.logs)")
        XCTAssertFalse(c.logs.contains { $0.contains("{") || $0.contains("x:") }, "never event JSON / coordinates")
        print("JOINING-LOG-SAMPLE\n" + c.logs.prefix(8).joined(separator: "\n"))
    }

    /// v2.5: a burst of pointer moves / enters / exits / clicks while opening logs nothing new.
    func testMovesWhileOpeningLogNothing() {
        var g = KeyGate(hoverKeys: true)
        _ = g.step(.opening(true))
        XCTAssertTrue(g.opening)
        let evs: [KeyGate.Event] = (0..<50).flatMap { i -> [KeyGate.Event] in
            [.moved(cursor: Self.elsewhere, inCard: i % 2 == 0), .hoverEnter(cursor: Self.inside, inCard: true),
             .click(inCard: true), .hoverExit, .resigned]
        }
        var logs: [String] = []
        for e in evs {
            let b = g; _ = g.step(e)
            if let l = KeyGate.openingLog(id: "x", before: b, after: g, event: e) { logs.append(l) }
        }
        XCTAssertEqual(logs, [], "no-op transitions while opening are never logged")
        let b = g; _ = g.step(.opening(false))
        XCTAssertEqual(KeyGate.openingLog(id: "x", before: b, after: g, event: .opening(false)),
                       "opening x: gate opening:idle->idle (opening-off)")
    }

    func testNoOpeningLogOutsideJoining() {
        var g = KeyGate(hoverKeys: true); let before = g
        _ = g.step(.click(inCard: true))
        XCTAssertNil(KeyGate.openingLog(id: "x", before: before, after: g, event: .click(inCard: true)))
        let b2 = g; _ = g.step(.opening(true))
        XCTAssertEqual(KeyGate.openingLog(id: "x", before: b2, after: g, event: .opening(true)),
                       "opening x: gate armed->opening:idle (opening-on)")
        let b3 = g; _ = g.step(.opening(false))
        XCTAssertNotNil(KeyGate.openingLog(id: "x", before: b3, after: g, event: .opening(false)), "the exit from Joining is logged")
        let b4 = g; _ = g.step(.hoverExit)
        XCTAssertNil(KeyGate.openingLog(id: "x", before: b4, after: g, event: .hoverExit))
    }

    func testAppLogsGateAndTitleWhileOpening() throws {
        let src = try FixesV24Tests.appSource()
        let b = FixesV24Tests.body(src, "private func gateStep(_ e: KeyGate.Event)")
        XCTAssertTrue(b.contains("KeyGate.openingLog("))
        XCTAssertTrue(FixesV24Tests.body(src, "private func applyOpeningLabel()").contains("KeyGate.openingTitleLog("))
        XCTAssertTrue(FixesV24Tests.body(src, "func refresh(_ ev: Event, now: Date)").contains("KeyGate.openingTitleLog("))
    }
}
