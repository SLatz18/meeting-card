import AppKit
import QuartzCore
import SwiftUI
import MeetingCardCore

/// Borderless non-activating panel: clicks land on buttons without taking app focus.
/// Key events are routed to `onKey` (the card's KeyGate decides); Esc never closes it by default.
final class CardPanelWindow: NSPanel {
    var onKey: ((NSEvent) -> Bool)?
    /// Left click; `inCard` = on the CARD rect, not outside it (#12 review P2).
    var onMouseDown: ((_ inCard: Bool) -> Void)?
    /// #11 review P2-3: the card's current height (taller while the Next up line shows).
    var cardHeight: (() -> Double)?
    var onResign: (() -> Void)?
    /// Key ONLY while the card's KeyGate is armed (#12 review r2): with becomesKeyOnlyIfNeeded,
    /// AppKit's click-to-key can't capture focus from an off-card click behind the gate's back.
    var allowsKey: (() -> Bool)?
    override var canBecomeKey: Bool { allowsKey?() ?? false }

    override func sendEvent(_ e: NSEvent) {
        if e.type == .leftMouseDown {
            let p = e.locationInWindow
            onMouseDown?(CardLayout.cardContains(x: Double(p.x), y: Double(p.y),
                                                 height: cardHeight?() ?? CardLayout.H))
        }
        super.sendEvent(e)
    }
    override func keyDown(with e: NSEvent) {
        if onKey?(e) == true { return }
        super.keyDown(with: e)
    }
    /// NSPanel's default closes on Esc; only the KeyGate may act on Esc (via keyDown).
    override func cancelOperation(_ sender: Any?) {}
    override func resignKey() {
        super.resignKey()
        onResign?()
    }
}

/// Panel-sized root: tracks hover + movement over the CARD rect and appearance
/// changes. Pointer events go to the card's KeyGate with the GLOBAL cursor location, so the gate
/// can tell a real movement from AppKit's enter-on-appear under a resting cursor (#12 review P1).
final class CardRootView: NSView {
    var cardRect = NSRect.zero { didSet { updateTrackingAreas() } }
    var onPointer: ((KeyGate.Event) -> Void)?
    var onAppearance: (() -> Void)?
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: cardRect, options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways], owner: self)
        addTrackingArea(a)
        area = a
        super.updateTrackingAreas()
    }
    /// AppKit can deliver a mouseEntered when the panel is ordered in / tracking areas are
    /// (re)installed while the cursor is elsewhere (seen 2026-10-06: armed with the cursor 600pt
    /// away). Only a cursor that is really over the card counts.
    var cursorInsideCard: Bool {
        guard let w = window else { return false }
        return cardRect.contains(convert(w.mouseLocationOutsideOfEventStream, from: nil))
    }
    static var globalCursor: KeyGate.Point {
        let m = NSEvent.mouseLocation
        return KeyGate.Point(x: Double(m.x), y: Double(m.y))
    }
    var onSpurious: (() -> Void)?
    override func mouseEntered(with e: NSEvent) {
        let inside = cursorInsideCard
        if !inside { onSpurious?() }
        onPointer?(.hoverEnter(cursor: CardRootView.globalCursor, inCard: inside))
    }
    override func mouseMoved(with e: NSEvent) {
        onPointer?(.moved(cursor: CardRootView.globalCursor, inCard: cursorInsideCard))
    }
    override func mouseExited(with e: NSEvent) { onPointer?(.hoverExit) }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        onAppearance?()
    }
    /// codex P2: a card moved 1x <-> Retina must re-raster its border at the new scale.
    var onBackingChange: (() -> Void)?
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        onBackingChange?()
    }
}

/// Provider outline (CardBorder): ONE persistent layer per card, mutated in place. Drawn in
/// draw(in:) (clip to the stroked rounded-rect path, then a solid fill or a conic gradient), not a
/// CAGradientLayer + mask, so CALayer.render(in:) (--snapshot) draws it exactly as on screen.
final class BorderLayer: CALayer {
    var colors: [CGColor]?
    var lineWidth: CGFloat = 1.3
    var radius: CGFloat = 20

    override init() {
        super.init()
        needsDisplayOnBoundsChange = true
        actions = ["contents": NSNull(), "bounds": NSNull(), "position": NSNull(), "hidden": NSNull()]
    }
    override init(layer: Any) { super.init(layer: layer) }
    required init?(coder: NSCoder) { fatalError() }

    override func draw(in ctx: CGContext) {
        guard let colors, !colors.isEmpty else { return }
        // codex P2: match the parent's cornerCurve = .continuous clip. Stroke the FULL-bounds
        // continuous path at 2x width; the card's continuous clip trims the outer half, so the
        // visible outer edge IS the card edge (public SwiftUI Shape path, no private API).
        ctx.addPath(RoundedRectangle(cornerRadius: radius, style: .continuous).path(in: bounds).cgPath)
        ctx.setLineWidth(lineWidth * 2)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        if colors.count == 1 {
            ctx.setFillColor(colors[0])
            ctx.fill(bounds)
            return
        }
        let locs = (0..<colors.count).map { CGFloat($0) / CGFloat(colors.count - 1) }
        guard let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors as CFArray,
                                 locations: locs) else { return }
        CGContextDrawConicGradient(ctx, g, CGPoint(x: bounds.midX, y: bounds.midY), 0)   // public CG (macOS 14+); no Swift method spelling
    }
}

/// Layer-backed button with hover + pressed fills from CardPalette.
final class CardButton: NSButton {
    enum Role { case ignore, join }
    var role: Role = .ignore
    var palette: () -> CardPalette = { .for(dark: false) }
    private var hovering = false, pressing = false
    private var area: NSTrackingArea?

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    var state3: ButtonState { pressing ? .pressed : hovering ? .hover : .normal }

    func applyFill() {
        let p = palette()
        let c = role == .ignore ? p.ignoreFill(state3) : p.joinFillState(state3)
        layer?.backgroundColor = Card.ns(c).cgColor
        if role == .ignore {
            layer?.borderWidth = 0.5
            layer?.borderColor = Card.ns(p.hairline).cgColor
        }
    }

    override func updateTrackingAreas() {
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(a)
        area = a
        super.updateTrackingAreas()
    }
    override func mouseEntered(with e: NSEvent) {
        guard let w = window, bounds.contains(convert(w.mouseLocationOutsideOfEventStream, from: nil)) else { return }
        hovering = true; applyFill()
    }
    override func mouseExited(with e: NSEvent) { hovering = false; applyFill() }
    override func mouseDown(with e: NSEvent) {
        pressing = true; applyFill()
        super.mouseDown(with: e)            // tracking loop; returns on mouse-up
        pressing = false; applyFill()
    }
}

/// One card. #12: semantic text colors, per-appearance fills (light + dark),
/// no window shadow, provider outline (CardBorder),
/// hover/pressed buttons, Return/Esc after click or hover only.
final class Card: CardHandle {
    static let W = CGFloat(CardLayout.W), H = CGFloat(CardLayout.H)
    static let radius = CGFloat(CardLayout.radius), border: CGFloat = 1.3

    private(set) var ev: Event
    let rk: Rechecker
    let panel: CardPanelWindow
    let root: CardRootView
    let cardView: NSView
    /// Provider outline; created once in init, re-applied from `model` on every refresh.
    let borderLayer = BorderLayer()
    /// Fixture runs log `border demo:` / `border layers=` from the apply path (live runs: silent).
    let fixtureRun: Bool
    private var content: NSView?
    private var titleLabel: NSTextField!
    /// #11: the muted "Next up" line (nil = none). The card is `nextUpExtra` taller while set.
    private(set) var nextUp: NextUp.Parts?
    var cardH: CGFloat { CGFloat(CardLayout.cardHeight(nextUp: nextUp != nil)) }
    private var suffix: String?
    private(set) var model: CardModel
    private(set) var ignoreButton: NSButton!
    private(set) var joinButton: NSButton?
    private(set) var gate: KeyGate
    private var prevApp: NSRunningApplication?
    private var now: Date
    private var appearanceObs: NSKeyValueObservation?
    private var lastDark: Bool?
    /// The 50ms hover-exit focus give-back; cancelled on re-arm (#12 review P2).
    private var giveBack: DispatchWorkItem?
    weak var target: AnyObject?
    let ignoreAction: Selector
    let joinAction: Selector
    let log: (String) -> Void

    static func ns(_ c: RGBA) -> NSColor {
        NSColor(srgbRed: CGFloat(c.r), green: CGFloat(c.g), blue: CGFloat(c.b), alpha: CGFloat(c.a))
    }

    init(ev: Event, rk: Rechecker, now: Date, target: AnyObject, ignoreAction: Selector, joinAction: Selector,
         hoverKeys: Bool = KeyGate.hoverKeysDefault,
         fixtureRun: Bool = false, log: @escaping (String) -> Void = { _ in }) {
        self.fixtureRun = fixtureRun
        self.ev = ev
        self.rk = rk
        self.now = now
        self.model = CardModel(ev)
        self.target = target
        self.ignoreAction = ignoreAction
        self.joinAction = joinAction
        self.log = log
        gate = KeyGate(hoverKeys: hoverKeys)
        let ps = CardLayout.panelSize
        let PW = CGFloat(ps.w), PH = CGFloat(ps.h)
        panel = CardPanelWindow(contentRect: NSRect(x: 0, y: 0, width: PW, height: PH),
                                styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false             // OQ-3: no drop shadow
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.isMovableByWindowBackground = false
        panel.becomesKeyOnlyIfNeeded = true

        root = CardRootView(frame: NSRect(x: 0, y: 0, width: PW, height: PH))
        root.wantsLayer = true
        root.layer?.backgroundColor = .clear

        cardView = NSView(frame: NSRect(x: 0, y: 0, width: Card.W, height: Card.H))
        cardView.wantsLayer = true
        cardView.layer?.cornerRadius = Card.radius
        cardView.layer?.cornerCurve = .continuous
        cardView.layer?.masksToBounds = true
        root.addSubview(cardView)
        root.cardRect = cardView.frame

        borderLayer.zPosition = 1          // over the content view's layer: the stroke sits on the card edge
        borderLayer.lineWidth = Card.border
        borderLayer.radius = Card.radius
        cardView.layer?.addSublayer(borderLayer)

        panel.contentView = root
        panel.acceptsMouseMovedEvents = true
        // All callbacks [weak self]: AppKit can outlive the Card with the panel / root view
        // (#12 review P1: an appearance flip after close aborted on an unowned capture).
        root.onPointer = { [weak self] e in self?.pointer(e) }
        root.onSpurious = { [weak self] in self?.log("hover enter ignored: cursor not over card") }
        // System light/dark switch (and --appearance flips). viewDidChangeEffectiveAppearance alone
        // did not fire for an NSApp.appearance change (flip seam, 2026-10-06), so KVO is primary.
        root.onAppearance = { [weak self] in self?.appearanceChanged() }
        root.onBackingChange = { [weak self] in self?.backingChanged() }
        appearanceObs = NSApp.observe(\.effectiveAppearance, options: [.new]) { [weak self] _, _ in
            DispatchQueue.main.async { self?.appearanceChanged() }
        }
        panel.onMouseDown = { [weak self] inCard in self?.click(inCard) }
        panel.cardHeight = { [weak self] in Double(self?.cardH ?? Card.H) }
        panel.allowsKey = { [weak self] in self?.gate.allowsKey ?? false }
        panel.onResign = { [weak self] in guard let self else { return }; self.gateStep(.resigned) }
        panel.onKey = { [weak self] e in self?.key(e) ?? false }
        applyChrome()
        refresh(ev, now: now)
    }

    // MARK: appearance

    /// From the app's appearance (we never set per-view appearances): a view's effectiveAppearance
    /// can still be stale when the KVO change arrives.
    var isDark: Bool { NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }
    var palette: CardPalette { CardPalette.for(dark: isDark) }

    /// Layer colors are CGColors (not dynamic): resolve them for the current appearance.
    func applyChrome() {
        lastDark = isDark
        cardView.layer?.backgroundColor = Card.ns(palette.cardFill).cgColor
    }

    func appearanceChanged() {
        guard lastDark != isDark else { return }
        lastDark = isDark
        log("appearance -> \(isDark ? "dark" : "light")")
        applyChrome()
        refresh(ev, now: now)
    }

    /// Resolved text contrast vs the card fill (logged on --snapshot runs for review).
    func contrastReport() -> String {
        var out = ""
        NSApp.effectiveAppearance.performAsCurrentDrawingAppearance {
            let fill = palette.cardFill
            func ratio(_ c: NSColor) -> String {
                guard let s = c.usingColorSpace(.sRGB) else { return "?" }
                let fg = RGBA(Double(s.redComponent), Double(s.greenComponent), Double(s.blueComponent),
                              Double(s.alphaComponent)).over(fill)
                return String(format: "%.2f", RGBA.contrast(fg, fill))
            }
            let p = palette
            out = "contrast \(isDark ? "dark" : "light") title=\(ratio(.labelColor)) secondary=\(ratio(.secondaryLabelColor))"
                + " flag=\(String(format: "%.2f", RGBA.contrast(p.flag, fill)))"
                + " nextUp=\(String(format: "%.2f", RGBA.contrast(p.nextUp, fill)))"
                + " ignore=\(String(format: "%.2f", RGBA.contrast(p.ignoreFill(.normal).over(fill), fill)))"
                + " join=\(String(format: "%.2f", RGBA.contrast(p.joinText, p.joinFill)))"
        }
        return out
    }

    // MARK: keys

    func click(_ inCard: Bool) {
        gateStep(.click(inCard: inCard))
    }

    /// The ONE gate entry point: step (mutation ends), log while Joining, then apply.
    private func gateStep(_ e: KeyGate.Event) {
        let before = gate
        let calls = gate.step(e)
        if let l = KeyGate.openingLog(id: ev.id ?? "nil", before: before, after: gate, event: e) { log(l) }
        KeyGate.apply(calls, to: self)
    }

    func cancelGiveBack() {
        guard let g = giveBack else { return }
        g.cancel()
        giveBack = nil
        log("keys give-back cancelled (re-armed)")
    }

    func pointer(_ e: KeyGate.Event) {
        gateStep(e)
    }

    /// Hand keyboard focus back (hover-exit, re-place, Join). The panel is nonactivating, so the app
    /// Scott was typing in never stopped being active; re-activate it, and if the panel still holds
    /// key, resignKey() in place. v2.4: NEVER order the panel out/in here: that out/in was the
    /// "Joining..." flash (headless probe: resignKey() drops key with zero order-out calls).
    func releaseKey() {
        guard panel.isKeyWindow else { return }
        let prev = prevApp
        prev?.activate()
        var fallback = false
        if panel.isKeyWindow {
            fallback = true
            panel.resignKey()
        }
        log("keys released key=\(panel.isKeyWindow) fallback=\(fallback) "
            + "front=\(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "-") prev=\(prev?.bundleIdentifier ?? "-")")
    }

    func key(_ e: NSEvent) -> Bool {
        guard let a = gate.action(keyCode: e.keyCode) else { return false }
        log("key \(a == .join ? "return" : "esc")")
        switch a {
        case .join: (joinButton)?.performClick(nil)
        case .ignore: ignoreButton.performClick(nil)
        }
        return true
    }

    // MARK: content

    static func attr(_ s: String, _ font: NSFont, _ color: NSColor) -> NSAttributedString {
        NSAttributedString(string: s, attributes: [.font: font, .foregroundColor: color])
    }

    static func label(_ a: NSAttributedString, _ frame: NSRect) -> NSTextField {
        let f = NSTextField(labelWithAttributedString: a)
        f.frame = frame
        f.cell?.lineBreakMode = .byTruncatingTail
        return f
    }

    func button(_ title: String, _ role: CardButton.Role, _ frame: NSRect, image: NSImage? = nil) -> NSButton {
        let b = CardButton(frame: frame)
        b.role = role
        b.palette = { [weak self] in self?.palette ?? .for(dark: false) }
        b.isBordered = false
        b.wantsLayer = true
        b.layer?.cornerRadius = 9
        b.layer?.cornerCurve = .continuous
        let fg: NSColor = role == .ignore ? .labelColor : Card.ns(palette.joinText)
        b.attributedTitle = Card.attr(title, .systemFont(ofSize: 14, weight: .medium), fg)
        if let image {
            b.image = image
            b.imagePosition = .imageLeft
            b.imageHugsTitle = true
        }
        b.applyFill()
        return b
    }

    /// (Re)build title, Ends/flag line and buttons from ev (in place, same panel).
    func refresh(_ ev: Event, now: Date) {
        self.ev = ev
        model = CardModel(ev)
        content?.removeFromSuperview()
        let W = Card.W, H = cardH
        let v = NSView(frame: NSRect(x: 0, y: 0, width: W, height: H))

        suffix = nil
        titleLabel = Card.label(Card.attr("", .systemFont(ofSize: 17), .labelColor),
                                NSRect(x: 17, y: H - 40, width: W - 34, height: 24))
        titleLabel.maximumNumberOfLines = 1
        titleLabel.usesSingleLineMode = true
        v.addSubview(titleLabel)
        setNow(now)
        let ends = NSMutableAttributedString()
        ends.append(Card.attr(model.ends, .systemFont(ofSize: 13.5), .secondaryLabelColor))
        if let flag = model.flag {
            ends.append(Card.attr("  \u{00B7}  " + flag, .systemFont(ofSize: 13.5), Card.ns(palette.flag)))
        }
        v.addSubview(Card.label(ends, NSRect(x: 18, y: H - 67, width: W - 36, height: 20)))
        if let nextUp {
            // #11: between Ends and the buttons, in the extra height the line adds.
            // #17: own color (palette.nextUp) so it doesn't read as a second Ends line; the title
            // truncates, never " @ <time>".
            let font = NSFont.systemFont(ofSize: 12.5)
            let w = W - 36
            let text = NextUp.fit(nextUp, width: Double(w) - 4, measure: {
                Double(($0 as NSString).size(withAttributes: [.font: font]).width) })
            let nl = Card.label(Card.attr(text, font, Card.ns(palette.nextUp)),
                                NSRect(x: 18, y: H - 90, width: w, height: 18))
            nl.maximumNumberOfLines = 1   // belt-and-braces: never wrap, the time stays visible
            nl.usesSingleLineMode = true
            v.addSubview(nl)
        }

        ignoreButton = button("Ignore", .ignore, NSRect(x: 17, y: 15, width: 67, height: 33))
        ignoreButton.target = target
        ignoreButton.action = ignoreAction
        v.addSubview(ignoreButton)

        joinButton = nil
        if let link = model.link, let title = model.openingTitle(isOpening) {
            let b: NSButton
            if link.provider == "calendar" {
                let jw: CGFloat = 142
                b = button(title, .join, NSRect(x: W - 16 - jw, y: 15, width: jw, height: 33))
            } else if isOpening {
                // v2.4: built as "Joining..." (no icon) directly: no intermediate normal title.
                let jw: CGFloat = link.provider == "meet" ? 110 : 114
                b = button(title, .join, NSRect(x: W - 16 - jw, y: 15, width: jw, height: 33))
                log(KeyGate.openingTitleLog(id: ev.id ?? "nil", title: title))
            } else {
                let jw: CGFloat = link.provider == "meet" ? 110 : 114
                b = button(" " + title, .join, NSRect(x: W - 16 - jw, y: 15, width: jw, height: 33),
                           image: Icons.icon(link.provider, size: 20))
            }
            b.target = target
            b.action = joinAction
            v.addSubview(b)
            joinButton = b
        }
        cardView.addSubview(v)
        content = v
        applyBorder()
    }

    /// Backing scale changed (screen move): re-raster the outline at the new scale.
    func backingChanged() {
        let scale = panel.backingScaleFactor > 0 ? panel.backingScaleFactor : 2
        borderLayer.contentsScale = scale
        borderLayer.setNeedsDisplay()
        if fixtureRun { log("border scale=\(scale)") }
    }

    /// Re-apply the provider outline from the CURRENT model, height and appearance (in place).
    func applyBorder() {
        let cs = CardBorder.colors(for: model, dark: isDark)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        borderLayer.frame = cardView.bounds
        borderLayer.contentsScale = panel.backingScaleFactor > 0 ? panel.backingScaleFactor : 2
        borderLayer.colors = cs?.map { Card.ns($0).cgColor }
        borderLayer.isHidden = cs == nil
        borderLayer.setNeedsDisplay()
        borderLayer.displayIfNeeded()
        CATransaction.commit()
        if fixtureRun {
            let n = cardView.layer?.sublayers?.filter { $0 is BorderLayer }.count ?? 0
            log("border demo: \(cs == nil ? "none" : model.link?.provider ?? "none") \(isDark ? "dark" : "light") h=\(Int(borderLayer.frame.height))")
            log("border layers=\(n)")
        }
    }

    /// #4: "Joining..." after Join; false rebuilds the normal Join button. The state is stored
    /// (#4 review P2) so every refresh path (live update, appearance flip) re-applies it.
    private(set) var isOpening = false
    func setOpening(_ on: Bool) {
        isOpening = on
        gateStep(.opening(on))
        guard on else { refresh(ev, now: now); log("join back \(ev.id ?? "nil")"); return }
        applyOpeningLabel()
    }

    private func applyOpeningLabel() {
        guard let b = joinButton, let title = model.openingTitle(isOpening) else { return }
        b.image = nil
        b.attributedTitle = Card.attr(title, .systemFont(ofSize: 14, weight: .medium), Card.ns(palette.joinText))
        if isOpening { log(KeyGate.openingTitleLog(id: ev.id ?? "nil", title: title)) }
        // Relabel, not isEnabled=false: AppKit's disabled look made the label unreadable. A second
        // click / Return while opening is a no-op in Core (Coordinator.join, "already opening").
    }

    /// Live countdown suffix ("in 2 min" / "in 1 min" / "now"); only redraws on change.
    func setNow(_ now: Date) {
        self.now = now
        let s = Timing.countdownSuffix(ev, now)
        if s == suffix { return }
        suffix = s
        let f = NSFont.systemFont(ofSize: 17, weight: .semibold)
        let t = NSMutableAttributedString()
        // v2.5 #4: only the title truncates (measured in this font); " <countdown>" always shows.
        let fit = CardLayout.fitTitle(model.title, fixture: fixtureRun, suffix: s,
                                      width: Double(titleLabel.frame.width) - 4, measure: {
            Double(($0 as NSString).size(withAttributes: [.font: f]).width) })
        t.append(Card.attr(fit.title, f, .labelColor))
        t.append(Card.attr(fit.suffix, f, .secondaryLabelColor))
        titleLabel.attributedStringValue = t
    }

    /// #11: show / hide the Next up line. Height changes resize in place (bottom edge fixed);
    /// Core re-places the cards above AND this card (#11 review P2-2: a resize is a KeyGate placement).
    func setNextUp(_ line: NextUp.Parts?) {
        guard line != nextUp else { return }
        let grows = (line != nil) != (nextUp != nil)
        nextUp = line
        if grows {
            let size = NSSize(width: Card.W, height: cardH)
            panel.setFrame(NSRect(origin: panel.frame.origin, size: size), display: false)
            root.frame = NSRect(origin: .zero, size: size)
            cardView.frame = NSRect(x: 0, y: 0, width: Card.W, height: cardH)
            root.cardRect = cardView.frame
        }
        refresh(ev, now: now)
    }

    /// Card edge `margin` from the visibleFrame's bottom-right (above the Dock); stack upward.
    /// Fixture runs: bottom-LEFT instead (CardLayout.corner), never the live slot.
    func place(_ slot: CardSlot) {
        guard let vf = NSScreen.main?.visibleFrame else { return }
        let o = CardLayout.panelOrigin(offset: slot.offset, minY: Double(vf.minY), minX: Double(vf.minX),
                                       maxX: Double(vf.maxX), corner: CardLayout.corner(fixture: fixtureRun))
        panel.setFrameOrigin(NSPoint(x: o.x, y: o.y))
        gateStep(.placed(cursor: CardRootView.globalCursor))
    }

    /// Never makes the panel key on appear (#12): keys arm only on click or hover.
    func show(_ slot: CardSlot) {
        place(slot)
        gateStep(.appear(cursor: CardRootView.globalCursor))
        panel.orderFrontRegardless()
        log("shown key=\(panel.isKeyWindow)")
    }

    /// Detach every AppKit callback BEFORE teardown: the panel / root view can outlive the Card.
    func close() {
        appearanceObs?.invalidate()
        appearanceObs = nil
        giveBack?.cancel(); giveBack = nil
        root.onAppearance = nil; root.onBackingChange = nil; root.onPointer = nil; root.onSpurious = nil
        panel.onKey = nil; panel.onMouseDown = nil; panel.onResign = nil; panel.allowsKey = nil
        panel.cardHeight = nil
        panel.orderOut(nil)
        panel.close()
    }

    /// Render the layer tree to PNG via CALayer.render(in:) (CTO ruling 7). The PNG is card-sized
    /// (panel frame == card rect).
    func snapshot(to path: String) -> Bool {
        root.layoutSubtreeIfNeeded()
        root.displayIfNeeded()
        let scale = panel.backingScaleFactor > 0 ? panel.backingScaleFactor : 2
        let w = Int(root.bounds.width * scale), h = Int(root.bounds.height * scale)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.scaleBy(x: scale, y: scale)
        root.layer?.render(in: ctx)
        guard let img = ctx.makeImage() else { return false }
        return Card.writePNG(img, path)
    }

    static func writePNG(_ img: CGImage, _ path: String) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL, "public.png" as CFString, 1, nil)
        else { return false }
        CGImageDestinationAddImage(dest, img, nil)
        return CGImageDestinationFinalize(dest)
    }

}

/// KeyGate effects land here (decided in Core by `KeyGate.step`, applied by `KeyGate.apply`).
extension Card: KeySurface {
    func makeKey() {
        let front = NSWorkspace.shared.frontmostApplication
        prevApp = front?.processIdentifier == getpid() ? nil : front
        panel.makeKey()
        log("keys armed front=\(prevApp?.bundleIdentifier ?? "-")")
    }
}
