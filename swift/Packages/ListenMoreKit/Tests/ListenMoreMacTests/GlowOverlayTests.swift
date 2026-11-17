import AppKit
import ScreenCaptureKit
import XCTest
import ListenMoreCore
@testable import ListenMoreMac

let testGlowProfile = GlowProfile(
    width: 32, peakOpacity: 0.45, cornerRadius: 16,
    stops: [.init(0, 1), .init(0.15, 0.78), .init(0.35, 0.42), .init(0.6, 0.16), .init(0.82, 0.05), .init(1, 0)],
    motion: .init(rise: 0.32, hold: 0.8, fade: 1.88, appearFactor: 0, easeRise: true, easeFade: true),
    reduceMotion: .init(rise: 0, hold: 0, fade: 2.0, appearFactor: 0.7, easeRise: false, easeFade: false))
let testGlowStyle = GlowStyle(rose: NSColor(srgbRed: 0.65, green: 0.36, blue: 0.34, alpha: 1),
                              amber: NSColor(srgbRed: 0.71, green: 0.52, blue: 0.23, alpha: 1),
                              profile: testGlowProfile)

@MainActor
final class GlowOverlayTests: XCTestCase {
    /// A host theme that is deliberately not red/amber, to prove the Kit uses whatever it is given.
    let hostStyle = CoachStyle(
        colors: [.red: CoachStyle.RGBA(red: 0.9, green: 0.1, blue: 0.6, alpha: 0.7),
                 .amber: CoachStyle.RGBA(red: 0.1, green: 0.6, blue: 0.9, alpha: 0.5)],
        fadeIn: 0.25, fadeOut: 2.0, bandWidth: 18, cooldownDisplay: .hidden)

    override func setUp() async throws {
        _ = NSApplication.shared
    }

    func panel(_ w: CGFloat = 800, _ h: CGFloat = 600, style: GlowStyle = testGlowStyle) -> GlowPanel {
        GlowPanel(frame: NSRect(x: 0, y: 0, width: w, height: h), style: style)
    }

    func testPanelAsksToBeHiddenFromScreenShare() {
        XCTAssertEqual(panel().sharingType, .none)
    }

    func testPanelIsClickThroughAndNeverTakesFocus() {
        let p = panel()
        XCTAssertTrue(p.ignoresMouseEvents)
        XCTAssertFalse(p.canBecomeKey)
        XCTAssertFalse(p.canBecomeMain)
        XCTAssertTrue(p.styleMask.contains(.nonactivatingPanel))
        XCTAssertTrue(p.styleMask.contains(.borderless))
        XCTAssertFalse(p.styleMask.contains(.titled))
        XCTAssertTrue(p.becomesKeyOnlyIfNeeded)
        XCTAssertFalse(p.hidesOnDeactivate)
    }

    func testPanelStaysKeyAndMainFreeWhenShown() {
        let p = panel(400, 300)
        p.orderFrontRegardless()
        p.makeKey()
        XCTAssertFalse(p.isKeyWindow)
        XCTAssertFalse(p.isMainWindow)
        p.orderOut(nil)
    }

    func testPanelIsTransparent() {
        let p = panel()
        XCTAssertFalse(p.isOpaque)
        XCTAssertEqual(p.backgroundColor, .clear)
        XCTAssertFalse(p.hasShadow)
        XCTAssertEqual(p.alphaValue, 0)
    }

    func testPanelLevelAndCollectionBehavior() {
        let p = panel()
        XCTAssertEqual(p.level, .statusBar, "default: with status-bar windows, ordered behind the host's window")
        XCTAssertTrue(p.collectionBehavior.contains(.canJoinAllSpaces))
        XCTAssertTrue(p.collectionBehavior.contains(.stationary))
        XCTAssertTrue(p.collectionBehavior.contains(.fullScreenAuxiliary))
        XCTAssertTrue(p.collectionBehavior.contains(.ignoresCycle))
        XCTAssertFalse(p.collectionBehavior.contains(.moveToActiveSpace))
    }

    func testLevelIsInjectable() {
        var raised = testGlowStyle
        raised.level = .screenSaver
        XCTAssertEqual(panel(style: raised).level, .screenSaver)
        let c = GlowOverlayController(style: testGlowStyle, screenFrames: { [NSRect(x: 0, y: 0, width: 400, height: 300)] })
        c.apply(style: raised)
        XCTAssertEqual(c.panels[0].level, .screenSaver)
    }

    func testOnePanelPerDisplayCoveringIt() {
        let frames = [NSRect(x: 0, y: 0, width: 1440, height: 900), NSRect(x: 1440, y: 0, width: 1920, height: 1080)]
        let c = GlowOverlayController(style: testGlowStyle, screenFrames: { frames })
        XCTAssertEqual(c.panels.count, 2)
        XCTAssertEqual(c.panels.map(\.frame), frames)
        XCTAssertTrue(c.panels.allSatisfy { $0.sharingType == .none && $0.ignoresMouseEvents && !$0.canBecomeKey })
    }

    func testFlashUsesStyleColorsAndNeverActivatesApp() {
        let c = GlowOverlayController(style: testGlowStyle, screenFrames: { [NSRect(x: 0, y: 0, width: 400, height: 300)] })
        let wasActive = NSApp.isActive
        c.flash(.amber)
        XCTAssertEqual(c.panels.first?.glowView.color, .amber)
        XCTAssertEqual(NSApp.isActive, wasActive)
        XCTAssertFalse(c.panels.first?.isKeyWindow ?? true)
        c.flash(.red)
        XCTAssertEqual(c.panels.first?.glowView.color, .red)
        XCTAssertEqual(c.panels.first?.glowView.style, testGlowStyle)
        c.hideAll()
        XCTAssertEqual(c.panels.first?.alphaValue, 0)
        XCTAssertFalse(c.panels.first?.isVisible ?? true)
    }

    func testCoachStyleColorsAndShapeReachTheGlow() {
        let c = GlowOverlayController(style: GlowStyle(hostStyle), screenFrames: { [NSRect(x: 0, y: 0, width: 400, height: 300)] })
        c.flash(.red)
        let view = c.panels[0].glowView
        let red = view.currentColor.usingColorSpace(.sRGB)
        XCTAssertEqual(red?.redComponent ?? 0, 0.9, accuracy: 0.01)
        XCTAssertEqual(red?.blueComponent ?? 0, 0.6, accuracy: 0.01)
        XCTAssertEqual(red?.alphaComponent ?? 0, 0.7, accuracy: 0.01)
        c.flash(.amber)
        XCTAssertEqual(view.currentColor.usingColorSpace(.sRGB)?.blueComponent ?? 0, 0.9, accuracy: 0.01)
        XCTAssertEqual(view.style.profile.width, 18)
        XCTAssertEqual(c.style.profile.motion.rise, 0.25)
        XCTAssertEqual(c.style.profile.motion.fade, 2.0)
        c.hideAll()
    }

    func testHostDarkColorsResolvePerAppearance() {
        var style = hostStyle
        style.darkColors = [.red: CoachStyle.RGBA(red: 0.2, green: 0.4, blue: 0.6, alpha: 1),
                            .amber: CoachStyle.RGBA(red: 0.6, green: 0.4, blue: 0.2, alpha: 1)]
        let glow = GlowStyle(style)
        func red(_ name: NSAppearance.Name) -> NSColor? {
            var c: NSColor?
            NSAppearance(named: name)?.performAsCurrentDrawingAppearance { c = glow.rose.usingColorSpace(.sRGB) }
            return c
        }
        XCTAssertEqual(red(.aqua)?.redComponent ?? 0, 0.9, accuracy: 0.01)
        XCTAssertEqual(red(.darkAqua)?.redComponent ?? 0, 0.2, accuracy: 0.01)
        XCTAssertEqual(red(.darkAqua)?.blueComponent ?? 0, 0.6, accuracy: 0.01)
    }

    func testLiveRetheme() {
        let c = GlowOverlayController(style: GlowStyle(hostStyle), screenFrames: { [NSRect(x: 0, y: 0, width: 400, height: 300)] })
        c.flash(.red)
        var dark = hostStyle
        dark.colors[.red] = CoachStyle.RGBA(red: 0.2, green: 0.2, blue: 0.2, alpha: 1)
        c.apply(style: GlowStyle(dark))
        XCTAssertEqual(c.panels[0].glowView.currentColor.usingColorSpace(.sRGB)?.redComponent ?? 0, 0.2, accuracy: 0.01)
        c.hideAll()
    }

    func testFlashShowsOnlyTheTargetDisplay() {
        let frames = [NSRect(x: 0, y: 0, width: 1440, height: 900), NSRect(x: 1440, y: 0, width: 1920, height: 1080)]
        let c = GlowOverlayController(style: testGlowStyle, screenFrames: { frames }, reduceMotion: { false })
        c.flash(.red, on: frames[1])
        XCTAssertFalse(c.panels[0].isVisible)
        XCTAssertTrue(c.panels[1].isVisible)
        XCTAssertEqual(c.lastMotion?.total ?? 0, 3.0, accuracy: 1e-9)
        c.flash(.amber, on: nil)
        XCTAssertTrue(c.panels[0].isVisible, "no target: first display")
        XCTAssertFalse(c.panels[1].isVisible)
        c.hideAll()
    }

    func testRendererUsesPlacement() {
        let frames = [NSRect(x: 0, y: 0, width: 1440, height: 900), NSRect(x: 1440, y: 0, width: 1920, height: 1080)]
        let c = GlowOverlayController(style: testGlowStyle, screenFrames: { frames })
        c.placement = { .init(screen: frames[1]) }
        c.render(Cue(type: .interrupt, color: .red, t: 3.3, onset: 3.0, latencyMs: 300, source: .local, fadeS: 3, confidence: nil))
        XCTAssertFalse(c.panels[0].isVisible)
        XCTAssertTrue(c.panels[1].isVisible)
        XCTAssertEqual(c.panels[1].glowView.color, .red)
        c.clear()
        XCTAssertFalse(c.panels[1].isVisible)
    }

    func testReduceMotionUsesTheShortLinearFade() {
        let c = GlowOverlayController(style: testGlowStyle, screenFrames: { [NSRect(x: 0, y: 0, width: 400, height: 300)] },
                                      reduceMotion: { true })
        c.flash(.amber)
        XCTAssertEqual(c.lastMotion, testGlowProfile.reduceMotion)
        XCTAssertEqual(c.panels[0].alphaValue, 0.45 * 0.7, accuracy: 0.01)
        c.hideAll()
    }

    func testIncreaseContrastUsesTheHigherPeak() {
        var style = testGlowStyle
        style.profile.increasedContrastPeakOpacity = 0.6
        let frames = { [NSRect(x: 0, y: 0, width: 400, height: 300)] }
        let hc = GlowOverlayController(style: style, screenFrames: frames, reduceMotion: { true }, increaseContrast: { true })
        hc.flash(.red)
        XCTAssertEqual(hc.lastPeak, 0.6)
        XCTAssertEqual(hc.panels[0].alphaValue, 0.6 * 0.7, accuracy: 0.01)
        hc.show(.amber)
        XCTAssertEqual(hc.panels[0].alphaValue, 0.6, accuracy: 0.01)
        hc.hideAll()
        let normal = GlowOverlayController(style: style, screenFrames: frames, increaseContrast: { false })
        normal.show(.red)
        XCTAssertEqual(normal.lastPeak, 0.45)
        normal.hideAll()
    }

    func testShowHoldsAtPeakOpacity() {
        let c = GlowOverlayController(style: testGlowStyle, screenFrames: { [NSRect(x: 0, y: 0, width: 400, height: 300)] })
        c.show(.red)
        XCTAssertEqual(c.panels[0].alphaValue, 0.45, accuracy: 0.01)
        c.hideAll()
    }

    func testSuppressedDropsFlashes() {
        let c = GlowOverlayController(style: testGlowStyle, screenFrames: { [NSRect(x: 0, y: 0, width: 400, height: 300)] })
        c.suppressed = true
        c.flash(.red)
        XCTAssertFalse(c.panels.first?.isVisible ?? true)
    }

    func testFadeUsesStyleTiming() async {
        let quick = CoachStyle(colors: hostStyle.colors, fadeIn: 0.01, fadeOut: 0.05, bandWidth: 10, cooldownDisplay: .hidden)
        let c = GlowOverlayController(style: GlowStyle(quick), screenFrames: { [NSRect(x: 0, y: 0, width: 200, height: 200)] },
                                      reduceMotion: { false })
        c.flash(.amber)
        XCTAssertTrue(c.panels[0].isVisible)
        let deadline = Date().addingTimeInterval(3)
        while c.panels[0].isVisible && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertFalse(c.panels[0].isVisible, "panel orders out after the style's fade")
    }

    func testStreamConfigurationIsAudioOnlyAndExcludesSelf() {
        let c = CallCapture.streamConfiguration(sampleRate: 24000)
        XCTAssertTrue(c.capturesAudio)
        XCTAssertTrue(c.excludesCurrentProcessAudio)
        XCTAssertEqual(c.sampleRate, 24000)
        XCTAssertEqual(c.channelCount, 1)
        XCTAssertLessThanOrEqual(c.width, 2)
        XCTAssertLessThanOrEqual(c.height, 2)
        XCTAssertGreaterThanOrEqual(c.minimumFrameInterval.seconds, 1)
        XCTAssertEqual(CallCapture.outputTypes, [.audio], "no screen output: SCK has nowhere to deliver video")
    }

    func testCallCaptureSourceAddsNoScreenOutput() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/ListenMoreMac/CallCapture.swift"), encoding: .utf8)
        XCTAssertFalse(src.contains("type: .screen"))
        XCTAssertFalse(src.contains(".microphone"))
        XCTAssertFalse(src.contains("SCRecordingOutput"))
        XCTAssertFalse(src.contains("CVPixelBuffer"))
    }
}
