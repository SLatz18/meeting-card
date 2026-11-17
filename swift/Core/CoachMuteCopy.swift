import Foundation

/// Why the coach card's Mute in Zoom control can't act. Raw values match ListenMoreKit's `MuteUnavailableReason`;
/// the App maps one to the other with an exhaustive switch (`CoachController.muteDisabledReason`). Any
/// reason hides the control: a greyed-out second mute beside the coach's own reads as broken.
public enum MuteDisabledReason: String, CaseIterable, Sendable {
    case toggleOff
    case permissionDenied
    case noZoomCall
    case meet
}

/// How a host surface (the card, the pill) shows the Mute in Zoom control.
public struct MuteControlPresentation: Equatable, Sendable {
    public enum Visibility: Equatable, Sendable {
        case enabled
        /// Not shown at all: no tooltip, no accessibility element.
        case hidden
    }

    public var visibility: Visibility
    public var tooltip: String?
    public var accessibilityLabel: String?
}

/// Copy for the coach card's Mute in Zoom control, which presses Zoom's own mute. It is never the
/// coach's own Mute (Mute My Mic for Coach), so every line names Zoom and none is a bare Mute. It
/// shows only while it can act: Use Zoom/Meet controls on, Accessibility granted, a Zoom call.
public enum CoachMuteCopy {
    public static let muteTooltip = "Mute in Zoom"
    public static let unmuteTooltip = "Unmute in Zoom"
    public static let muteAccessibilityLabel = "Mute your mic in Zoom"
    public static let unmuteAccessibilityLabel = "Unmute your mic in Zoom"

    /// - Parameters:
    ///   - reason: nil when the control can act; any reason hides it.
    ///   - isMuted: Zoom's mute reading (the control offers Unmute while muted).
    public static func presentation(reason: MuteDisabledReason?, isMuted: Bool) -> MuteControlPresentation {
        guard reason == nil else { return MuteControlPresentation(visibility: .hidden, tooltip: nil, accessibilityLabel: nil) }
        return MuteControlPresentation(visibility: .enabled, tooltip: isMuted ? unmuteTooltip : muteTooltip,
                                       accessibilityLabel: isMuted ? unmuteAccessibilityLabel : muteAccessibilityLabel)
    }
}
