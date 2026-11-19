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
}
