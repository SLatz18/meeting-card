import XCTest
@testable import MeetingCardCore

/// The ask-back (self-pivot) cue's settings in MeetingCard: on by default inside the opt-in coach, nothing sent
/// or shown until its notice has been shown once (for a new enable and for anyone who already had the coach on),
/// off with a note on a cue judge that can't check it, and its signed-off copy, kept generic.
final class CoachSelfPivotTests: XCTestCase {
    var defaults: UserDefaults!
    var suite: String!

    override func setUp() {
        suite = "CoachSelfPivotTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suite)
    }

    func testOnByDefaultButNothingIsAllowedBeforeTheNotice() {
        XCTAssertTrue(CoachSelfPivot.isOn(defaults), "on by default")
        XCTAssertFalse(CoachSelfPivot.noticeSeen(defaults))
        XCTAssertFalse(CoachSelfPivot.allowed(defaults), "nothing is sent or shown before the notice")
        defaults.set(true, forKey: CoachSelfPivot.Keys.noticeSeen)
        XCTAssertTrue(CoachSelfPivot.allowed(defaults))
        defaults.set(false, forKey: CoachSelfPivot.Keys.on)
        XCTAssertFalse(CoachSelfPivot.allowed(defaults), "the Settings switch turns it off")
        defaults.set(true, forKey: CoachSelfPivot.Keys.on)
        XCTAssertTrue(CoachSelfPivot.allowed(defaults))
        XCTAssertEqual(CoachSelfPivot.Keys.on, "coach.selfPivot")
        XCTAssertEqual(CoachSelfPivot.Keys.noticeSeen, "coach.selfPivotNoticeSeen")
    }

    func testSettingsState() {
        typealias S = CoachSelfPivot
        XCTAssertEqual(S.state(shipped: false, judgeSupports: true, keyUsable: true, on: true), .notShipped)
        XCTAssertEqual(S.state(shipped: true, judgeSupports: false, keyUsable: true, on: true), .unsupportedJudge)
        XCTAssertEqual(S.state(shipped: true, judgeSupports: true, keyUsable: false, on: true), .needsKey)
        XCTAssertEqual(S.state(shipped: true, judgeSupports: true, keyUsable: true, on: false), .available(on: false))
        XCTAssertEqual(S.state(shipped: true, judgeSupports: true, keyUsable: true, on: true), .available(on: true))
    }

    /// The notice is due only while the cue could run: the coach on, a usable key, a judge that can check it,
    /// the switch on, and not yet shown. It is the same check for a new enable and for an existing user.
    func testTheNoticeIsDueBeforeAnythingIsSent() {
        typealias S = CoachSelfPivot
        let ready = S.State.available(on: true)
        XCTAssertTrue(S.noticeDue(coachEnabled: true, state: ready, seen: false))
        XCTAssertFalse(S.noticeDue(coachEnabled: false, state: ready, seen: false), "the coach stays opt-in")
        XCTAssertFalse(S.noticeDue(coachEnabled: true, state: ready, seen: true), "once")
        for state in [S.State.available(on: false), .needsKey, .unsupportedJudge, .notShipped] {
            XCTAssertFalse(S.noticeDue(coachEnabled: true, state: state, seen: false), "\(state)")
        }
        // An existing user: the coach was already on with a key before this build. The notice is due and,
        // until it is answered, the engine's switch is off.
        defaults.set(true, forKey: "coach.enabled")
        XCTAssertTrue(S.noticeDue(coachEnabled: defaults.bool(forKey: "coach.enabled"),
                                  state: S.state(shipped: true, judgeSupports: true, keyUsable: true, on: S.isOn(defaults)),
                                  seen: S.noticeSeen(defaults)))
        XCTAssertFalse(S.allowed(defaults))
    }

    func testFinalCopy() {
        let c = CoachSelfPivot.Copy.self
        XCTAssertEqual(c.toggle, "Remind me to ask back")
        XCTAssertEqual(c.help, "Call coach nudges you when you answer someone with your own story and don't ask back. To check each moment, it sends a short part of the call transcript to the AI provider you set up. On group calls, this can include what others said. The provider is asked not to store it. Call audio is never saved.")
        XCTAssertEqual(c.noticeTitle, "New: ask-back cue")
        XCTAssertEqual(c.noticeBody, "Call coach can nudge you when you turn the talk to yourself. To check each moment, it sends a short part of the call transcript to the AI provider you set up. This can include what others said. The provider is asked not to store it, and call audio is never saved. You can turn this cue off in Settings.")
        XCTAssertEqual(c.noticeConfirm, "Got it")
        XCTAssertEqual(c.noticeOpenSettings, "Open Settings")
        XCTAssertEqual(CoachCardCopy.SelfPivot.words, "Ask about them")
        XCTAssertEqual(CoachCardCopy.SelfPivot.announcement, "Call coach: ask the other person about what they shared.")
    }

    /// Generic: no company, product or app names and no people. Every capitalized word is a sentence start or
    /// one of the UI's own words.
    func testCopyStaysGeneric() {
        let c = CoachSelfPivot.Copy.self
        let all = [c.toggle, c.help, c.noticeTitle, c.noticeBody, c.noticeConfirm, c.noticeOpenSettings, c.unsupportedJudge,
                   CoachCardCopy.SelfPivot.words, CoachCardCopy.SelfPivot.announcement]
        let banned = ["openai", "typesafe", "gpt", "zoom", "meet", "teams", "google", "microsoft", "slack", "webex", "facetime",
                      "apple", "meetingcard", "chrome", "dia", "off by default"]
        let allowedCaps: Set<String> = ["Call", "New", "You", "The", "To", "On", "This", "Got", "Open", "Settings", "Off", "AI",
                                        "Remind", "Ask"]
        for s in all {
            let words = s.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
            for w in words {
                XCTAssertFalse(banned.contains(w.lowercased()), "\(w) in \(s)")
                if let first = w.first, first.isUppercase { XCTAssertTrue(allowedCaps.contains(w), "\(w) in \(s)") }
            }
            XCTAssertFalse(s.lowercased().contains("off by default"), s)
        }
    }
}
