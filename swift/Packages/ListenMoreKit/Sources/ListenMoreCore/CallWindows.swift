import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// A window as CGWindowListCopyWindowInfo reports it, without its title: number, owner, layer,
/// whether it's on screen, and bounds (global CG coordinates, origin top-left, y down).
public struct AppWindow: Equatable, Sendable {
    public var id: Int
    public var bundleId: String?
    public var layer: Int
    public var onScreen: Bool
    public var bounds: CGRect

    public init(id: Int, bundleId: String?, layer: Int, onScreen: Bool, bounds: CGRect) {
        self.id = id
        self.bundleId = bundleId
        self.layer = layer
        self.onScreen = onScreen
        self.bounds = bounds
    }
}

/// Which browser window holds the Meet meeting tab: its rank (1 = front) among the browser's
/// visible (not minimized) windows, and how many visible windows the browser reported. From the
/// Meet script (`MeetScript`), only when exactly one window holds meeting tabs.
public struct CallWindowHint: Equatable, Sendable {
    public var rank: Int
    public var visibleWindows: Int

    public init(rank: Int, visibleWindows: Int) {
        self.rank = rank
        self.visibleWindows = visibleWindows
    }
}

/// The call's window, for the glow's display and for "is the meeting window still there". Never
/// the app's largest, first or frontmost window:
/// - Native call apps (Zoom, Teams, ...): the normal window that appeared with the call. The first
///   bind of a session takes the newest normal window first seen no earlier than `lookbackS` before
///   the session started. It stays bound until it disappears, so the home window closing or
///   Settings or Chat opening mid-call don't move it. When it disappears (a preview or waiting-room
///   window giving way to the meeting window), the newest normal window that appeared since
///   observation began and is still open binds, with no lookback, except windows that opened while
///   another one was bound (Settings, Chat): if only those are left, nothing binds. Windows that
///   were already open when observation began (unknown age) never bind.
/// - While the bound window is off screen (minimized), its floating window that appeared during the
///   call (Zoom's mini window, a share video panel) stands in; small bars (share toolbars) never.
/// - Browsers: the window the Meet script names (`CallWindowHint`), matched by z-order rank among
///   the browser's visible normal windows only when both sides count the same number of windows.
/// Nothing identified means nil: the host's fallback (the card's display) and Core Audio as before.
public struct CallWindowSelector: Sendable {
    /// Windows smaller than this on either side are bars, badges or toolbars, never the call.
    public static let minSide: CGFloat = 100
    public let lookbackS: Double

    struct AppState: Sendable {
        var firstSeen: [Int: Double] = [:]
        /// Present when this app was first observed: their age is unknown, so they never bind.
        var unknownAge: Set<Int> = []
        var bound: Int?
        /// The session this state's binding belongs to (its start time).
        var session: Double?
        /// This session has bound a window before: later binds are re-resolves (no lookback).
        var everBound = false
        /// Opened while another window was bound this session: never take over at a re-resolve.
        var openedWhileBound: Set<Int> = []
    }

    private var apps: [String: AppState] = [:]
    private var windows: [String: [AppWindow]] = [:]
    private var sessionKey: String?
    private var sessionStart: Double?

    public init(lookbackS: Double) {
        self.lookbackS = lookbackS
    }

    /// The apps whose window list is worth reading on this poll: every native call app (windows are
    /// watched from the moment they open, so a call's window is told from the home window by when
    /// it appeared), but a browser only once the Meet script has named the window holding a
    /// meeting. A browser with no hint binds nothing, so it never costs a window-list read.
    public static func keysToRead(appKeys: Set<String>, browserKeys: Set<String>, hints: [String: CallWindowHint]) -> Set<String> {
        appKeys.filter { !browserKeys.contains($0) || hints[$0] != nil }
    }

    /// Forget everything (the coach was switched off; ages restart as unknown).
    public mutating func reset() {
        self = CallWindowSelector(lookbackS: lookbackS)
    }

    /// One observation of the on-screen and off-screen windows of every app in `appKeys`.
    /// - Parameters:
    ///   - session: the coach session's app (lowercased bundle ID) and start time, if any.
    ///   - browserKeys: apps bound by `hints` instead of by window age.
    public mutating func observe(_ all: [AppWindow], appKeys: Set<String>, browserKeys: Set<String>,
                                 session: (appKey: String, startedAt: Double)?, hints: [String: CallWindowHint], now: Double) {
        sessionKey = session?.appKey
        sessionStart = session?.startedAt
        for key in appKeys {
            let own = all.filter { w in w.bundleId.map { BundleIds.belongs($0, to: key) } == true }
            var s = apps[key] ?? AppState()
            let firstObservation = apps[key] == nil
            let ids = Set(own.map(\.id))
            let opened = ids.filter { s.firstSeen[$0] == nil }
            for id in opened {
                s.firstSeen[id] = now
                if firstObservation { s.unknownAge.insert(id) }
            }
            s.firstSeen = s.firstSeen.filter { ids.contains($0.key) }
            s.unknownAge.formIntersection(ids)
            if let b = s.bound, ids.contains(b) { s.openedWhileBound.formUnion(opened) }
            s.openedWhileBound.formIntersection(ids)
            if let b = s.bound, !ids.contains(b) { s.bound = nil }

            if browserKeys.contains(key) {
                s.bound = Self.browserWindow(own, hint: hints[key])
            } else if let start = session?.startedAt, session?.appKey == key {
                if s.session != start {
                    s.session = start
                    s.bound = nil
                    s.everBound = false
                    s.openedWhileBound = []
                }
                if s.bound == nil {
                    s.bound = s.everBound
                        ? Self.newestCallWindow(own, state: s, since: -.infinity, excluding: s.openedWhileBound)
                        : Self.newestCallWindow(own, state: s, since: start - lookbackS)
                    if s.bound != nil { s.everBound = true }
                }
            } else {
                s.bound = nil
                s.session = nil
                s.everBound = false
                s.openedWhileBound = []
            }
            apps[key] = s
            windows[key] = own
        }
        for key in apps.keys where !appKeys.contains(key) {
            apps[key] = nil
            windows[key] = nil
        }
    }

    static func isNormal(_ w: AppWindow) -> Bool {
        w.layer == 0 && w.bounds.width >= minSide && w.bounds.height >= minSide
    }

    static func newestCallWindow(_ own: [AppWindow], state: AppState, since: Double, excluding: Set<Int> = []) -> Int? {
        let candidates = own.filter { w in
            isNormal(w) && !state.unknownAge.contains(w.id) && !excluding.contains(w.id)
                && (state.firstSeen[w.id] ?? -.infinity) >= since - 1e-9
        }
        guard let newest = candidates.map({ state.firstSeen[$0.id] ?? -.infinity }).max() else { return nil }
        let tied = candidates.filter { state.firstSeen[$0.id] == newest }
        // Two windows that appeared in the same observation can't be told apart: wait for the next.
        return tied.count == 1 ? tied[0].id : nil
    }

    static func browserWindow(_ own: [AppWindow], hint: CallWindowHint?) -> Int? {
        guard let hint, hint.rank > 0 else { return nil }
        let visible = own.filter { isNormal($0) && $0.onScreen }
        guard visible.count == hint.visibleWindows, hint.rank <= visible.count else { return nil }
        return visible[hint.rank - 1].id
    }

    /// Bounds (CG coordinates) of the call's window for `appKey`, or nil when none is identified.
    public func target(appKey: String?) -> CGRect? {
        guard let appKey, let s = apps[appKey], let own = windows[appKey], let b = s.bound,
              let w = own.first(where: { $0.id == b }) else { return nil }
        if w.onScreen { return w.bounds }
        guard sessionKey == appKey, let start = sessionStart else { return nil }
        let standIns = own.filter { f in
            f.layer != 0 && f.onScreen && f.bounds.width >= Self.minSide && f.bounds.height >= Self.minSide
                && !s.unknownAge.contains(f.id) && (s.firstSeen[f.id] ?? -.infinity) >= start - 1e-9
        }
        guard let newest = standIns.map({ s.firstSeen[$0.id] ?? -.infinity }).max() else { return nil }
        return standIns.first { s.firstSeen[$0.id] == newest }?.bounds
    }

    /// The bound call window still exists (on screen or minimized); nil when none is bound.
    public func callWindowPresent(appKey: String) -> Bool? {
        guard let s = apps[appKey], let b = s.bound else { return nil }
        return windows[appKey]?.contains { $0.id == b } == true
    }

    public func boundWindow(appKey: String) -> Int? { apps[appKey]?.bound }
}
