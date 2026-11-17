import AppKit
import MeetingCardCore
import SwiftUI

/// The coach card's captions area. The app's card uses `CaptionFeedSlot` (#13c's caption feed);
/// the placeholder shows the empty-state line where no feed is wired (the card's own snapshots).
/// The card asks once per presentation and keeps the view (it moves between card layouts, never
/// rebuilt).
@MainActor
protocol CoachCaptionsSlot: AnyObject {
    func makeView() -> NSView
}

@MainActor
final class CoachCaptionsPlaceholder: CoachCaptionsSlot {
    func makeView() -> NSView {
        let f = NSTextField(wrappingLabelWithString: CoachCardCopy.Captions.empty)
        f.font = Theme.font(Theme.CoachCard.captionsFont)
        f.textColor = Theme.text(Theme.CoachCard.captionsText, Theme.style(dark: Theme.isDark))
        f.isSelectable = false
        f.setAccessibilityLabel(CoachCardCopy.Captions.empty)
        return f
    }
}

/// #13c's live captions in the card: `CaptionFeedView`'s card layout over `CoachTranscript.feed`,
/// which the transcript keeps current (empty while captions are off).
@MainActor
final class CaptionFeedSlot: CoachCaptionsSlot {
    let model: CaptionFeedModel

    init(model: CaptionFeedModel) {
        self.model = model
    }

    func makeView() -> NSView {
        let v = NSHostingView(rootView: CaptionFeedView(model: model, layout: .card))
        v.sizingOptions = []
        return v
    }
}
