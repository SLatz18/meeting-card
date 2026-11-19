import Foundation

/// Which window the call coach ties a call to. The one place the `callWindowBinding` flag is read:
/// `CoachController` asks `resolve` once and builds the window tracker only for `.boundWindow`.
public enum CallWindowRule: Equatable, Sendable {
    /// Main's behavior: the glow goes to the display of the call app's largest on-screen window, and
    /// Zoom reads as in a meeting only while its menu shows the in-meeting shortcuts.
    case largestWindow
    /// The call's own window (the meeting window, never an app's home window) decides the glow's
    /// display, and Zoom stays in a meeting while that window exists (see the Kit README).
    case boundWindow

    public static func resolve(_ flags: FeatureFlags) -> CallWindowRule {
        flags.isEnabled(.callWindowBinding) ? .boundWindow : .largestWindow
    }
}
