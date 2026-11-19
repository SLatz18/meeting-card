import AppKit
import CoreGraphics
import ListenMoreCore

/// Observes call apps' windows into a `CallWindowSelector`: window number, owner, layer, on-screen
/// flag and bounds from CGWindowListCopyWindowInfo (never titles or pixels, so no Screen Recording
/// permission is involved). Updated from the coach's poll on the main thread and read from the
/// call-controls queue, so it locks. The window list is read only for Zoom (always), another native
/// call app while its session is active, and a browser once the Meet script has named its meeting
/// window (`CallWindowSelector.keysToRead`); an app that isn't read on a poll forgets its windows.
public final class CallWindowTracker: @unchecked Sendable {
    /// The windows of the running apps in a set of bundle ID keys (tests inject their own).
    public typealias WindowSource = (_ appKeys: Set<String>) -> [AppWindow]

    private let lock = NSLock()
    private var selector: CallWindowSelector
    private let windowSource: WindowSource

    /// - Parameter windowSource: nil reads the real window list (`windows(appKeys:)`).
    public init(lookbackS: Double, windowSource: WindowSource? = nil) {
        selector = CallWindowSelector(lookbackS: lookbackS)
        self.windowSource = windowSource ?? { CallWindowTracker.windows(appKeys: $0) }
    }

    public convenience init(config: ListenMoreConfig, windowSource: WindowSource? = nil) {
        self.init(lookbackS: config.trigger.callWindowLookbackS, windowSource: windowSource)
    }

    /// One observation. `session` is the coach session's app and start time (system uptime);
    /// `alwaysOnKeys` are the apps read on every poll (Zoom).
    public func update(session: (appKey: String, startedAt: Double)?, appKeys: Set<String>, browserKeys: Set<String>,
                       alwaysOnKeys: Set<String>, hints: [String: CallWindowHint],
                       now: Double = ProcessInfo.processInfo.systemUptime) {
        let readKeys = CallWindowSelector.keysToRead(appKeys: appKeys, browserKeys: browserKeys, alwaysKeys: alwaysOnKeys,
                                                     sessionAppKey: session?.appKey, hints: hints)
        let all = readKeys.isEmpty ? [] : windowSource(readKeys)
        lock.withLock {
            selector.observe(all, appKeys: readKeys, browserKeys: browserKeys, session: session, hints: hints, now: now)
        }
    }

    public func reset() { lock.withLock { selector.reset() } }

    /// Bounds (CG coordinates) of the call's window, or nil when none is identified.
    public func target(appKey: String?) -> CGRect? { lock.withLock { selector.target(appKey: appKey) } }

    public func callWindowPresent(appKey: String) -> Bool? { lock.withLock { selector.callWindowPresent(appKey: appKey) } }

    /// Windows owned by running apps in `appKeys` (their main process; helpers don't own windows).
    static func windows(appKeys: Set<String>) -> [AppWindow] {
        var bundleByPid: [pid_t: String] = [:]
        for app in NSWorkspace.shared.runningApplications where !app.isTerminated {
            guard let id = app.bundleIdentifier, appKeys.contains(where: { BundleIds.belongs(id, to: $0) }) else { continue }
            bundleByPid[app.processIdentifier] = id
        }
        guard !bundleByPid.isEmpty,
              let list = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        return list.compactMap { w in
            guard let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value, let bundle = bundleByPid[pid],
                  let number = (w[kCGWindowNumber as String] as? NSNumber)?.intValue,
                  let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict) else { return nil }
            let onScreen = (w[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
            return AppWindow(id: number, bundleId: bundle, layer: layer, onScreen: onScreen, bounds: bounds)
        }
    }
}

/// The display for the glow, else the card's display: the one holding the call app's largest window
/// (`screen(appKey:fallback:)`, flag off) or the call's own window (`screen(callWindow:...)`, flag on).
public enum CallDisplayLocator {
    // MARK: the largest-window rule (flag off)

    public static func windows() -> [CallDisplay.WindowInfo] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
                as? [[String: Any]] else { return [] }
        var bundleByPid: [pid_t: String?] = [:]
        return list.compactMap { w in
            guard let pid = (w[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let layer = (w[kCGWindowLayer as String] as? NSNumber)?.intValue,
                  let dict = w[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: dict) else { return nil }
            let bundle: String?
            if let cached = bundleByPid[pid] {
                bundle = cached
            } else {
                bundle = NSRunningApplication(processIdentifier: pid)?.bundleIdentifier
                bundleByPid[pid] = bundle
            }
            return CallDisplay.WindowInfo(bundleId: bundle, layer: layer, bounds: bounds)
        }
    }

    /// Cocoa frame of the display for the glow; `fallback` is the card's display.
    public static func screen(appKey: String?, fallback: NSRect?) -> NSRect? {
        let screens = NSScreen.screens.map(\.frame)
        let primaryHeight = NSScreen.screens.first?.frame.maxY ?? 0
        return CallDisplay.screen(appKey: appKey, windows: appKey == nil ? [] : windows(), screens: screens,
                                  primaryHeight: primaryHeight, fallback: fallback)
    }

    // MARK: the call window rule (flag on)

    /// Cocoa frame of the display for the glow; `fallback` is the card's display. `screens` (Cocoa
    /// frames, the primary first) defaults to the attached displays; tests pass their own.
    public static func screen(callWindow: CGRect?, fallback: NSRect?, screens: [NSRect]? = nil) -> NSRect? {
        let screens = screens ?? NSScreen.screens.map(\.frame)
        let primaryHeight = screens.first?.maxY ?? 0
        return CallDisplay.screen(callWindow: callWindow, screens: screens, primaryHeight: primaryHeight, fallback: fallback)
    }
}
