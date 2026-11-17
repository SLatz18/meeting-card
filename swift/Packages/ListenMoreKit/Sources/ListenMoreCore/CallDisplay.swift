import Foundation
#if canImport(CoreGraphics)
import CoreGraphics
#endif

/// Which display gets the glow: the one holding the call's window (`CallWindowSelector`), else
/// the card's display. Never the call app's largest or frontmost window: an app's home window is
/// not the call. Window numbers, owners and bounds come from CGWindowListCopyWindowInfo (no
/// window titles, so no Screen Recording permission is needed for this).
public enum CallDisplay {
    /// CG (top-left, y down) to Cocoa (bottom-left, y up) using the primary display's height.
    public static func cocoaRect(_ cg: CGRect, primaryHeight: CGFloat) -> CGRect {
        CGRect(x: cg.minX, y: primaryHeight - cg.maxY, width: cg.width, height: cg.height)
    }

    /// Screen (Cocoa frame) for the glow: the display that holds most of `callWindow` (CG
    /// coordinates, from `CallWindowSelector.target`), else `fallback` (the card's screen).
    public static func screen(callWindow: CGRect?, screens: [CGRect], primaryHeight: CGFloat, fallback: CGRect?) -> CGRect? {
        if let callWindow {
            let r = cocoaRect(callWindow, primaryHeight: primaryHeight)
            if let s = screens.max(by: { area($0.intersection(r)) < area($1.intersection(r)) }), area(s.intersection(r)) > 0 {
                return s
            }
        }
        return fallback ?? screens.first
    }

    static func area(_ r: CGRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }
}
