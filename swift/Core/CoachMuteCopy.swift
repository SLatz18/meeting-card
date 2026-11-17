import Foundation

/// Why the coach card's Mute in Zoom control can't act. Raw values match ListenMoreKit's `MuteUnavailableReason`;
/// the App maps one to the other with an exhaustive switch (`CoachController.muteDisabledReason`).
public enum MuteDisabledReason: String, CaseIterable, Sendable {
    case toggleOff
    case permissionDenied
    case noZoomCall
    case meet
}

/// How a host surface (the card, the pill) shows the coach's Mute control.
public struct MuteControlPresentation: Equatable, Sendable {
    public enum Visibility: Equatable, Sendable {
        case enabled
        case disabled
        /// Not shown at all (nothing to mute): no tooltip, no accessibility element.
        case hidden
    }

    public var visibility: Visibility
    public var tooltip: String?
    public var accessibilityLabel: String?
    /// Why it's disabled, for VoiceOver (the same text as the tooltip).
    public var accessibilityHelp: String?
    /// The copy key of the disabled text, if any.
    public var disabledKey: String?
}

/// Copy for the coach card's Mute in Zoom control, which presses Zoom's own mute. It is never the
/// coach's own Mute (the menu's Mute My Mic for Coach), so every line names Zoom or Meet and none is
/// a bare Mute. Disabled texts are keyed for a future strings table.
public enum CoachMuteCopy {
    public static let disabledOffKey = "coach.mute.disabled.off"
    public static let disabledPermissionKey = "coach.mute.disabled.permission"
    public static let disabledMeetKey = "coach.mute.disabled.meet"
    /// VoiceOver's label in a Meet call (the tooltip stays `disabledMeetKey`'s text).
    public static let accessibilityDisabledMeetKey = "coach.a11y.mute.disabled.meet"

    public static let strings: [String: String] = [
        disabledOffKey: "Turn on \"Use Zoom/Meet controls\" in Settings to mute in Zoom from here.",
        disabledPermissionKey: "Allow MeetingCard in Privacy & Security to mute in Zoom from here.",
        disabledMeetKey: "Meet can't be muted from here. Mute in the Meet window.",
        accessibilityDisabledMeetKey: "Mute in Zoom is unavailable in a Meet call. Mute in the Meet window.",
    ]

    public static let muteTooltip = "Mute in Zoom"
    public static let unmuteTooltip = "Unmute in Zoom"
    public static let muteAccessibilityLabel = "Mute your mic in Zoom"
    public static let unmuteAccessibilityLabel = "Unmute your mic in Zoom"

    /// The disabled text's key for `reason`; nil for `noZoomCall`, which hides the control instead.
    public static func disabledKey(_ reason: MuteDisabledReason) -> String? {
        switch reason {
        case .toggleOff: disabledOffKey
        case .permissionDenied: disabledPermissionKey
        case .meet: disabledMeetKey
        case .noZoomCall: nil
        }
    }

    /// - Parameters:
    ///   - reason: nil when the control can act.
    ///   - isMuted: Zoom's mute reading (the control offers Unmute while muted).
    public static func presentation(reason: MuteDisabledReason?, isMuted: Bool) -> MuteControlPresentation {
        let tooltip = isMuted ? unmuteTooltip : muteTooltip
        let label = isMuted ? unmuteAccessibilityLabel : muteAccessibilityLabel
        guard let reason else {
            return MuteControlPresentation(visibility: .enabled, tooltip: tooltip, accessibilityLabel: label,
                                           accessibilityHelp: nil, disabledKey: nil)
        }
        guard let key = disabledKey(reason), let text = strings[key] else {
            return MuteControlPresentation(visibility: .hidden, tooltip: nil, accessibilityLabel: nil,
                                           accessibilityHelp: nil, disabledKey: nil)
        }
        // In a Meet call there is no Zoom mic to name: VoiceOver gets its own Meet label.
        let a11y = reason == .meet ? strings[accessibilityDisabledMeetKey] : label
        return MuteControlPresentation(visibility: .disabled, tooltip: text, accessibilityLabel: a11y,
                                       accessibilityHelp: text, disabledKey: key)
    }
}
