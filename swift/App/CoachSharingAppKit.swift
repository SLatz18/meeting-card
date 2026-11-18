import AppKit
import MeetingCardCore

extension CoachSurface.Sharing {
    /// The window server's setting for this: left out of captures, or readable by them.
    var windowSharingType: NSWindow.SharingType {
        switch self {
        case .excluded: .none
        case .shared: .readOnly
        }
    }
}

extension CoachCardPanel: SharingWindow {
    var sharing: CoachSurface.Sharing {
        get { sharingType == .readOnly ? .shared : .excluded }
        set { sharingType = newValue.windowSharingType }
    }
}
