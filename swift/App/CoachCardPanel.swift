import AppKit
import MeetingCardCore
import QuartzCore

/// The coach card's window. Every coach state (the card, the pill, the morph from the reminder
/// card, nudges, the captions) draws in this one panel. Captures leave it out (`sharingType` `.none`)
/// unless "Show Coach in Screenshots" is on; that setting alone changes it, through `SharingRegistry`.
final class CoachCardPanel: NSPanel {
    static func make() -> CoachCardPanel {
        let p = CoachCardPanel(contentRect: NSRect(origin: .zero, size: CoachFullCardView.size),
                               styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        p.sharing = .excluded
        p.isFloatingPanel = true
        p.level = .statusBar
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.isOpaque = false
        p.backgroundColor = .clear
        p.hasShadow = CardStyle.Material.shadow
        p.animationBehavior = CardStyle.Material.animates ? .default : .none
        p.hidesOnDeactivate = false
        p.isReleasedWhenClosed = false
        p.isMovableByWindowBackground = false
        p.becomesKeyOnlyIfNeeded = true
        return p
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}

final class CoachRootView: NSView {
    var onAppearance: (() -> Void)?

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearance?()
    }
}

/// Shows the coach card: morphs it out of the reminder card in place and glides it to its spot
/// (Reduce Motion: fades out and back in there), collapses it to the pill and expands it back,
/// resizes in place for the tip row or Mute in Zoom (never for a cue), and follows the call to its display. The spot is
/// `CoachPlacement`'s; a drag moves it, is kept inside the visible frame, and is remembered.
@MainActor
final class CoachCardPresenter {
    let panel = CoachCardPanel.make()
    let root = CoachRootView()
    let defaults: UserDefaults
    let positionKey: String
    let captions: CoachCaptionsSlot
    var actions = CoachCardActions()
    /// The display the coach last found the call on (`CoachService.glowScreen`, so the service's
    /// `locateScreen` choice of the call's window), if any. The card never picks a window itself.
    var callScreen: () -> NSRect? = { nil }
    var reduceMotion: () -> Bool = { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }
    var displays: () -> [CoachDisplay] = { CoachCardPresenter.screens() }
    /// After each transition, once nothing is pending.
    var onSettled: (() -> Void)?
    private(set) var state: CoachCardState?
    private(set) var content: CoachSurfaceView?
    /// The reminder card the coach card morphed out of (hidden while the coach card shows).
    private(set) weak var morphedCard: Card?
    private var captionsView: NSView?
    private(set) var transitioning = false
    private var pending: CoachCardState?
    private var generation = 0

    init(defaults: UserDefaults, positionKey: String, captions: CoachCaptionsSlot) {
        self.defaults = defaults
        self.positionKey = positionKey
        self.captions = captions
        root.wantsLayer = true
        root.layer?.cornerCurve = .continuous
        root.layer?.masksToBounds = true
        root.layer?.cornerRadius = Theme.cg(Theme.CoachCard.radius)
        root.autoresizesSubviews = true
        panel.contentView = root
        root.onAppearance = { [weak self] in self?.applyChrome() }
        applyChrome()
    }

    var isShown: Bool { panel.isVisible }

    private var isDark: Bool { root.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    func applyChrome() {
        var bg = Theme.ns(Theme.style(dark: isDark).surface).cgColor
        root.effectiveAppearance.performAsCurrentDrawingAppearance { bg = Theme.ns(Theme.style(dark: self.isDark).surface).cgColor }
        root.layer?.backgroundColor = bg
    }

    // MARK: show, update, hide

    /// Shows the coach card for `s`, morphing out of `card` when there is one on screen.
    func show(_ s: CoachCardState, from card: Card?) {
        generation += 1
        pending = nil
        state = s
        let incoming = makeContent(s)
        let target = spot(size: incoming.frame.size, cardScreen: card?.panel.screen?.frame)
        root.subviews.forEach { $0.removeFromSuperview() }
        setRadius(incoming.surfaceRadius)
        panel.alphaValue = 1
        guard let card, card.panel.isVisible, let image = card.snapshotImage() else {
            panel.setFrame(target, display: false)
            incoming.frame.origin = .zero
            root.addSubview(incoming)
            content = incoming
            panel.orderFrontRegardless()
            return settle()
        }
        let start = card.panel.frame
        let outgoing = NSImageView(frame: NSRect(origin: .zero, size: start.size))
        outgoing.image = NSImage(cgImage: image, size: start.size)
        outgoing.imageScaling = .scaleAxesIndependently
        outgoing.autoresizingMask = [.maxXMargin, .maxYMargin]
        panel.setFrame(start, display: false)
        root.addSubview(outgoing)
        incoming.frame.origin = .zero
        incoming.autoresizingMask = [.maxXMargin, .maxYMargin]
        incoming.alphaValue = 0
        root.addSubview(incoming)
        content = incoming
        panel.orderFrontRegardless()
        card.panel.orderOut(nil)
        morphedCard = card
        if reduceMotion() {
            run(.morph, to: target, outgoing: outgoing, incoming: incoming)
        } else {
            let inPlace = clampedOnItsDisplay(NSRect(origin: start.origin, size: incoming.frame.size))
            run(.morph, to: inPlace, outgoing: outgoing, incoming: incoming) { [weak self] in
                self?.run(.glide, to: target, outgoing: nil, incoming: incoming)
            }
        }
    }

    func update(_ s: CoachCardState) {
        guard isShown, let old = state, let current = content else { return }
        if transitioning {
            pending = s
            return
        }
        state = s
        if s.mode != old.mode {
            swap(current, for: s, transition: s.mode == .pill ? .collapse : .expand)
        } else if s.mode == .pill, CoachPillView.width(for: s) != Double(current.frame.width)
                    || (current as? CoachPillView)?.buttons != s.pillButtons {
            swap(current, for: s, transition: .widen)
        } else if s.mode == .card, CoachFullCardView.frameSize(for: s) != current.frame.size {
            swap(current, for: s, transition: .widen)
        } else {
            current.apply(s)
            followCallDisplay()
        }
    }

    /// Hides at once (windows leave without animation). Returns the reminder card it morphed out of.
    @discardableResult
    func hide() -> Card? {
        generation += 1
        pending = nil
        transitioning = false
        panel.orderOut(nil)
        panel.alphaValue = 1
        content?.removeFromSuperview()
        content = nil
        state = nil
        captionsView = nil
        let card = morphedCard
        morphedCard = nil
        return card
    }

    /// VoiceOver reads `text` (nudges, and Stop's confirmation).
    static func announce(_ text: String) {
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: text, .priority: NSAccessibilityPriorityLevel.high.rawValue])
    }

    // MARK: content

    private func makeContent(_ s: CoachCardState) -> CoachSurfaceView {
        let v: CoachSurfaceView
        switch s.mode {
        case .card:
            let c = captionsView ?? captions.makeView()
            captionsView = c
            v = CoachFullCardView(state: s, actions: actions, captions: c)
        case .pill:
            v = CoachPillView(state: s, actions: actions)
        }
        v.clamp = { [weak self, weak v] o in
            guard let self, let v else { return o }
            return self.clamp(o, size: v.frame.size)
        }
        v.onDragged = { [weak self] in self?.saveOffset() }
        return v
    }

    /// Card and pill share a top-center: the new layout comes in centered on it as the old one goes.
    private func swap(_ current: CoachSurfaceView, for s: CoachCardState, transition: CoachTransition) {
        let incoming = makeContent(s)
        let old = panel.frame.size, new = incoming.frame.size
        let target: NSRect
        if let d = displayOfPanel() {
            let o = CoachPlacement.resize(origin: (Double(panel.frame.minX), Double(panel.frame.minY)),
                                          from: (Double(old.width), Double(old.height)), to: (Double(new.width), Double(new.height)), on: d)
            target = NSRect(x: o.x, y: o.y, width: new.width, height: new.height)
        } else {
            target = NSRect(x: panel.frame.midX - new.width / 2, y: panel.frame.maxY - new.height, width: new.width, height: new.height)
        }
        let topCenter: NSView.AutoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        current.autoresizingMask = topCenter
        incoming.frame.origin = NSPoint(x: (old.width - new.width) / 2, y: old.height - new.height)
        incoming.autoresizingMask = topCenter
        incoming.alphaValue = 0
        root.addSubview(incoming)
        content = incoming
        run(transition, to: target, outgoing: current, incoming: incoming, radius: incoming.surfaceRadius)
    }

    private func setRadius(_ r: Double) { root.layer?.cornerRadius = Theme.cg(r) }

    // MARK: motion

    /// Runs `t`'s steps from the panel's frame to `target`, fading `outgoing` out and `incoming` in.
    private func run(_ t: CoachTransition, to target: NSRect, outgoing: NSView?, incoming: NSView, radius: Double? = nil,
                     then next: (() -> Void)? = nil) {
        let steps = CoachMotion.steps(t, reduceMotion: reduceMotion())
        let start = panel.frame, gen = generation
        transitioning = true
        func finish() {
            outgoing?.removeFromSuperview()
            panel.setFrame(target, display: true)
            incoming.alphaValue = 1
            incoming.frame.origin = .zero
            incoming.autoresizingMask = []
            panel.alphaValue = 1
            if let radius { setRadius(radius) }
            transitioning = false
            if let next { next() } else { settle() }
        }
        func step(_ i: Int) {
            guard gen == generation else { return }
            guard i < steps.count else { return finish() }
            let s = steps[i]
            if i == steps.count - 1, let radius { setRadius(radius) }
            let frame = Self.interpolate(start, target, s.frameProgress)
            if !s.animatesFrame {
                panel.setFrame(frame, display: true)
                if panel.alphaValue == 0 {
                    outgoing?.alphaValue = CGFloat(s.outgoingAlpha)
                    incoming.alphaValue = CGFloat(s.incomingAlpha)
                }
            }
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = s.duration
                ctx.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
                if s.animatesFrame { self.panel.animator().setFrame(frame, display: true) }
                outgoing?.animator().alphaValue = CGFloat(s.outgoingAlpha)
                incoming.animator().alphaValue = CGFloat(s.incomingAlpha)
                self.panel.animator().alphaValue = CGFloat(s.surfaceAlpha)
            }, completionHandler: {
                MainActor.assumeIsolated { step(i + 1) }
            })
        }
        step(0)
    }

    private func settle() {
        if let p = pending {
            pending = nil
            update(p)
            if transitioning { return }
        }
        onSettled?()
    }

    static func interpolate(_ a: NSRect, _ b: NSRect, _ k: Double) -> NSRect {
        let t = CGFloat(k)
        return NSRect(x: a.minX + (b.minX - a.minX) * t, y: a.minY + (b.minY - a.minY) * t,
                      width: a.width + (b.width - a.width) * t, height: a.height + (b.height - a.height) * t)
    }

    // MARK: placement

    static func frame(_ r: NSRect) -> CoachDisplay.Frame {
        CoachDisplay.Frame(x: Double(r.minX), y: Double(r.minY), width: Double(r.width), height: Double(r.height))
    }

    /// Every display, with whether it holds the built-in camera.
    static func screens() -> [CoachDisplay] {
        NSScreen.screens.map { s in
            let n = (s.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
            return CoachDisplay(id: Int(n), frame: frame(s.frame), visibleFrame: frame(s.visibleFrame),
                                safeAreaTop: Double(s.safeAreaInsets.top), builtIn: CGDisplayIsBuiltin(n) != 0)
        }
    }

    private func display(for screen: NSRect?, in ds: [CoachDisplay]) -> CoachDisplay? {
        guard let screen else { return nil }
        let f = Self.frame(screen)
        return ds.first { $0.frame == f }
    }

    private func displayOfPanel() -> CoachDisplay? {
        let ds = displays(), c = NSPoint(x: panel.frame.midX, y: panel.frame.midY)
        return ds.first { NSRect(x: $0.frame.x, y: $0.frame.y, width: $0.frame.width, height: $0.frame.height).contains(c) }
            ?? display(for: panel.screen?.frame, in: ds) ?? ds.first
    }

    var savedOffset: CoachOffset? {
        guard let v = defaults.array(forKey: positionKey) as? [Double], v.count == 2 else { return nil }
        return CoachOffset(dx: v[0], dy: v[1])
    }

    private func saveOffset() {
        guard let d = displayOfPanel() else { return }
        let f = panel.frame
        let o = CoachPlacement.offset(origin: (Double(f.minX), Double(f.minY)), size: (Double(f.width), Double(f.height)), on: d)
        defaults.set([o.dx, o.dy], forKey: positionKey)
    }

    /// The spot on the call's display (the card's until the call's is known).
    func spot(size: NSSize, cardScreen: NSRect?) -> NSRect {
        let ds = displays()
        guard let d = CoachPlacement.display(call: display(for: callScreen(), in: ds)?.id, card: display(for: cardScreen, in: ds)?.id,
                                             displays: ds) else { return NSRect(origin: .zero, size: size) }
        return spot(on: d, size: size)
    }

    private func spot(on d: CoachDisplay, size: NSSize) -> NSRect {
        let o = CoachPlacement.origin(size: (Double(size.width), Double(size.height)), on: d, offset: savedOffset)
        return NSRect(x: o.x, y: o.y, width: size.width, height: size.height)
    }

    private func clamp(_ origin: NSPoint, size: NSSize) -> NSPoint {
        guard let d = displayOfPanel() else { return origin }
        let o = CoachPlacement.clamp(origin: (Double(origin.x), Double(origin.y)), size: (Double(size.width), Double(size.height)), on: d)
        return NSPoint(x: o.x, y: o.y)
    }

    private func clampedOnItsDisplay(_ r: NSRect) -> NSRect {
        NSRect(origin: clamp(r.origin, size: r.size), size: r.size)
    }

    /// The call turned out to be on another display: glide there.
    private func followCallDisplay() {
        guard let content, !transitioning else { return }
        let ds = displays()
        guard let call = display(for: callScreen(), in: ds), call.id != displayOfPanel()?.id else { return }
        run(.glide, to: spot(on: call, size: content.frame.size), outgoing: nil, incoming: content)
    }
}
