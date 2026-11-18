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

    // MARK: when the notice opens

    /// Never during a live call: not at an enable, not at a call start, and not when it falls due mid-call.
    func testTheNoticeNeverOpensDuringALiveCall() {
        var t = CoachSelfPivot.NoticeTiming()
        XCTAssertFalse(t.shouldOpen(due: true, enabledNow: true, callStarting: false, callLive: true), "enabled mid-call")
        XCTAssertFalse(t.shouldOpen(due: true, enabledNow: false, callStarting: false, callLive: true), "due mid-call")
        // A call that skips the pre-warm (manual Start) goes live at once: nothing opens through it.
        for _ in 0..<5 { XCTAssertFalse(t.shouldOpen(due: true, enabledNow: false, callStarting: false, callLive: true)) }
        XCTAssertFalse(t.shouldOpen(due: true, enabledNow: false, callStarting: false, callLive: false), "the call ended: wait for a moment")
        XCTAssertTrue(CoachSelfPivot.NoticeTiming.shouldClose(callLive: true, openedFromSettings: false), "a call goes live: it comes down")
        XCTAssertFalse(CoachSelfPivot.NoticeTiming.shouldClose(callLive: false, openedFromSettings: false))
        XCTAssertFalse(CoachSelfPivot.NoticeTiming.shouldClose(callLive: true, openedFromSettings: true), "opened on request: it stays")
    }

    /// It opens at the next coach enable or call start (pre-warmed, before the session is live), whichever
    /// comes first; not at launch or any other refresh, and once per call start.
    func testTheNoticeOpensAtTheNextEnableOrCallStart() {
        var launch = CoachSelfPivot.NoticeTiming()
        XCTAssertFalse(launch.shouldOpen(due: true, enabledNow: false, callStarting: false, callLive: false), "launch or a key saved: wait")
        XCTAssertTrue(launch.shouldOpen(due: true, enabledNow: true, callStarting: false, callLive: false), "the coach turned on")

        var call = CoachSelfPivot.NoticeTiming()
        XCTAssertFalse(call.shouldOpen(due: true, enabledNow: false, callStarting: false, callLive: false))
        XCTAssertTrue(call.shouldOpen(due: true, enabledNow: false, callStarting: true, callLive: false), "a call starts")
        XCTAssertFalse(call.shouldOpen(due: true, enabledNow: false, callStarting: true, callLive: false), "once per call start")
        XCTAssertFalse(call.shouldOpen(due: true, enabledNow: false, callStarting: false, callLive: true), "then the call is live")
        XCTAssertFalse(call.shouldOpen(due: true, enabledNow: false, callStarting: false, callLive: false))
        XCTAssertTrue(call.shouldOpen(due: true, enabledNow: false, callStarting: true, callLive: false), "the next call start")

        var answered = CoachSelfPivot.NoticeTiming()
        XCTAssertFalse(answered.shouldOpen(due: false, enabledNow: true, callStarting: true, callLive: false), "not due: never")
    }

    /// Until the notice is answered the cue stays off, whether it was never shown, is up, or came down when a call
    /// went live; answering it (either button) turns the cue on.
    func testSelfPivotStaysOffUntilTheNoticeIsAnswered() {
        var t = CoachSelfPivot.NoticeTiming()
        defaults.set(true, forKey: "coach.enabled")
        func due() -> Bool {
            CoachSelfPivot.noticeDue(coachEnabled: true, state: .available(on: CoachSelfPivot.isOn(defaults)), seen: CoachSelfPivot.noticeSeen(defaults))
        }
        XCTAssertFalse(t.shouldOpen(due: due(), enabledNow: false, callStarting: false, callLive: true))
        XCTAssertFalse(CoachSelfPivot.allowed(defaults), "mid-call, not shown: off")
        XCTAssertTrue(t.shouldOpen(due: due(), enabledNow: false, callStarting: true, callLive: false))
        XCTAssertFalse(CoachSelfPivot.allowed(defaults), "shown, not answered: off")
        XCTAssertTrue(CoachSelfPivot.NoticeTiming.shouldClose(callLive: true, openedFromSettings: false))
        XCTAssertFalse(CoachSelfPivot.allowed(defaults), "came down unanswered: off")
        defaults.set(true, forKey: CoachSelfPivot.Keys.noticeSeen)
        XCTAssertTrue(CoachSelfPivot.allowed(defaults), "answered: on")
        XCTAssertFalse(due(), "and it doesn't open again on its own")
    }

    func testFinalCopy() {
        let c = CoachSelfPivot.Copy.self
        XCTAssertEqual(c.toggle, "Remind me to ask back")
        XCTAssertEqual(c.help, "Call coach nudges you when you answer someone with your own story and don't ask back. To check each moment, it sends a short part of the call transcript to the AI provider you set up. On group calls, this can include what others said. The provider is asked not to store it. Call audio is never saved.")
        XCTAssertEqual(c.noticeTitle, "New: ask-back cue")
        XCTAssertEqual(c.noticeBody, "Call coach can nudge you when you turn the talk to yourself. To check each moment, it sends a short part of the call transcript to the AI provider you set up. This can include what others said. The provider is asked not to store it, and call audio is never saved. You can turn this cue off in Settings.")
        XCTAssertEqual(c.noticeConfirm, "Got it")
        XCTAssertEqual(c.noticeOpenSettings, "Open Settings")
        XCTAssertEqual(c.unsupportedJudge, "Off for now. The AI provider you set up can't check this cue yet.")
        XCTAssertEqual(c.showNoticeAgain, "Show Notice Again")
        XCTAssertEqual(CoachCardCopy.SelfPivot.words, "Ask about them")
        XCTAssertEqual(CoachCardCopy.SelfPivot.announcement, "Call coach: ask the other person about what they shared.")
    }

    /// Generic: no company, product or app names and no people. Every capitalized word is a sentence start or
    /// one of the UI's own words.
    func testCopyStaysGeneric() {
        let c = CoachSelfPivot.Copy.self
        let all = [c.toggle, c.help, c.noticeTitle, c.noticeBody, c.noticeConfirm, c.noticeOpenSettings, c.unsupportedJudge, c.showNoticeAgain,
                   CoachCardCopy.SelfPivot.words, CoachCardCopy.SelfPivot.announcement]
        let banned = ["openai", "typesafe", "gpt", "zoom", "meet", "teams", "google", "microsoft", "slack", "webex", "facetime",
                      "apple", "meetingcard", "chrome", "dia", "off by default"]
        let allowedCaps: Set<String> = ["Call", "New", "You", "The", "To", "On", "This", "Got", "Open", "Settings", "Off", "AI",
                                        "Remind", "Ask", "Show", "Notice", "Again"]
        for s in all {
            let words = s.split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
            for w in words {
                XCTAssertFalse(banned.contains(w.lowercased()), "\(w) in \(s)")
                if let first = w.first, first.isUppercase { XCTAssertTrue(allowedCaps.contains(w), "\(w) in \(s)") }
            }
            XCTAssertFalse(s.lowercased().contains("off by default"), s)
            XCTAssertFalse(s.lowercased().contains("placeholder") || s.contains("["), "final copy: \(s)")
        }
    }

    // MARK: wiring (the App target reads these; hostless tests read its sources)

    static let swiftDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    func read(_ path: String) throws -> String { try String(contentsOf: Self.swiftDir.appendingPathComponent(path), encoding: .utf8) }

    /// The controller feeds `NoticeTiming` on every refresh with the coach's live-call state (a running session)
    /// and its call start (pre-warmed), marks a coach enable, and takes down a notice that opened on its own
    /// when a call goes live. Only an answer marks it seen.
    func testTheControllerTimesTheNotice() throws {
        let c = try read("App/CoachController.swift")
        XCTAssertTrue(c.contains("let live = enabled && Self.isLiveCall(indicator)"))
        XCTAssertTrue(c.contains("selfPivotNoticeTiming.shouldOpen(due: due, enabledNow: enabledNow, callStarting: enabled && indicator == .on,"))
        XCTAssertTrue(c.contains("case .listening, .paused, .muted, .micOff: true\n        case .hidden, .on: false"))
        XCTAssertTrue(c.contains("CoachSelfPivot.NoticeTiming.shouldClose(callLive: live, openedFromSettings: selfPivotNoticeFromSettings)"))
        XCTAssertTrue(c.contains("keyProblem = nil\n        enabledSinceRefresh = true\n        refresh()"), "a coach enable is a moment")
        let refresh = try XCTUnwrap(c.components(separatedBy: "    func refresh() {").dropFirst().first?.components(separatedBy: "\n    }\n").first)
        XCTAssertTrue(refresh.contains("updateSelfPivotNotice()"))
        XCTAssertEqual(c.components(separatedBy: "forKey: CoachSelfPivot.Keys.noticeSeen)").count - 1, 1, "set in one place: the answer")
        XCTAssertFalse(c.contains("showSelfPivotNoticeIfDue"), "nothing opens it outside its moments")
    }

    /// Settings' Show Notice Again, under the switch, opens the notice (also checked at run time by the snapshot
    /// run: UISnapshots.selfPivotNoticeCheck).
    func testShowNoticeAgainOpensTheNotice() throws {
        let settings = try read("App/CoachSettingsWindow.swift")
        XCTAssertTrue(settings.contains("let showNoticeAgainButton = NSButton(title: CoachSelfPivot.Copy.showNoticeAgain, target: nil, action: nil)"))
        XCTAssertTrue(settings.contains("showNoticeAgainButton.action = #selector(showNoticeAgain(_:))"))
        XCTAssertTrue(settings.contains("let g = Self.group([row, help, showNoticeAgainButton, selfPivotNote])"), "under the switch")
        XCTAssertTrue(settings.contains("@objc private func showNoticeAgain(_ sender: Any?) {\n        coach.showSelfPivotNotice()\n    }"))
        let c = try read("App/CoachController.swift")
        let show = try XCTUnwrap(c.components(separatedBy: "func showSelfPivotNotice(fromSettings: Bool = true) {").dropFirst().first?
            .components(separatedBy: "\n    }\n").first)
        XCTAssertTrue(show.contains("CoachNotice(content: .selfPivot)"))
        XCTAssertTrue(show.contains("notice.presentAlone()"))
        let snapshots = try read("scripts/snapshots.sh")
        XCTAssertTrue(snapshots.contains("coach check self-pivot-reopen-$a before=closed opened=yes title=ok"))
        XCTAssertTrue(try read("App/UISnapshots.swift").contains("coach.settingsWindow?.showNoticeAgainButton.performClick(nil)"))
    }
}
