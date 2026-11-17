import AppKit
import CoreGraphics
import ListenMoreCore

/// Reads on-screen window owners and bounds (never titles or pixels, so no Screen Recording
/// permission is involved) to find the display holding the call app's window.
public enum CallDisplayLocator {
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
}
