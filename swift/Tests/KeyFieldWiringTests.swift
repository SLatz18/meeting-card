import XCTest
@testable import MeetingCardCore

/// Settings' key field and notice: how the window is wired to the Kit's decisions. Hostless tests can't
/// load AppKit, so the App's sources are read as text.
final class KeyFieldWiringTests: XCTestCase {
    static let swiftDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    func read(_ path: String) throws -> String {
        try String(contentsOf: Self.swiftDir.appendingPathComponent(path), encoding: .utf8)
    }

    /// The key field is redrawn from the Keychain on every refresh, never from the key's text.
    func testSettingsKeyFieldWiring() throws {
        let src = try read("App/CoachSettingsWindow.swift")
        XCTAssertTrue(src.contains("KeyPlaceholder.refresh(shown: shownKeyPlaceholder, hasKey: coach.hasKey)"))
        XCTAssertEqual(src.components(separatedBy: "placeholderString = coach.hasKey ?").count - 1, 0, "no ad-hoc placeholder set outside refreshKeyField")
        let update = try XCTUnwrap(src.components(separatedBy: "    func update() {").dropFirst().first?.components(separatedBy: "\n    }\n").first)
        XCTAssertTrue(update.contains("refreshKeyField()"), "every refresh, including when the window is shown")
        let present = try XCTUnwrap(src.components(separatedBy: "    func present() {").dropFirst().first?.components(separatedBy: "\n    }\n").first)
        XCTAssertTrue(present.contains("update()"))
        XCTAssertTrue(src.contains("KeyNotice.after(check, callCapturing: self.coach.service?.isCapturing ?? false)"))
        let copy = try read("App/CoachCopy.swift")
        XCTAssertTrue(copy.contains("static let keySavedNextCallNote = \"Key saved. It will be used from your next call.\""))
    }
}
