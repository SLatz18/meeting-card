import Foundation

/// MeetingCard's ask-back cue (the coach's self_pivot cue): its Settings switch, the one-time notice that comes
/// before it, and its copy. Inside the opt-in coach and with a usable key the cue is on by default, but it
/// sends nothing and shows nothing until the notice has been shown once. It runs only on a cue judge that can
/// check it; on any other, it is off and Settings says so. Two settings in UserDefaults, never call data.
public enum CoachSelfPivot {
    public enum Keys {
        /// The Settings switch; missing means on.
        public static let on = "coach.selfPivot"
        /// The notice was shown and answered.
        public static let noticeSeen = "coach.selfPivotNoticeSeen"
    }

    /// What Settings shows for the switch.
    public enum State: Equatable, Sendable {
        /// The coach's build ships the cue disabled (the rollback line in `CoachController.configOverrides`).
        case notShipped
        /// The cue judge the user picked can't check this cue: off, with a note.
        case unsupportedJudge
        /// No usable key: nothing to check it with (the switch is shown, dimmed).
        case needsKey
        /// The user's switch.
        case available(on: Bool)
    }

    public static func isOn(_ defaults: UserDefaults) -> Bool {
        defaults.object(forKey: Keys.on) as? Bool ?? true
    }

    public static func noticeSeen(_ defaults: UserDefaults) -> Bool {
        defaults.bool(forKey: Keys.noticeSeen)
    }

    /// The engine's switch, read before every self-pivot step: the user's switch is on and the notice has
    /// been shown. (The engine adds the rest: a key, a judge that can check it, the cue not disabled.)
    public static func allowed(_ defaults: UserDefaults) -> Bool {
        isOn(defaults) && noticeSeen(defaults)
    }

    public static func state(shipped: Bool, judgeSupports: Bool, keyUsable: Bool, on: Bool) -> State {
        guard shipped else { return .notShipped }
        guard judgeSupports else { return .unsupportedJudge }
        guard keyUsable else { return .needsKey }
        return .available(on: on)
    }

    /// The notice is due: the coach is on with a usable key, the cue is shipped, the judge can check it and the
    /// switch is on, and it hasn't been shown yet. This holds for a new enable and for anyone who already had
    /// the coach on, before anything is sent.
    public static func noticeDue(coachEnabled: Bool, state: State, seen: Bool) -> Bool {
        guard coachEnabled, !seen else { return false }
        return state == .available(on: true)
    }

    /// Signed-off copy. Generic by design: no company or product names, no people.
    public enum Copy {
        public static let toggle = "Remind me to ask back"
        public static let help = "Call coach nudges you when you answer someone with your own story and don't ask back. To check each moment, it sends a short part of the call transcript to the AI provider you set up. On group calls, this can include what others said. The provider is asked not to store it. Call audio is never saved."
        public static let noticeTitle = "New: ask-back cue"
        public static let noticeBody = "Call coach can nudge you when you turn the talk to yourself. To check each moment, it sends a short part of the call transcript to the AI provider you set up. This can include what others said. The provider is asked not to store it, and call audio is never saved. You can turn this cue off in Settings."
        public static let noticeConfirm = "Got it"
        public static let noticeOpenSettings = "Open Settings"
        /// Under the switch while the picked cue judge can't check the cue. Not in the signed-off set:
        /// written to the same rules (short, generic) pending copy review.
        public static let unsupportedJudge = "Off: the cue judge you picked can't check this cue yet."
    }
}
