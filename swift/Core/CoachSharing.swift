import Foundation

/// A window whose presence in screenshots and screen recordings the coach setting controls.
public protocol SharingWindow: AnyObject {
    var sharing: CoachSurface.Sharing { get set }
}

/// Keeps every coach window's capture setting in step with "Show Coach in Screenshots": a window
/// registered now gets the current setting, and turning the setting on or off updates every window still
/// open, with no relaunch. Windows are held weakly.
public final class SharingRegistry {
    private struct Entry { weak var window: SharingWindow? }

    public private(set) var showInScreenshots: Bool
    private var entries: [Entry] = []

    public init(showInScreenshots: Bool = CoachSurface.showInScreenshotsDefault) {
        self.showInScreenshots = showInScreenshots
    }

    /// What a coach window shows to captures under the current setting.
    public var sharing: CoachSurface.Sharing { CoachSurface.card.sharing(showInScreenshots: showInScreenshots) }

    public func register(_ window: SharingWindow) {
        entries.removeAll { $0.window == nil }
        entries.append(Entry(window: window))
        window.sharing = sharing
    }

    /// Applies the setting to every open window; returns how many were updated.
    @discardableResult
    public func set(showInScreenshots on: Bool) -> Int {
        showInScreenshots = on
        entries.removeAll { $0.window == nil }
        for entry in entries { entry.window?.sharing = sharing }
        return entries.count
    }

    /// The reminder card's own window: shown to captures like any card, except while it carries the coach chip,
    /// when it follows the setting.
    public static func reminderCardSharing(chipShown: Bool, showInScreenshots: Bool) -> CoachSurface.Sharing {
        chipShown ? CoachSurface.card.sharing(showInScreenshots: showInScreenshots) : .shared
    }
}
