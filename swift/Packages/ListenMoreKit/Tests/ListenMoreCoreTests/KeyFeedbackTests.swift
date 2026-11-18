import XCTest
@testable import ListenMoreCore

final class KeyFeedbackTests: XCTestCase {
    func testPlaceholderFollowsTheStoredKey() {
        XCTAssertEqual(KeyPlaceholder.of(hasKey: true), .saved)
        XCTAssertEqual(KeyPlaceholder.of(hasKey: false), .empty)
    }

    /// A field that was never drawn always gets its placeholder.
    func testNeverDrawnAlwaysRefreshes() {
        XCTAssertEqual(KeyPlaceholder.refresh(shown: nil, hasKey: true), .saved)
        XCTAssertEqual(KeyPlaceholder.refresh(shown: nil, hasKey: false), .empty)
    }

    /// After a save the empty placeholder is replaced; after a delete the saved one is.
    func testRefreshesAfterSaveAndAfterDelete() {
        XCTAssertEqual(KeyPlaceholder.refresh(shown: .empty, hasKey: true), .saved, "key saved")
        XCTAssertEqual(KeyPlaceholder.refresh(shown: .saved, hasKey: false), .empty, "key deleted")
    }

    /// Nothing to redraw while what is shown matches the Keychain.
    func testNoChangeNoRefresh() {
        XCTAssertNil(KeyPlaceholder.refresh(shown: .saved, hasKey: true))
        XCTAssertNil(KeyPlaceholder.refresh(shown: .empty, hasKey: false))
    }

    /// Whenever the window is shown the decision re-reads the Keychain, so a key stored (or removed)
    /// while it was hidden is caught on the next show.
    func testShowingTheWindowCatchesChangesMadeWhileHidden() {
        var shown: KeyPlaceholder? = .empty
        for hasKey in [true, true, false, false, true] {
            if let next = KeyPlaceholder.refresh(shown: shown, hasKey: hasKey) { shown = next }
            XCTAssertEqual(shown, KeyPlaceholder.of(hasKey: hasKey))
        }
    }

    func testSaveBetweenCallsIsUsedRightAway() {
        XCTAssertEqual(KeyNotice.after(.ok, callCapturing: false), .saved)
        XCTAssertEqual(KeyNotice.after(.unreachable, callCapturing: false), .saved, "a key OpenAI could not be asked about is still stored")
    }

    /// The key is read when capture starts, so a key saved while it runs is for the next call.
    func testSaveMidCallIsForTheNextCall() {
        XCTAssertEqual(KeyNotice.after(.ok, callCapturing: true), .savedForNextCall)
        XCTAssertEqual(KeyNotice.after(.unreachable, callCapturing: true), .savedForNextCall)
    }

    /// Removing a key that was never stored says nothing; one that was says so.
    func testRemoveNoticeOnlyWhenAKeyExisted() {
        XCTAssertNil(KeyNotice.after(.empty, callCapturing: false, hadKey: false))
        XCTAssertNil(KeyNotice.after(.empty, callCapturing: true, hadKey: false))
        XCTAssertEqual(KeyNotice.after(.empty, callCapturing: false, hadKey: true), .removed)
        XCTAssertEqual(KeyNotice.after(.empty, callCapturing: true, hadKey: true), .removedAfterThisCall)
        XCTAssertEqual(KeyNotice.after(.ok, callCapturing: false, hadKey: false), .saved, "saving needs no earlier key")
    }

    /// The "next call" and "this call" notes go when the call ends; the others stay.
    func testCallSpecificNotesAreClearedAtCallEnd() {
        XCTAssertNil(KeyNotice.savedForNextCall.clearedAtCallEnd)
        XCTAssertNil(KeyNotice.removedAfterThisCall.clearedAtCallEnd)
        XCTAssertEqual(KeyNotice.saved.clearedAtCallEnd, .saved)
        XCTAssertEqual(KeyNotice.removed.clearedAtCallEnd, .removed)
    }

    func testDelete() {
        XCTAssertEqual(KeyNotice.after(.empty, callCapturing: false), .removed)
        XCTAssertEqual(KeyNotice.after(.empty, callCapturing: true), .removedAfterThisCall)
    }

    /// A rejected key is not stored, so there is nothing to confirm.
    func testRejectedKeyHasNoNotice() {
        XCTAssertNil(KeyNotice.after(.rejected, callCapturing: false))
        XCTAssertNil(KeyNotice.after(.rejected, callCapturing: true))
    }

    /// The decision handles every check result.
    func testEveryCheckResultIsHandled() {
        for check in [KeyCheck.ok, .empty, .rejected, .unreachable] {
            for capturing in [false, true] {
                let notice = KeyNotice.after(check, callCapturing: capturing)
                XCTAssertEqual(notice == nil, check == .rejected, "\(check) \(capturing)")
            }
        }
    }

    // MARK: presence and the gate

    final class CountingKeys: APIKeyProvider {
        var key: APIKey?
        var failure: Error?
        var reads = 0
        func readKey() throws -> APIKey? {
            reads += 1
            if let failure { throw failure }
            return key
        }
    }

    /// A refresh tick uses the cached presence: loading reads the Keychain once, and a thousand ticks
    /// (placeholder decisions, as the Settings window makes every second) read it zero more times.
    func testRefreshTicksNeverReadTheKeychain() throws {
        let keys = CountingKeys()
        keys.key = APIKey("sk-test-not-real")
        var presence = KeyPresence()
        _ = presence.load(from: keys)
        XCTAssertEqual(keys.reads, 1)
        var shown: KeyPlaceholder?
        for _ in 0..<1000 {
            if let next = presence.placeholder(shown: shown) { shown = next }
        }
        XCTAssertEqual(shown, .saved)
        XCTAssertEqual(keys.reads, 1, "the ticks did not touch the provider")
    }

    func testSaveAndRemoveUpdateThePresenceWithoutReading() {
        let keys = CountingKeys()
        var presence = KeyPresence()
        presence.saved()
        XCTAssertEqual(presence.placeholder(shown: .empty), .saved)
        presence.removed()
        XCTAssertEqual(presence.placeholder(shown: .saved), .empty)
        XCTAssertEqual(keys.reads, 0)
    }

    func testLoadSeparatesAbsentFromUnreadable() {
        let sink = CaptureSink()
        CoachLog.install(sink)
        defer { CoachLog.install(nil) }
        struct Refused: StatusCarryingError { var statusCode: Int { -25308 } }
        let keys = CountingKeys()
        var presence = KeyPresence()
        XCTAssertNil(presence.load(from: keys))
        XCTAssertFalse(presence.stored)
        XCTAssertFalse(presence.unreadable)
        keys.failure = Refused()
        XCTAssertNil(presence.load(from: keys))
        XCTAssertTrue(presence.unreadable, "a refusal is not the same as no key")
        XCTAssertEqual(sink.lines, ["key.read result=absent at=stored", "key.read result=unreadable status=-25308 at=stored"])
        keys.failure = nil
        keys.key = APIKey("sk-test-not-real")
        XCTAssertNotNil(presence.load(from: keys))
        XCTAssertTrue(presence.stored)
        XCTAssertFalse(presence.unreadable)
        XCTAssertFalse(sink.lines.contains { $0.contains("sk-") })
    }

    func testGateStateAfterEachCheck() {
        XCTAssertEqual(KeyGateState.after(.ok), .accepted)
        XCTAssertEqual(KeyGateState.after(.rejected), .rejected)
        XCTAssertEqual(KeyGateState.after(.unreachable), .unchecked, "no answer leaves the key in use")
        XCTAssertEqual(KeyGateState.after(.empty), .unchecked)
    }
}
