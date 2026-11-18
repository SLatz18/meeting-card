import XCTest
@testable import MeetingCardCore

/// The Settings window could not be scrolled: its once-a-second refresh re-applied everything and
/// scrolled back to the top. A refresh with nothing changed must touch no view, relayout nothing and
/// keep the scroll position; a change keeps the place too.
final class SettingsRefreshTests: XCTestCase {
    struct State: Equatable, Sendable {
        var keyStored = false
        var enabled = true
        var cost = "$0.00"
    }

    func testFirstStateIsAppliedThenIdenticalTicksAreNot() {
        var gate = ChangeGate<State>()
        XCTAssertTrue(gate.shouldApply(State()))
        for _ in 0..<3600 { XCTAssertFalse(gate.shouldApply(State())) }
        XCTAssertEqual(gate.applications, 1, "an hour of ticks with nothing changed applies nothing")
    }

    func testEachChangeIsAppliedOnce() {
        var gate = ChangeGate<State>()
        XCTAssertTrue(gate.shouldApply(State()))
        var s = State()
        s.keyStored = true
        XCTAssertTrue(gate.shouldApply(s), "key saved")
        XCTAssertFalse(gate.shouldApply(s))
        s.cost = "$0.01"
        XCTAssertTrue(gate.shouldApply(s))
        s.keyStored = false
        XCTAssertTrue(gate.shouldApply(s), "key removed")
        XCTAssertEqual(gate.applications, 4)
    }

    func testForceRecordsAndResetStartsOver() {
        var gate = ChangeGate<State>()
        gate.force(State())
        XCTAssertFalse(gate.shouldApply(State()), "a forced apply is what the next tick compares to")
        gate.reset()
        XCTAssertTrue(gate.shouldApply(State()))
    }

    // MARK: scroll

    func testRangeIsHowFarContentExtendsPastTheWindow() {
        XCTAssertEqual(SettingsScroll.range(fitting: 1000, visible: 700), 300)
        XCTAssertEqual(SettingsScroll.range(fitting: 600, visible: 700), 0)
    }

    /// The document view is not flipped: the top of the content is the largest origin.
    func testTopAndBottomOffsets() {
        XCTAssertEqual(SettingsScroll.offsetFromTop(originY: 300, fitting: 1000, visible: 700), 0, "origin 300 is the top")
        XCTAssertEqual(SettingsScroll.offsetFromTop(originY: 0, fitting: 1000, visible: 700), 300, "origin 0 is the bottom")
        XCTAssertEqual(SettingsScroll.offsetFromTop(originY: 180, fitting: 1000, visible: 700), 120)
    }

    /// A tick with nothing changed is not a layout change, so the scroll is never touched.
    func testTicksWithTheSameLayoutNeverRescroll() {
        var layout = ChangeGate<SettingsLayoutKey>()
        let key = SettingsLayoutKey(width: 480, fitting: 1000.2, height: 699.8)
        XCTAssertTrue(layout.shouldApply(key), "first fit")
        var originY = 180.0
        for _ in 0..<600 {
            if layout.shouldApply(SettingsLayoutKey(width: 480, fitting: 1000.4, height: 700.1)) { originY = 300 }
        }
        XCTAssertEqual(originY, 180, "the user's place survived ten minutes of ticks")
    }

    /// When the content does change height, the same distance from the top is kept (within the new range).
    func testAChangeInHeightKeepsThePlaceFromTheTop() {
        let fromTop = SettingsScroll.offsetFromTop(originY: 180, fitting: 1000, visible: 700)
        XCTAssertEqual(fromTop, 120)
        XCTAssertEqual(SettingsScroll.originY(fromTop: fromTop, fitting: 1060, visible: 700), 240, "a note appeared: still 120 from the top")
        XCTAssertEqual(SettingsScroll.originY(fromTop: fromTop, fitting: 1000, visible: 700), 180, "unchanged: same origin")
        XCTAssertEqual(SettingsScroll.originY(fromTop: fromTop, fitting: 760, visible: 700), 0, "shrunk past the offset: clamped to the bottom")
        XCTAssertEqual(SettingsScroll.originY(fromTop: 0, fitting: 1000, visible: 700), 300, "fromTop 0 is the top")
        XCTAssertEqual(SettingsScroll.originY(fromTop: 50, fitting: 500, visible: 700), 0, "nothing to scroll")
    }

    // MARK: wiring (hostless tests read the App's sources)

    static let swiftDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    func read(_ path: String) throws -> String {
        try String(contentsOf: Self.swiftDir.appendingPathComponent(path), encoding: .utf8)
    }

    func body(_ marker: String, in text: String) throws -> String {
        try XCTUnwrap(text.components(separatedBy: marker).dropFirst().first?.components(separatedBy: "\n    }\n").first, marker)
    }

    /// The controller's tick calls the gated refresh; only user actions and screenshots force an update.
    func testTheTimerPathIsTheGatedRefresh() throws {
        let controller = try read("App/CoachController.swift")
        let refresh = try body("    func refresh() {", in: controller)
        XCTAssertTrue(refresh.contains("settingsWindow?.refresh()"))
        XCTAssertFalse(refresh.contains("settingsWindow?.update()"))
        XCTAssertFalse(refresh.contains("showSettings") || refresh.contains("present()"))

        let window = try read("App/CoachSettingsWindow.swift")
        let tick = try body("    func refresh() {", in: window)
        XCTAssertTrue(tick.contains("viewGate.shouldApply(viewState())"), "no change, no view update")
        XCTAssertFalse(tick.contains("build()"), "the tick never rebuilds")
        for banned in ["scroll", "removeFromSuperview", "arrangedSubviews", "setContentSize"] {
            XCTAssertFalse(tick.contains(banned), "the tick touches \(banned)")
        }
    }

    /// Nothing rebuilds the scroll content except building the window and changing the onboarding screen.
    func testNothingRebuildsOnATimer() throws {
        let window = try read("App/CoachSettingsWindow.swift")
        XCTAssertEqual(window.components(separatedBy: "Timer").count - 1, 0, "the Settings window runs no timer of its own")
        for marker in ["    func refresh() {", "    func update() {", "    private func applyState() {", "    private func viewState() -> ViewState {",
                       "    private func fitWindow() {", "    private func refreshKeyField() {"] {
            XCTAssertFalse(try body(marker, in: window).contains("build()"), "\(marker) rebuilds the content")
        }
        let update = try body("    func update() {", in: window)
        XCTAssertFalse(update.contains("build()"))
        XCTAssertFalse(update.contains("removeFromSuperview"))
    }

    /// A fit keeps the scroll place unless the window was just built or shown, and skips when the layout is unchanged.
    func testFitWindowKeepsTheScrollPlace() throws {
        let window = try read("App/CoachSettingsWindow.swift")
        let fit = try body("    private func fitWindow() {", in: window)
        XCTAssertTrue(fit.contains("layoutGate.shouldApply(key) || toTop"))
        XCTAssertTrue(fit.contains("SettingsScroll.offsetFromTop"))
        XCTAssertTrue(fit.contains("SettingsScroll.originY(fromTop: toTop ? 0 : fromTop"))
        XCTAssertFalse(fit.contains("max(0, fitting - h)"), "no unconditional scroll to the top")
        let present = try body("    func present() {", in: window)
        XCTAssertTrue(present.contains("scrollToTopOnNextFit = true"), "showing the window starts at the top")
    }
}
