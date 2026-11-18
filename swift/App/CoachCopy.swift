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
    static let coachMuted = "Coach paused while you're muted in Zoom"
    static let chipMuted = "Muted in Zoom"
    static let callControlsToggle = "Use Zoom/Meet controls"
    static let callControlsHelp = "Stops the coach a few seconds after you leave a Zoom call or close a Meet tab, and pauses it while you're muted in Zoom. Reads only Zoom's meeting controls and whether a Meet tab is open: never titles, names, chat or other tabs. Lets the Mute in Zoom button on the coach card mute your Zoom mic. Off by default."
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
    static let menuShowCoachLog = "Show Coach Log"
    static let menuShowCoachLogHelp = "Shows the coach's local diagnostics file in Finder. It lists event names, times, device and app names, error codes and counts. Never transcript text, audio or your key. Old entries are removed after a few days."
    static let menuVersion = "Version"
    static let menuVersionUnknown = "unknown"
    static let menuQuit = "Quit"
    static let menuOff = "Call coach: off"
    static let menuWaiting = "Coach on, waiting for a call"
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

    // MARK: Final copy (VP Comms): onboarding privacy and the caption feed

    static let onboardingPrivacyBody = "While the coach is on, call audio goes to OpenAI on your own API key. Nothing is saved unless you choose to. Live captions are optional and stay in memory only. Saving a transcript is a separate choice. Your key stays in the Keychain."
    static let captionsYou = "You"
    static let captionsThem = "Them"
    static let captionsHeader = "Live captions"
    static let captionsEmpty = "Captions will show here once someone talks."
    static let captionsNote = "Kept in memory only. Not saved."
    /// Only while the Save transcripts switch is on.
    static let captionsNoteSaving = "Saving a transcript for this call."

    // MARK: DRAFT: captions and saved transcripts (not yet copy-reviewed; edit before release)

    /// Set while any string below is still a draft; the notice sheet shows a draft marker while true.
    static let transcriptCopyIsDraft = true
    static let transcriptSection = "Captions and transcript"
    static let captionsToggle = "Live captions"
    static let captionsHelp = "Shows what's being said on the meeting card during your call. Captions stay in memory and are gone when the call ends."
    static let saveToggle = "Save transcripts"
    static let saveHelp = "Saves one text file per call, with times and speaker labels. Audio is never saved."
    static let transcriptNeedsKey = "Needs an OpenAI API key: captions and transcripts use the same transcription as the GPT cues."
    static let folderLabel = "Folder"
    static let chooseFolder = "Choose\u{2026}"
    static let savingNow = "Saving transcript"
    static let savedLast = "Last transcript saved"
    static let saveFailed = "Couldn't save the transcript. Saving is off for this call."
    static let transcriptDeleted = "Transcript deleted. Nothing more is saved for this call."
    static let deleteTranscript = "Delete Transcript"
    static let deleteConfirmTitle = "Delete this transcript?"
    static let deleteConfirmBody = "The file is removed from your Mac. This can't be undone."
    static let delete = "Delete"
    static let cancel = "Cancel"
    static let speakerNames = "Speaker names for this call"
    static let speakerNamesHelp = "Rename \u{201C}You\u{201D} or \u{201C}Them\u{201D} for this call only. Names are kept only in a saved transcript."
    static let captionsStopped = "Captions stopped: this call reached its cost limit. On-device cues continue."
    static let captionsStoppedError = "Captions stopped: OpenAI transcription is unavailable. On-device cues continue."
    static let costLine = "This call: %@ of %@ (transcription %@, GPT cues %@). Captions and transcript add %@."
    static let costNone = "This call: no OpenAI usage yet."
    static let menuSaving = "Saving transcript"
    static let menuDeleteTranscript = "Delete Transcript\u{2026}"

    static let noticeDraftMarker = "Draft wording"
    static let noticeTitle = "Others on this call will be transcribed"
    static let noticeBody = "Captions and saved transcripts include what everyone on the call says, not just you. The audio is sent to OpenAI for transcription using your API key. You are responsible for telling the other people on the call and for following the laws where you and they are, and any policies that apply to you, such as your employer's."
    static let noticeConfirm = "I Understand, Turn On"
    static let noticeCancel = "Not Now"

    // MARK: Final copy (VP Comms): the coach menu's Start/Stop toggle and its Mute, mic only

    static let menuStart = "Start Coach"
    static let menuStop = "Stop Coach"
    static let menuMute = "Mute My Mic for Coach"
    static let menuUnmute = "Unmute My Mic for Coach"
    static let menuMuteHelp = "The coach stops hearing your mic. It still hears the others. This doesn't mute you in Zoom or Meet."
    static let menuUnmuteHelp = "The coach hears your mic again."
    static let coachMicOff = "Coach is hearing others only"
    static let chipMicOff = "Coach can't hear you"
    static let micMutedAnnouncement = "Call coach stopped hearing your mic. It still hears the others."
    static let micUnmutedAnnouncement = "Call coach hears your mic again."

    // MARK: The hidden Edit menu (`EditMenu`): never drawn, so these names only label its key
    // equivalents for macOS (standard macOS wording)

    static let editMenu = "Edit"
    static let editUndo = "Undo"
    static let editRedo = "Redo"
    static let editCut = "Cut"
    static let editCopy = "Copy"
    static let editPaste = "Paste"
    static let editSelectAll = "Select All"

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
               body: CoachCopy.onboardingPrivacyBody,
               primary: "Next", secondary: nil),
        Screen(title: "Turn it on",
               body: "Turn it on and allow mic and system audio access. Add your OpenAI API key for GPT cues; without one, the on-device cues still run. The coach starts by itself when a call starts, and you can pause it anytime from the coach chip on the meeting card or the coach menu in the menu bar.",
               primary: "Add key", secondary: "Not now"),
    ]
}
