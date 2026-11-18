import Foundation

/// Applies a state to a view only when it differs from the last one applied. The Settings window is
/// refreshed once a second; with nothing changed a refresh must touch no view, relayout nothing and
/// leave the scroll position alone (a refresh that re-applied everything snapped the window back to
/// the top, so it could not be scrolled).
public struct ChangeGate<State: Equatable>: Sendable where State: Sendable {
    public private(set) var applied: State?
    /// How many times a state was let through (tests).
    public private(set) var applications = 0

    public init() {}

    /// True when `state` is new (or nothing was applied yet); it is then recorded as applied.
    public mutating func shouldApply(_ state: State) -> Bool {
        guard applied != state else { return false }
        applied = state
        applications += 1
        return true
    }

    /// Applies unconditionally (a user action), recording the state.
    public mutating func force(_ state: State) {
        applied = state
        applications += 1
    }

    public mutating func reset() { applied = nil }
}

/// What decides the Settings window's size and scroll range.
public struct SettingsLayoutKey: Equatable, Sendable {
    public var width: Double
    public var fitting: Double
    public var height: Double

    public init(width: Double, fitting: Double, height: Double) {
        self.width = width
        self.fitting = fitting.rounded()
        self.height = height.rounded()
    }
}

/// The Settings scroll position, as the distance from the top of the content. AppKit's document view
/// is not flipped, so the top is at `fitting - visible` and the bottom at 0.
public enum SettingsScroll {
    /// The largest scroll offset: how far the content extends past the visible height.
    public static func range(fitting: Double, visible: Double) -> Double { max(0, fitting - visible) }

    /// Distance scrolled down from the top, for a clip view at `originY`.
    public static func offsetFromTop(originY: Double, fitting: Double, visible: Double) -> Double {
        let range = range(fitting: fitting, visible: visible)
        return min(max(0, range - originY), range)
    }

    /// The clip view origin that shows the same place after the content or window changed size: the same
    /// distance from the top, kept inside the new range. `fromTop` 0 is the top.
    public static func originY(fromTop: Double, fitting: Double, visible: Double) -> Double {
        let range = range(fitting: fitting, visible: visible)
        return min(max(0, range - fromTop), range)
    }
}
