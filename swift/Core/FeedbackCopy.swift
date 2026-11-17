import Foundation

/// Every user-facing "Send feedback" string: the menu item, the Settings row, the public-issue
/// notice and the GitHub issue form. `.github/ISSUE_TEMPLATE/feedback.yml` repeats the `Form`
/// strings (GitHub reads them from there); FeedbackTests fails if the two drift apart.
/// Final copy from comms review.
public enum FeedbackCopy {
    public static let menuItem = "Send Feedback\u{2026}"
    public static let settingsLabel = "Feedback"
    public static let settingsHelp = "Opens a new public issue on GitHub in your browser."
    public static let settingsButton = "Send Feedback\u{2026}"

    /// One line in the alert: at its fixed width that's about 25 characters.
    public static let notice = "GitHub issues are public."
    public static let noticeOpen = "Open GitHub"
    public static let noticeCancel = "Cancel"
    public static let dontShowAgain = "Don't show again"

    /// The issue form's name, intro and field labels.
    public enum Form {
        public static let name = "App feedback"
        public static let description = "Opened from Send Feedback in MeetingCard."
        public static let intro = "This issue is public. Leave out meeting details, names and log contents."
        public static let whatHappened = "What happened"
        public static let whatExpected = "What you expected"
        public static let appVersion = "App version"
        public static let buildNumber = "Build number"
        public static let macOSVersion = "macOS version"
        public static let buildType = "Build type"
        public static let all = [name, description, intro, whatHappened, whatExpected, appVersion, buildNumber, macOSVersion, buildType]
    }

    /// Pre-filled values of the form's Build type field (they show in the public issue).
    public static let buildRelease = "Release"
    public static let buildTestId = "Test"
    /// A pre-filled value the app couldn't read.
    public static let unknown = "Unknown"
}
