import AppKit
import MeetingCardCore

/// The coach card's captions area. #13c's `CaptionFeedView(model:)` drops in by providing a slot
/// whose `makeView()` returns it; until then the placeholder shows the empty-state line. The card
/// asks once per presentation and keeps the view (it moves between card layouts, never rebuilt).
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
