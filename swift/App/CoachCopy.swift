import Foundation

/// User-facing call coach strings (approved copy; edits only where the build differs, see the PR).
enum CoachCopy {
    static let section = "Call Coach"
    static let toggle = "Call coach"
    static let toggleHelp = "A quiet screen-edge glow when you interrupt, talk over someone, or miss a question. Off by default."
    static let keyLabel = "OpenAI API key"
    static let keyPlaceholder = "sk-\u{2026}"
    static let keySavedPlaceholder = "Saved in your Keychain"
    static let keyHelp = "Call audio goes to OpenAI on this key, only while the coach is on. The key is stored in your Keychain."
    static let keyEmpty = "Add an OpenAI API key to turn on Call coach."
    static let keyRejected = "OpenAI didn't accept this key. Check it and try again."
    static let keyUnreachable = "Can't reach OpenAI right now. Call coach will try again on your next call."
    static let coachOn = "Coach on"
    static let coachPaused = "Coach paused"
    static let pause = "Pause"
    static let resume = "Resume"
    static let startNow = "Start now"
    static let settings = "Settings\u{2026}"
    static let allowedApps = "Allowed apps"
    static let add = "Add"
    static let remove = "Remove"
    static let anyApp = "Coach any app that uses the mic and speakers"
    static let privacy = "When the coach is on, call audio is sent to OpenAI for analysis."
    static let pausedPrivacy = "No audio is sent while paused."
    static let permissionDenied = "Call coach needs mic and system audio access. You can turn these on in System Settings > Privacy & Security."

    struct Screen {
        let title: String
        let body: String
        let primary: String
        let secondary: String?
    }

    static let onboarding: [Screen] = [
        Screen(title: "Meet Call coach",
               body: "A quiet nudge on your calls. The edge of your screen glows red if you interrupt or talk over someone, and amber if you miss a question. Only you see it.",
               primary: "Next", secondary: nil),
        Screen(title: "Your audio stays yours",
               body: "While the coach is on, call audio goes to OpenAI on your own API key. Nothing is saved: no transcripts, no stats, no recaps. Your key stays in the Keychain.",
               primary: "Next", secondary: nil),
        Screen(title: "Turn it on",
               body: "Add your OpenAI API key and allow mic and system audio access. The coach starts by itself when a call starts, and you can pause it anytime from the coach chip on the meeting card, or from the menu bar while no card is showing.",
               primary: "Add key", secondary: "Not now"),
    ]
}
