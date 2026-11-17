import Foundation

/// Which display gets the glow: the one holding the call app's largest normal window, else the
/// card's display. Window owner PIDs and bounds come from CGWindowListCopyWindowInfo (no window
/// titles, so no Screen Recording permission is needed for this).
public enum CallDisplay {
    public struct WindowInfo: Equatable, Sendable {
        public var bundleId: String?
        public var layer: Int
        /// Global CG coordinates (origin top-left of the primary display, y down).
        public var bounds: CGRect

        public init(bundleId: String?, layer: Int, bounds: CGRect) {
            self.bundleId = bundleId
            self.layer = layer
            self.bounds = bounds
        }
    }

    /// CG (top-left, y down) to Cocoa (bottom-left, y up) using the primary display's height.
    public static func cocoaRect(_ cg: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: cg.minX, y: primaryHeight - cg.maxY, width: cg.width, height: cg.height)
    }

    /// Screen (Cocoa frame) for the glow. `appKey` is the session's app (lowercased bundle ID);
    /// helpers count via `BundleIds.belongs`. Falls back to `fallback` (the card's screen).
    public static func screen(appKey: String?, windows: [WindowInfo], screens: [CGRect],
                              primaryHeight: CGFloat, fallback: CGRect?) -> CGRect? {
        if let appKey {
            let candidates = windows.filter { w in
                w.layer == 0 && w.bounds.width >= 100 && w.bounds.height >= 100
                    && w.bundleId.map { BundleIds.belongs($0, to: appKey) } == true
            }
            if let w = candidates.max(by: { $0.bounds.width * $0.bounds.height < $1.bounds.width * $1.bounds.height }) {
                let r = cocoaRect(w.bounds, primaryHeight: primaryHeight)
                if let s = screens.max(by: { area($0.intersection(r)) < area($1.intersection(r)) }), area(s.intersection(r)) > 0 {
                    return s
                }
            }
        }
        return fallback ?? screens.first
    }

    static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
}
