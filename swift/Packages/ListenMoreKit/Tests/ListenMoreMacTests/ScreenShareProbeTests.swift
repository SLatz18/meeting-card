import AppKit
import ScreenCaptureKit
import XCTest
import ListenMoreCore
@testable import ListenMoreMac

/// Screen-share probe (opt-in: LISTEN_MORE_SCK_PROBE=1, needs a GUI session and Screen Recording
/// permission). Puts on screen: the glow panel (sharingType .none), a stand-in for the coach chip's
/// panel (the card panel's window settings, sharingType .none), and a normal control window. Then
/// it captures the display with ScreenCaptureKit and checks whether our windows are in
/// SCShareableContent's window list and in the captured pixels. The control window must show up,
/// or the result is inconclusive. Prints one `SCK_PROBE_RESULT {json}` line and, if
/// LISTEN_MORE_SCK_PROBE_OUT is set, writes the JSON and the captured PNGs there. The capture shows
/// only these synthetic windows on a CI runner's desktop.
@MainActor
final class ScreenShareProbeTests: XCTestCase {
    static let glowRGB = (r: 0.0, g: 1.0, b: 0.0)
    static let chipRGB = (r: 1.0, g: 0.0, b: 1.0)
    static let controlRGB = (r: 0.0, g: 0.0, b: 1.0)

    final class SolidView: NSView {
        let color: NSColor
        init(frame: NSRect, color: NSColor) {
            self.color = color
            super.init(frame: frame)
        }
        required init?(coder: NSCoder) { fatalError() }
        override func draw(_ dirtyRect: NSRect) {
            color.setFill()
            bounds.fill()
        }
    }

    func solidPanel(_ frame: NSRect, _ rgb: (r: Double, g: Double, b: Double), hidden: Bool) -> NSPanel {
        let p = NSPanel(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = true
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.becomesKeyOnlyIfNeeded = true
        if hidden { p.sharingType = .none }
        p.contentView = SolidView(frame: NSRect(origin: .zero, size: frame.size),
                                  color: NSColor(srgbRed: rgb.r, green: rgb.g, blue: rgb.b, alpha: 1))
        return p
    }

    struct Result: Codable {
        var os: String
        var osBuild: String
        var permission: Bool
        var controlInList: Bool?
        var controlInPixels: Bool?
        var glowInList: Bool?
        var glowInPixels: Bool?
        var chipInList: Bool?
        var chipInPixels: Bool?
        var glowInPixelsWithExplicitExclusion: Bool?
        var chipInPixelsWithExplicitExclusion: Bool?
        var note: String
    }

    func testOurWindowsAgainstScreenCaptureKit() async throws {
        guard ProcessInfo.processInfo.environment["LISTEN_MORE_SCK_PROBE"] == "1" else {
            throw XCTSkip("set LISTEN_MORE_SCK_PROBE=1 to run the screen-share probe")
        }
        _ = NSApplication.shared
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let osString = "\(os.majorVersion).\(os.minorVersion).\(os.patchVersion)"
        let build = (try? String(contentsOfFile: "/System/Library/CoreServices/SystemVersion.plist", encoding: .utf8))
            .flatMap { s -> String? in
                guard let r = s.range(of: "<key>ProductBuildVersion</key>\\s*<string>([^<]+)</string>", options: .regularExpression) else { return nil }
                return String(s[r]).components(separatedBy: "<string>").last?.replacingOccurrences(of: "</string>", with: "")
            } ?? "?"
        var result = Result(os: osString, osBuild: build, permission: false, note: "")

        guard let screen = NSScreen.main else { throw XCTSkip("no screen") }
        let sf = screen.frame
        // Flat, opaque, wide band so a leak is unambiguous in the pixels (the real glow is softer).
        let flat = GlowProfile.Motion(rise: 0, hold: 0, fade: 0, appearFactor: 1, easeRise: false, easeFade: false)
        let probeProfile = GlowProfile(width: 120, peakOpacity: 1, cornerRadius: 0, stops: [.init(0, 1), .init(1, 1)],
                                       motion: flat, reduceMotion: flat)
        let style = GlowStyle(rose: NSColor(srgbRed: Self.glowRGB.r, green: Self.glowRGB.g, blue: Self.glowRGB.b, alpha: 1),
                              amber: .orange, profile: probeProfile)
        let glow = GlowOverlayController(style: style, screenFrames: { [sf] })
        glow.show(.red)
        let chipFrame = NSRect(x: sf.maxX - 14 - 400, y: sf.minY + 140, width: 400, height: 126)
        let chip = solidPanel(chipFrame, Self.chipRGB, hidden: true)
        let controlFrame = NSRect(x: sf.midX - 150, y: sf.midY - 100, width: 300, height: 200)
        let control = solidPanel(controlFrame, Self.controlRGB, hidden: false)
        chip.orderFrontRegardless()
        control.orderFrontRegardless()
        defer {
            glow.hideAll()
            chip.orderOut(nil)
            control.orderOut(nil)
        }
        try await Task.sleep(nanoseconds: 1_500_000_000)

        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            result.note = "SCShareableContent failed (code \((error as NSError).code)): no Screen Recording permission for the test runner"
            report(result, images: [:])
            throw XCTSkip(result.note)
        }
        result.permission = true
        let ids = Set(content.windows.map(\.windowID))
        let glowIDs = glow.panels.map { CGWindowID($0.windowNumber) }
        result.glowInList = glowIDs.contains { ids.contains($0) }
        result.chipInList = ids.contains(CGWindowID(chip.windowNumber))
        result.controlInList = ids.contains(CGWindowID(control.windowNumber))

        guard let display = content.displays.first(where: { $0.displayID == screen.displayID }) ?? content.displays.first else {
            result.note = "no SCDisplay"
            report(result, images: [:])
            throw XCTSkip(result.note)
        }
        let plain = try await capture(SCContentFilter(display: display, excludingWindows: []), display: display)
        let ours = content.windows.filter { glowIDs.contains($0.windowID) || $0.windowID == CGWindowID(chip.windowNumber) }
        let excluded = try await capture(SCContentFilter(display: display, excludingWindows: ours), display: display)

        func present(_ img: CGImage, _ rect: NSRect, _ rgb: (r: Double, g: Double, b: Double)) -> Bool {
            Self.fraction(img, screenRect: rect, screen: sf, rgb: rgb) > 0.5
        }
        // The outer 16 pt of the 120 pt gradient band (alpha above ~0.85).
        let band = NSRect(x: sf.minX + 200, y: sf.minY + 2, width: sf.width - 400, height: 16)
        let chipProbe = chipFrame.insetBy(dx: 20, dy: 20)
        result.controlInPixels = present(plain, controlFrame.insetBy(dx: 20, dy: 20), Self.controlRGB)
        result.glowInPixels = present(plain, band, Self.glowRGB)
        result.chipInPixels = present(plain, chipProbe, Self.chipRGB)
        result.glowInPixelsWithExplicitExclusion = present(excluded, band, Self.glowRGB)
        result.chipInPixelsWithExplicitExclusion = present(excluded, chipProbe, Self.chipRGB)
        if result.controlInPixels != true {
            result.note = "inconclusive: the control window is not in the capture"
        } else if result.glowInPixels == true || result.chipInPixels == true {
            result.note = "sharingType .none NOT honored by ScreenCaptureKit on this OS"
        } else {
            result.note = "sharingType .none honored: our windows are absent from the capture"
        }
        report(result, images: ["capture.png": plain, "capture-excluding-ours.png": excluded])
        XCTAssertEqual(result.controlInPixels, true, "probe must see the control window")
    }

    func capture(_ filter: SCContentFilter, display: SCDisplay) async throws -> CGImage {
        let c = SCStreamConfiguration()
        c.width = display.width * 2
        c.height = display.height * 2
        c.showsCursor = false
        c.capturesAudio = false
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: c)
    }

    /// Fraction of pixels in `screenRect` (Cocoa points) that match `rgb` within a tolerance.
    static func fraction(_ img: CGImage, screenRect: NSRect, screen: NSRect, rgb: (r: Double, g: Double, b: Double)) -> Double {
        let w = img.width, h = img.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        guard let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return 0 }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        let sx = Double(w) / screen.width, sy = Double(h) / screen.height
        // CGContext memory is top-row first; Cocoa y grows upward from the screen's bottom.
        let x0 = Int((screenRect.minX - screen.minX) * sx), x1 = Int((screenRect.maxX - screen.minX) * sx)
        let yTop = Int((screen.maxY - screenRect.maxY) * sy), yBottom = Int((screen.maxY - screenRect.minY) * sy)
        var hit = 0, total = 0
        for y in stride(from: max(0, yTop), to: min(h, yBottom), by: 4) {
            for x in stride(from: max(0, x0), to: min(w, x1), by: 4) {
                let i = (y * w + x) * 4
                let r = Double(buf[i]) / 255, g = Double(buf[i + 1]) / 255, b = Double(buf[i + 2]) / 255
                total += 1
                if abs(r - rgb.r) < 0.2 && abs(g - rgb.g) < 0.2 && abs(b - rgb.b) < 0.2 { hit += 1 }
            }
        }
        return total > 0 ? Double(hit) / Double(total) : 0
    }

    func report(_ r: Result, images: [String: CGImage]) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys]
        let data = (try? enc.encode(r)) ?? Data()
        let line = "SCK_PROBE_RESULT " + (String(data: data, encoding: .utf8) ?? "{}") + "\n"
        FileHandle.standardOutput.write(Data(line.utf8))
        guard let dir = ProcessInfo.processInfo.environment["LISTEN_MORE_SCK_PROBE_OUT"] else { return }
        let url = URL(fileURLWithPath: dir)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try? data.write(to: url.appendingPathComponent("sck-probe.json"))
        for (name, img) in images {
            guard let dest = CGImageDestinationCreateWithURL(url.appendingPathComponent(name) as CFURL,
                                                             "public.png" as CFString, 1, nil) else { continue }
            CGImageDestinationAddImage(dest, img, nil)
            CGImageDestinationFinalize(dest)
        }
    }
}

extension NSScreen {
    var displayID: CGDirectDisplayID {
        (deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
    }
}
