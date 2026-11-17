import AppKit
import ListenMoreCore
import QuartzCore

/// Glow colors, shape and timing. The app builds this from its shared Theme (rose and amber are
/// derived from system semantic colors), so the glow cannot drift from the cards; the Kit only draws.
public struct GlowStyle: Equatable {
    /// Interrupt, talk-over, aggressive.
    public var rose: NSColor
    /// Monologue, missed question, not listening, talk share.
    public var amber: NSColor
    public var profile: GlowProfile

    public init(rose: NSColor, amber: NSColor, profile: GlowProfile) {
        self.rose = rose
        self.amber = amber
        self.profile = profile
    }

    public func color(_ c: CueColor) -> NSColor {
        switch c {
        case .red: rose
        case .amber: amber
        }
    }
}

/// Borderless, transparent, click-through overlay panel. Never key or main and non-activating, so a
/// cue can never move keyboard focus. `sharingType = .none` asks the window server to leave it out
/// of screen captures (see the README's screen-sharing note for how far that holds).
public final class GlowPanel: NSPanel {
    /// Same level as the cards; the controller orders the glow behind the card window.
    public static let overlayLevel: NSWindow.Level = .statusBar
    public static let overlayCollectionBehavior: NSWindow.CollectionBehavior =
        [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]

    public let glowView: GlowView

    public init(frame: NSRect, style: GlowStyle) {
        glowView = GlowView(frame: NSRect(origin: .zero, size: frame.size), style: style)
        super.init(contentRect: frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        ignoresMouseEvents = true
        sharingType = .none
        // isFloatingPanel resets level to .floating, so it must be set before level.
        isFloatingPanel = true
        level = Self.overlayLevel
        collectionBehavior = Self.overlayCollectionBehavior
        becomesKeyOnlyIfNeeded = true
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        isMovable = false
        animationBehavior = .none
        alphaValue = 0
        glowView.autoresizingMask = [.width, .height]
        contentView = glowView
    }

    override public var canBecomeKey: Bool { false }
    override public var canBecomeMain: Bool { false }
}

/// Soft band along every edge of one display: opacity falls off through the profile's stops, and
/// the band follows the display's rounded corners. Drawn at full color; the panel's alpha carries
/// the peak opacity and the animation.
public final class GlowView: NSView {
    public let style: GlowStyle
    public private(set) var color: CueColor = .red

    public init(frame: NSRect, style: GlowStyle) {
        self.style = style
        super.init(frame: frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    public func setColor(_ c: CueColor) {
        guard c != color else { return }
        color = c
        needsDisplay = true
    }

    override public var isOpaque: Bool { false }

    /// Rose and amber are dynamic (per appearance): redraw when the appearance flips.
    override public func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    override public func draw(_ dirtyRect: NSRect) {
        guard let ctx = NSGraphicsContext.current?.cgContext else { return }
        let p = style.profile
        let width = CGFloat(p.width), radius = CGFloat(p.cornerRadius)
        var resolved = style.color(color)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            resolved = style.color(color).usingColorSpace(.sRGB) ?? style.color(color)
        }
        let base = resolved
        ctx.clear(bounds)
        ctx.saveGState()
        ctx.addPath(CGPath(roundedRect: bounds, cornerWidth: radius, cornerHeight: radius, transform: nil))
        ctx.clip()
        // 1 pt concentric rings, each following the inset rounded rect.
        let steps = max(Int(width.rounded(.up)), 1)
        ctx.setLineWidth(1)
        for i in 0..<steps {
            let d = CGFloat(i) + 0.5
            let a = p.factor(at: Double(d / width))
            guard a > 0 else { continue }
            let r = bounds.insetBy(dx: d, dy: d)
            guard r.width > 0, r.height > 0 else { break }
            let cr = max(radius - d, 0)
            ctx.setStrokeColor(base.withAlphaComponent(base.alphaComponent * CGFloat(a)).cgColor)
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: min(cr, r.width / 2), cornerHeight: min(cr, r.height / 2), transform: nil))
            ctx.strokePath()
        }
        ctx.restoreGState()
    }
}

/// Owns one `GlowPanel` per display and plays a cue on one of them: rise, hold, fade (~3 s in
/// total), or appear-and-fade under Reduce Motion. Plays once and never pulses or repeats; no
/// sound, ever. Cooldown is decided upstream by `CuePolicy`.
@MainActor
public final class GlowOverlayController {
    public let style: GlowStyle
    public private(set) var panels: [GlowPanel] = []
    /// The motion used by the most recent flash (tests and logs).
    public private(set) var lastMotion: GlowProfile.Motion?
    private let screenFrames: () -> [NSRect]
    private let reduceMotion: () -> Bool
    private var screenObserver: NSObjectProtocol?
    private var generation = 0
    /// While true, flashes are dropped.
    public var suppressed = false {
        didSet { if suppressed { hideAll() } }
    }

    public init(style: GlowStyle,
                screenFrames: @escaping () -> [NSRect] = { NSScreen.screens.map(\.frame) },
                reduceMotion: @escaping () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }) {
        self.style = style
        self.screenFrames = screenFrames
        self.reduceMotion = reduceMotion
        rebuildPanels()
        screenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuildPanels() }
        }
    }

    deinit {
        if let screenObserver { NotificationCenter.default.removeObserver(screenObserver) }
    }

    public func rebuildPanels() {
        panels.forEach { $0.orderOut(nil) }
        panels = screenFrames().map { GlowPanel(frame: $0, style: style) }
    }

    /// The panel covering `screen` (exact frame, else the most overlap), else the first display.
    public func panel(for screen: NSRect?) -> GlowPanel? {
        guard let screen else { return panels.first }
        if let exact = panels.first(where: { $0.frame == screen }) { return exact }
        return panels.max { area($0.frame.intersection(screen)) < area($1.frame.intersection(screen)) } ?? panels.first
    }

    private func area(_ r: NSRect) -> CGFloat { r.isNull ? 0 : r.width * r.height }

    private func present(_ color: CueColor, on screen: NSRect?, below windowNumber: Int?) -> GlowPanel? {
        guard let target = panel(for: screen) else { return nil }
        for p in panels where p !== target { p.alphaValue = 0; p.orderOut(nil) }
        target.glowView.setColor(color)
        if let windowNumber, windowNumber > 0 {
            target.order(.below, relativeTo: windowNumber)
        } else {
            target.orderFrontRegardless()
        }
        return target
    }

    /// Plays one cue on the display `screen` (Cocoa frame), ordered behind the card window if given.
    public func flash(_ color: CueColor, on screen: NSRect? = nil, below windowNumber: Int? = nil) {
        guard !suppressed else { return }
        generation += 1
        let gen = generation
        let motion = style.profile.motion(reduce: reduceMotion())
        lastMotion = motion
        guard let p = present(color, on: screen, below: windowNumber) else { return }
        let peak = CGFloat(style.profile.peakOpacity)
        p.alphaValue = peak * CGFloat(motion.appearFactor)
        guard motion.rise > 0 else {
            hold(p, motion: motion, generation: gen)
            return
        }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = motion.rise
            ctx.timingFunction = CAMediaTimingFunction(name: motion.easeRise ? .easeIn : .linear)
            p.animator().alphaValue = peak
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated { self?.hold(p, motion: motion, generation: gen) }
        })
    }

    private func hold(_ p: GlowPanel, motion: GlowProfile.Motion, generation gen: Int) {
        guard gen == generation else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + motion.hold) { [weak self] in
            MainActor.assumeIsolated { self?.fade(p, motion: motion, generation: gen) }
        }
    }

    private func fade(_ p: GlowPanel, motion: GlowProfile.Motion, generation gen: Int) {
        guard gen == generation else { return }
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = motion.fade
            ctx.timingFunction = CAMediaTimingFunction(name: motion.easeFade ? .easeOut : .linear)
            p.animator().alphaValue = 0
        }, completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self, gen == self.generation else { return }
                p.orderOut(nil)
            }
        })
    }

    /// Shows the glow at peak and leaves it up (screenshots and the screen-share probe).
    public func show(_ color: CueColor, on screen: NSRect? = nil, below windowNumber: Int? = nil) {
        generation += 1
        present(color, on: screen, below: windowNumber)?.alphaValue = CGFloat(style.profile.peakOpacity)
    }

    public func hideAll() {
        generation += 1
        panels.forEach { $0.alphaValue = 0; $0.orderOut(nil) }
    }
}
