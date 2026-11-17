import AppKit
import MeetingCardCore

/// "Send Feedback…" in the coach menu and Settings: the public-issue notice (unless turned off), then
/// the pre-filled issue form in the default browser. Opening the URL is the only thing it does.
@MainActor
enum FeedbackAction {
    static func send(defaults: UserDefaults, identity: AppIdentity = .current) {
        let notice = FeedbackNotice(defaults: defaults, identity: identity)
        if notice.shouldShow {
            let alert = noticeAlert()
            NSApp.activate()
            let choice: FeedbackNotice.Choice = alert.runModal() == .alertFirstButtonReturn ? .continue : .cancel
            guard notice.resolve(choice, dontShowAgain: alert.suppressionButton?.state == .on) else { return }
        }
        NSWorkspace.shared.open(Feedback.url(.current(identity: identity)))
    }

    /// One line, Open GitHub (Return) and Cancel (Esc), and a "Don't show again" checkbox.
    static func noticeAlert() -> NSAlert {
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.messageText = FeedbackCopy.notice
        alert.informativeText = ""
        alert.addButton(withTitle: FeedbackCopy.noticeOpen)
        alert.addButton(withTitle: FeedbackCopy.noticeCancel)
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = FeedbackCopy.dontShowAgain
        return alert
    }
}
