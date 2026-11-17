import Foundation
import ListenMoreCore

/// User-facing call coach strings (approved copy; edits only where the build differs, see the PR).
enum CoachCopy {
    static let section = "Call Coach"
    static let toggle = "Call coach"
    static let toggleHelp = "A small card turns red when you interrupt or talk over someone, and amber when you miss a question. Only you see it. Off by default."
    static let keyLabel = "OpenAI API key"
    static let keyPlaceholder = "sk-\u{2026}"
    static let keySavedPlaceholder = "Saved in your Keychain"
    static let keyHelp = "Call audio goes to OpenAI on this key, only while the coach is on. The key is stored in your Keychain."
    static let keyEmpty = "No key saved. Call coach runs its on-device cues; add a key for GPT cues."
    static let keyRejected = "OpenAI didn't accept this key. Check it and try again."
    static let storedKeyRejected = "OpenAI didn't accept the saved key. GPT cues are off; the on-device cues still run."
    static let gptOffNoKey = "GPT cues are off until you add an OpenAI API key. The on-device cues still run."
    static let keyUnreachable = "Can't reach OpenAI right now. Call coach will try again on your next call."
    static let coachOn = "Coach on"
    static let coachPaused = "Coach paused"
    static let coachListening = "Coach on, listening"
    static let coachMuted = "Coach paused while you're muted"
    static let chipMuted = "Muted"
    static let callControlsToggle = "Use Zoom/Meet controls"
    static let callControlsHelp = "Stops the coach a few seconds after you leave a Zoom call or close a Meet tab, and pauses it while you're muted in Zoom. Reads only Zoom's meeting controls and whether a Meet tab is open: never titles, names, chat or other tabs. With Accessibility it can also press Zoom's own Mute button when you ask. Off by default."
    static let requestAccess = "Request access"
    static let callControlsDiaUnsupported = "This version of Dia can't share its tabs, so for Dia the coach goes by audio activity."

    /// The permission explainer under the toggle, naming only what is still missing.
    static func callControlsNeeds(accessibility: Bool, automation: [String]) -> String? {
        var parts: [String] = []
        if accessibility { parts.append("Accessibility (for Zoom)") }
        if !automation.isEmpty { parts.append("Automation (for \(automation.joined(separator: " and ")))") }
        guard !parts.isEmpty else { return nil }
        return "Allow MeetingCard under \(parts.joined(separator: " and ")) in System Settings > Privacy & Security. Until then the coach goes by audio activity."
    }
    static let menuOff = "Call coach: off"
    static let menuWaiting = "Coach on, waiting for a call"
    static let menuEnable = "Turn On Call Coach"
    static let menuTurnOff = "Turn Off Call Coach"
    static let menuGptOffNoKey = "GPT cues off: no API key"
    static let menuGptOffRejected = "GPT cues off: key not accepted"
    static let pause = "Pause"
    static let resume = "Resume"
    static let startNow = "Start now"
    static let settings = "Settings\u{2026}"
    static let allowedApps = "Allowed apps"
    static let add = "Add"
    static let remove = "Remove"
    static let anyApp = "Coach any app that uses the mic and speakers"
    static let privacy = "When the coach is on with an API key, call audio is sent to OpenAI for analysis. Without a key, only the on-device cues run."
    static let pausedPrivacy = "No audio is sent while paused."
    static let permissionDenied = "Call coach needs mic and system audio access. You can turn these on in System Settings > Privacy & Security."
    static let judgeLabel = "Cue judge"
    static let judgeGpt = "OpenAI GPT"
    static let judgeTypeSafe = "TypeSafe System One"
    static let judgeHelpGpt = "OpenAI decides when your reply brushes past someone's point. This is the default."
    static let judgeHelpTypeSafe = "TypeSafe decides heated replies, missed questions and brushed-past points. A short, redacted transcript window around your reply goes to TypeSafe on your TypeSafe key. Transcription stays with OpenAI."
    static let typeSafeKeyLabel = "TypeSafe API key"
    static let typeSafeKeyPlaceholder = "TypeSafe API key"
    static let typeSafeKeySavedPlaceholder = "TypeSafe key saved in your Keychain"
    static let typeSafeKeyMissing = "Nothing is judged until you add a TypeSafe API key. The transcript rules and on-device cues still run."

    /// Why judging stopped: the failure's kind and status code only, never key text.
    static func judgeStopped(_ failure: JudgeFailure) -> String {
        let why: String, advice: String
        switch failure.kind {
        case .auth: (why, advice) = ("TypeSafe didn't accept the key", " Check the key and save it again.")
        case .balance: (why, advice) = ("TypeSafe reports no balance left on the account", "")
        case .rateLimited: (why, advice) = ("TypeSafe is limiting requests right now", "")
        case .server: (why, advice) = ("TypeSafe had a server problem", "")
        case .rejected: (why, advice) = ("TypeSafe turned the request down", "")
        case .timeout: (why, advice) = ("TypeSafe didn't answer in time", "")
        case .unreachable: (why, advice) = ("Couldn't reach TypeSafe", "")
        case .badReply: (why, advice) = ("TypeSafe's reply couldn't be read", "")
        }
        var code = ""
        if case .http(let status) = failure { code = " (HTTP \(status))" }
        return "Judging stopped for this call: \(why)\(code).\(advice) The transcript rules and on-device cues still run."
    }

    struct Screen {
        let title: String
        let body: String
        let primary: String
        let secondary: String?
    }

    static let onboarding: [Screen] = [
        Screen(title: "Meet Call Coach",
               body: "A quiet nudge on your calls. A small card shows a short tip. It turns red if you interrupt or talk over someone, and amber if you miss a question. Only you see it.",
               primary: "Next", secondary: nil),
        Screen(title: "Your audio stays yours",
               body: "While the coach is on, call audio goes to OpenAI on your own API key. Nothing is saved: no transcripts, no stats, no recaps. Your key stays in the Keychain.",
               primary: "Next", secondary: nil),
        Screen(title: "Turn it on",
               body: "Turn it on and allow mic and system audio access. Add your OpenAI API key for GPT cues; without one, the on-device cues still run. The coach starts by itself when a call starts, and you can pause it anytime from the coach chip on the meeting card or the coach menu in the menu bar.",
               primary: "Add key", secondary: "Not now"),
    ]
}
