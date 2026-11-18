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
        XCTAssertTrue(src.contains("coach.keyPresence.placeholder(shown: shownKeyPlaceholder)"))
        XCTAssertEqual(src.components(separatedBy: "placeholderString = coach.hasKey ?").count - 1, 0, "no ad-hoc placeholder set outside refreshKeyField")
        for banned in [".hasKey", "keychain", "readKey", "KeychainStore"] {
            XCTAssertFalse(src.contains(banned), "the window's refresh reads the cached presence, not the Keychain: \(banned)")
        }
        let update = try XCTUnwrap(src.components(separatedBy: "    func update() {").dropFirst().first?.components(separatedBy: "\n    }\n").first)
        XCTAssertTrue(update.contains("refreshKeyField()"), "every refresh, including when the window is shown")
        let present = try XCTUnwrap(src.components(separatedBy: "    func present() {").dropFirst().first?.components(separatedBy: "\n    }\n").first)
        XCTAssertTrue(present.contains("update()"))
        XCTAssertTrue(src.contains("KeyNotice.after(check, callCapturing: self.coach.service?.isCapturing ?? false)"))
        let copy = try read("App/CoachCopy.swift")
        XCTAssertTrue(copy.contains("static let keySavedNextCallNote = \"Key saved. It will be used from your next call.\""))
    }

    /// The controller's refresh tick (every second) touches no Keychain API: presence is loaded once and
    /// updated on save and remove.
    func testControllerRefreshDoesNotReadTheKeychain() throws {
        let src = try read("App/CoachController.swift")
        let refresh = try XCTUnwrap(src.components(separatedBy: "    func refresh() {").dropFirst().first?.components(separatedBy: "\n    }\n").first)
        for banned in ["keychain", "hasKey", "readKey", "keyPresence.load", "checkStoredKey"] {
            XCTAssertFalse(refresh.contains(banned), "refresh() reads the Keychain: \(banned)")
        }
        XCTAssertFalse(src.contains("var hasKey"), "no Keychain-reading hasKey on the controller")
        let keyActions = try read("App/CoachKeyActions.swift")
        XCTAssertTrue(keyActions.contains("keyPresence.saved()"))
        XCTAssertTrue(keyActions.contains("keyPresence.removed()"))
    }

    /// A Keychain refusal is logged as unreadable with its status, never folded into "empty".
    func testKeychainFailureIsNotLoggedAsEmpty() throws {
        let src = try read("App/CoachController.swift")
        let check = try XCTUnwrap(src.components(separatedBy: "    func checkStoredKey(").dropFirst().first?.components(separatedBy: "\n    }\n").first)
        XCTAssertFalse(check.contains("try? keychain"), "a failed read is not swallowed")
        XCTAssertTrue(check.contains("keyPresence.unreadable"))
    }

    /// captions.state is logged from the controller (the caption and transcript sources never log), when it changes.
    func testCaptionsStateIsLoggedOnChangeFromTheController() throws {
        let src = try read("App/CoachController.swift")
        let log = try XCTUnwrap(src.components(separatedBy: "    private func logCaptionsState() {").dropFirst().first?.components(separatedBy: "\n    }\n").first)
        XCTAssertTrue(log.contains("guard event != lastCaptionsState"))
        XCTAssertTrue(log.contains("CoachLog.record(event)"))
        let refresh = try XCTUnwrap(src.components(separatedBy: "    func refresh() {").dropFirst().first?.components(separatedBy: "\n    }\n").first)
        XCTAssertTrue(refresh.contains("logCaptionsState()"))
        for name in ["App/CoachTranscript.swift", "App/CoachCaptions.swift"] {
            XCTAssertFalse(try read(name).contains("CoachLog"), name)
        }
    }
}
