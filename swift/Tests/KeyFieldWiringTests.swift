import XCTest
@testable import MeetingCardCore

/// Settings' key field and notice: how the window is wired to the Kit's decisions. Hostless tests can't
/// load AppKit, so the App's sources are read as text.
final class KeyFieldWiringTests: XCTestCase {
    static let swiftDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    func read(_ path: String) throws -> String {
        try String(contentsOf: Self.swiftDir.appendingPathComponent(path), encoding: .utf8)
    }

    /// The key field is redrawn from whether a key is stored on every refresh, never from the key's text.
    func testSettingsKeyFieldWiring() throws {
        let src = try read("App/CoachSettingsWindow.swift")
        XCTAssertTrue(src.contains("KeyPlaceholder.refresh(shown: shownKeyPlaceholder, hasKey: coach.keyStored)"))
        XCTAssertEqual(src.components(separatedBy: "keyField.placeholderString = ").count - 1, 2,
                       "the OpenAI key field's placeholder is set only in refreshKeyField (one line per case)")
        for banned in [".hasKey", "keychain", "readKey", "KeychainStore"] {
            XCTAssertFalse(src.contains(banned), "the window reads the cached presence, not the Keychain: \(banned)")
        }
        let update = try XCTUnwrap(src.components(separatedBy: "    func update() {").dropFirst().first?.components(separatedBy: "\n    }\n").first)
        XCTAssertTrue(update.contains("refreshKeyField()"), "every forced refresh, including when the window is shown")
        let refresh = try XCTUnwrap(src.components(separatedBy: "    func refresh() {").dropFirst().first?.components(separatedBy: "\n    }\n").first)
        XCTAssertTrue(refresh.contains("refreshKeyField()"), "every tick")
        let present = try XCTUnwrap(src.components(separatedBy: "    func present() {").dropFirst().first?.components(separatedBy: "\n    }\n").first)
        XCTAssertTrue(present.contains("update()"))
        XCTAssertTrue(src.contains("KeyNotice.after(check, callCapturing: self.coach.service?.isCapturing ?? false, hadKey: hadKey)"))
        XCTAssertTrue(src.contains("let hadKey = coach.keyStored"), "read before the save changes it")
        XCTAssertTrue(src.contains("kind.clearedAtCallEnd"), "a call-specific note is cleared when the call ends")
        XCTAssertTrue(src.contains("var capturing: Bool"), "the call ending is a change the refresh sees")
        let copy = try read("App/CoachCopy.swift")
        XCTAssertTrue(copy.contains("static let keySavedNextCallNote = \"Key saved. It will be used from your next call.\""))
    }

    /// The controller's refresh tick (every second) touches no Keychain API: presence is cached in
    /// `keyStored` and updated by the key actions.
    func testControllerRefreshDoesNotReadTheKeychain() throws {
        let src = try read("App/CoachController.swift")
        let refresh = try XCTUnwrap(src.components(separatedBy: "    func refresh() {").dropFirst().first?.components(separatedBy: "\n    }\n").first)
        for banned in ["keychain", "hasKey", "readKey", "checkStoredKey"] {
            XCTAssertFalse(refresh.contains(banned), "refresh() reads the Keychain: \(banned)")
        }
        let keyActions = try read("App/CoachKeyActions.swift")
        XCTAssertEqual(keyActions.components(separatedBy: "keyStored = ").count - 1, 2, "a blank save and an accepted save update it")
    }
}
