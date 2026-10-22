import AppKit
import MeetingCardCore

/// Hand-drawn provider glyphs (no vendor assets). Port of icons.py.
enum Icons {
    static func rgb(_ h: UInt32, _ a: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((h >> 16) & 255) / 255, green: CGFloat((h >> 8) & 255) / 255,
                blue: CGFloat(h & 255) / 255, alpha: a)
    }

    static func fill(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat, _ c: NSColor) {
        c.set()
        NSRect(x: x, y: y, width: w, height: h).fill()
    }

    static func meet(_ r: NSRect) -> Bool {
        // Meet camera: rounded tile split into red (TL), yellow (top), blue (left),
        // green (bottom + right) bands around a hollow centre, plus a green notch.
        let s = r.width / 20
        let x0 = 1 * s, y0 = 3.5 * s, w = 12 * s, h = 13 * s, t = 4.2 * s
        NSGraphicsContext.saveGraphicsState()
        let outer = NSBezierPath(roundedRect: NSRect(x: x0, y: y0, width: w, height: h), xRadius: 2.2 * s, yRadius: 2.2 * s)
        let hole = NSBezierPath(roundedRect: NSRect(x: x0 + t, y: y0 + t, width: w - 2 * t, height: h - 2 * t),
                                xRadius: 0.6 * s, yRadius: 0.6 * s)
        outer.append(hole.reversed)
        outer.addClip()
        fill(x0, y0, w, h, rgb(Brand.meetGreen))
        fill(x0, y0 + h - t, w, t, rgb(Brand.meetYellow))
        fill(x0, y0, t, h - t, rgb(Brand.meetBlue))
        fill(x0, y0 + h - t, t, t, rgb(Brand.meetRed))
        fill(x0 + w - t, y0 + h - t, t, t, rgb(Brand.meetGreen))
        NSGraphicsContext.restoreGraphicsState()
        let notch = NSBezierPath()
        notch.move(to: NSPoint(x: x0 + w - 0.2 * s, y: y0 + h * 0.30))
        notch.line(to: NSPoint(x: 19 * s, y: y0 + 0.6 * s))
        notch.line(to: NSPoint(x: 19 * s, y: y0 + h - 0.6 * s))
        notch.line(to: NSPoint(x: x0 + w - 0.2 * s, y: y0 + h * 0.70))
        notch.close()
        notch.lineJoinStyle = .round
        rgb(Brand.meetGreen).set()
        notch.fill()
        return true
    }

    static func zoom(_ r: NSRect) -> Bool {
        let s = r.width / 18
        rgb(Brand.zoom).set()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 18 * s, height: 18 * s), xRadius: 4 * s, yRadius: 4 * s).fill()
        NSColor.white.set()
        NSBezierPath(roundedRect: NSRect(x: 3 * s, y: 5.5 * s, width: 8 * s, height: 7 * s), xRadius: 1.5 * s, yRadius: 1.5 * s).fill()
        let p = NSBezierPath()
        p.move(to: NSPoint(x: 11.5 * s, y: 8 * s)); p.line(to: NSPoint(x: 15 * s, y: 5.5 * s))
        p.line(to: NSPoint(x: 15 * s, y: 12.5 * s)); p.line(to: NSPoint(x: 11.5 * s, y: 10 * s)); p.close()
        p.fill()
        return true
    }

    static func teams(_ r: NSRect) -> Bool {
        let s = r.width / 18
        rgb(Brand.teams).set()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 18 * s, height: 18 * s), xRadius: 4 * s, yRadius: 4 * s).fill()
        fill(4 * s, 12 * s, 10 * s, 2.4 * s, .white)
        fill(7.8 * s, 3.5 * s, 2.4 * s, 9 * s, .white)
        return true
    }

    static func webex(_ r: NSRect) -> Bool {
        let s = r.width / 18
        rgb(0x1D1D1F).set()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: 18 * s, height: 18 * s), xRadius: 4 * s, yRadius: 4 * s).fill()
        for (x, c) in [(5.2, Brand.webexCyan), (12.8, Brand.webexGreen)] {
            let ring = NSBezierPath(ovalIn: NSRect(x: (x - 3.4) * s, y: 5.6 * s, width: 6.8 * s, height: 6.8 * s))
            ring.lineWidth = 2 * s
            rgb(c).set()
            ring.stroke()
        }
        return true
    }

    static func icon(_ provider: String, size: CGFloat = 18) -> NSImage? {
        let draw: ((NSRect) -> Bool)?
        switch provider {
        case "meet": draw = meet
        case "zoom": draw = zoom
        case "teams": draw = teams
        case "webex": draw = webex
        default: draw = nil
        }
        guard let draw else { return nil }
        return NSImage(size: NSSize(width: size, height: size), flipped: false, drawingHandler: draw)
    }
}
