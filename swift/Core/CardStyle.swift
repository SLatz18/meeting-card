import Foundation

/// #12 card geometry. The CARD sits `margin` from the visibleFrame's bottom-right edge;
/// the panel frame == the card rect.
public enum CardLayout {
    public static let W: Double = 400, H: Double = 126
    public static let margin: Double = 14, radius: Double = 20
    /// Card-edge to card-edge gap between stacked cards (OQ-4).
    public static let baseGap: Double = 20
    public static var gap: Double { baseGap }
    /// #11: the "Next up" line adds this much card height (only while the line is shown).
    public static let nextUpExtra: Double = 18
    public static func cardHeight(nextUp: Bool) -> Double { H + (nextUp ? nextUpExtra : 0) }
    /// #11: card-edge offset of a stack slot = sum of (card height + gap) of the cards below.
    public static func stackOffset(below hasNextUp: [Bool]) -> Double {
        hasNextUp.reduce(0) { $0 + cardHeight(nextUp: $1) + gap }
    }
    /// Panel origin for a card whose bottom edge sits `offset` above the first slot.
    public static func panelOrigin(offset: Double, minY: Double, maxX: Double) -> (x: Double, y: Double) {
        (maxX - W - margin, minY + margin + offset)
    }
    public static var panelSize: (w: Double, h: Double) { (W, H) }
    /// Screen corner the stack grows from. Fixture (demo) runs use bottom-LEFT so a demo card never
    /// shares the live card's bottom-right slot (2026-10-07: a demo card read as the live card).
    public enum Corner: Equatable, Sendable { case bottomRight, bottomLeft }
    public static func corner(fixture: Bool) -> Corner { fixture ? .bottomLeft : .bottomRight }
    /// Corner-aware origin: same `margin` and upward stacking; bottomRight == the legacy overload.
    public static func panelOrigin(offset: Double, minY: Double, minX: Double, maxX: Double,
                                   corner: Corner) -> (x: Double, y: Double) {
        let o = panelOrigin(offset: offset, minY: minY, maxX: maxX)
        switch corner {
        case .bottomRight: return o
        case .bottomLeft: return (minX + margin, o.y)
        }
    }
    /// The card's own title line: fixture runs prefix "DEMO · " so a demo can't pass for a real card.
    public static func displayTitle(_ title: String, fixture: Bool) -> String {
        fixture ? "DEMO \u{00B7} " + title : title
    }

    /// v2.5 #4: the title line fitted to `width`: only the (whitespace-collapsed, DEMO-prefixed)
    /// title truncates with a tail ellipsis; suffix = " <countdown>" always whole.
    public static func fitTitle(_ title: String, fixture: Bool, suffix: String, width: Double,
                                measure: (String) -> Double) -> (title: String, suffix: String) {
        let t = displayTitle(NextUp.flatten(title), fixture: fixture), sfx = " " + suffix
        let line = NextUp.tailFit(prefix: "", title: t, suffix: sfx, width: width, measure: measure)
        return (String(line.dropLast(sfx.count)), sfx)
    }

    /// Panel origin for stack slot `index` (0 = bottom), in screen coordinates.
    /// Is a panel-local point (origin bottom-left of the panel) on the CARD?
    /// #11 review P2-3: `height` = the card's CURRENT height (126, or 144 while the Next up line shows).
    public static func cardContains(x: Double, y: Double, height: Double = H) -> Bool {
        x >= 0 && x <= W && y >= 0 && y <= height
    }

    public static func panelOrigin(index: Int, minY: Double, maxX: Double) -> (x: Double, y: Double) {
        (maxX - W - margin, minY + margin + Double(index) * (H + gap))
    }
}

/// sRGB color with alpha, 0...1 components. Equality is exact (palette constants only).
public struct RGBA: Equatable, Sendable {
    public let r: Double, g: Double, b: Double, a: Double
    public init(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) { self.r = r; self.g = g; self.b = b; self.a = a }
    public init(hex: UInt32, _ a: Double = 1) {
        self.init(Double((hex >> 16) & 0xFF) / 255, Double((hex >> 8) & 0xFF) / 255, Double(hex & 0xFF) / 255, a)
    }
    public static func white(_ a: Double) -> RGBA { RGBA(1, 1, 1, a) }
    public static func black(_ a: Double) -> RGBA { RGBA(0, 0, 0, a) }

    /// Source-over onto an opaque background.
    public func over(_ bg: RGBA) -> RGBA {
        RGBA(r * a + bg.r * (1 - a), g * a + bg.g * (1 - a), b * a + bg.b * (1 - a), 1)
    }

    /// WCAG relative luminance (alpha ignored).
    public var luminance: Double {
        func lin(_ c: Double) -> Double { c <= 0.04045 ? c / 12.92 : pow((c + 0.055) / 1.055, 2.4) }
        return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)
    }

    public static func contrast(_ x: RGBA, _ y: RGBA) -> Double {
        let a = x.luminance, b = y.luminance
        return (max(a, b) + 0.05) / (min(a, b) + 0.05)
    }
}

public enum ButtonState: Sendable { case normal, hover, pressed }

/// Non-text card colors per appearance. Text uses AppKit semantic colors (labelColor /
/// secondaryLabelColor) in the App layer; these are the fills AppKit has no semantic for.
public struct CardPalette: Sendable {
    public let dark: Bool
    public let cardFill: RGBA
    public let hairline: RGBA
    public let flag: RGBA
    public let joinFill: RGBA
    public let joinText: RGBA
    /// #17: the Next up line's color (distinct from the Ends line's secondaryLabelColor).
    /// Measured vs cardFill: light #0A5CC2 5.75:1, dark #64A8FF 5.70:1.
    public let nextUp: RGBA
    let ignore: (normal: RGBA, hover: RGBA, pressed: RGBA)
    let join: (hover: RGBA, pressed: RGBA)

    public func ignoreFill(_ s: ButtonState) -> RGBA {
        switch s { case .normal: ignore.normal; case .hover: ignore.hover; case .pressed: ignore.pressed }
    }
    public func joinFillState(_ s: ButtonState) -> RGBA {
        switch s { case .normal: joinFill; case .hover: join.hover; case .pressed: join.pressed }
    }

    public static func `for`(dark: Bool) -> CardPalette { dark ? darkPalette : lightPalette }

    // Light keeps the Dia look (#F4F4F4 card, near-black pill). Amber darkened from #C08A2E
    // (2.8:1) to #966312 (4.7:1) so the flag text clears 4.5:1.
    static let lightPalette = CardPalette(
        dark: false, cardFill: RGBA(hex: 0xF4F4F4), hairline: .black(0.12), flag: RGBA(hex: 0x966312),
        joinFill: RGBA(hex: 0x1C1C1E), joinText: RGBA(hex: 0xFFFFFF), nextUp: RGBA(hex: 0x0A5CC2),
        ignore: (.black(0.11), .black(0.16), .black(0.23)),
        join: (RGBA(hex: 0x3A3A3C), RGBA(hex: 0x000000)))

    static let darkPalette = CardPalette(
        dark: true, cardFill: RGBA(hex: 0x2C2C2E), hairline: .white(0.14), flag: RGBA(hex: 0xFF9F0A),
        joinFill: RGBA(hex: 0xF2F2F7), joinText: RGBA(hex: 0x1C1C1E), nextUp: RGBA(hex: 0x64A8FF),
        ignore: (.white(0.14), .white(0.20), .white(0.28)),
        join: (RGBA(hex: 0xFFFFFF), RGBA(hex: 0xC7C7CC)))
}

/// What the App's card does with a KeyGate effect (`KeyGate.step` + `KeyGate.apply`).
public protocol KeySurface: AnyObject {
    /// Make the panel key (the gate is already armed, so `canBecomeKey` agrees).
    func makeKey()
    /// Hand keyboard focus back to the app Scott was in.
    func releaseKey()
    /// Cancel a pending delayed give-back (re-armed in the meantime).
    func cancelGiveBack()
}

/// Return/Esc gating (#12): keys only after Scott clicks or hovers the CARD, never on appear.
/// #12 review: hover arms only after a REAL pointer movement inside the card (cursor over the card)
/// since the last appear / re-place: AppKit sends hover-enter when a panel appears or is re-stacked
/// under a resting cursor, and that must not steal keys.
public struct KeyGate: Sendable {
    /// OQ-5: hover arms keys (and makes the panel key) by default; set false for click-only.
    public static let hoverKeysDefault = true

    /// Global (screen) mouse location.
    public struct Point: Equatable, Sendable {
        public let x: Double, y: Double
        public init(x: Double, y: Double) { self.x = x; self.y = y }
    }

    public enum Event: Sendable {
        /// Card shown / re-placed (stack slot change): `cursor` = global mouse location then.
        case appear(cursor: Point), placed(cursor: Point)
        case click(inCard: Bool)
        case hoverEnter(cursor: Point, inCard: Bool), moved(cursor: Point, inCard: Bool)
        case hoverExit, resigned
        /// v2.4: the card entered / left "Joining..." (Coordinator.join -> Card.setOpening).
        case opening(Bool)
    }
    public enum Effect: Equatable, Sendable { case none, makeKey, releaseKey }
    public enum KeyAction: Equatable, Sendable { case join, ignore }

    public let hoverKeys: Bool
    public private(set) var armed = false
    /// Cursor at the last appear / place (nil = never placed: any location counts as moved).
    public private(set) var anchor: Point?
    public private(set) var pointerMovedSincePlacement = false
    /// v2.4: the card is "Joining...": hover / click never arm.
    public private(set) var opening = false

    public init(hoverKeys: Bool = KeyGate.hoverKeysDefault) { self.hoverKeys = hoverKeys }

    /// A delayed focus give-back (after hover-exit) may act only while still disarmed.
    public var shouldGiveBackFocus: Bool { !armed }
    /// #12 review r2: the panel may become key ONLY while armed (`canBecomeKey` asks this; the
    /// arming path sets `armed` before calling `makeKey()`), so no click can bypass the gate.
    public var allowsKey: Bool { armed }

    public mutating func handle(_ e: Event) -> Effect {
        switch e {
        case .appear(let c):
            armed = false
            anchor = c; pointerMovedSincePlacement = false
            return .none
        case .placed(let c):
            // #12 review r2: a re-place disarms and hands focus back (same path as hover-exit).
            anchor = c; pointerMovedSincePlacement = false
            guard armed else { return .none }
            armed = false
            return .releaseKey
        case .resigned:
            armed = false
            return .none
        case .opening(let on):
            // v2.4: no arming while Joining (Scott's pointer crossing the card as the meeting app
            // takes over armed/released repeatedly). Entering Joining hands key back once.
            opening = on
            guard on, armed else { return .none }
            armed = false
            return .releaseKey
        case .click(let inCard):
            guard inCard else { return .none }   // clicks off the card never arm (#12 review P2)
            guard !opening else { return .none }
            guard !armed else { return .none }
            armed = true            // before makeKey: canBecomeKey == allowsKey (becomesKeyOnlyIfNeeded)
            return .makeKey
        case .hoverEnter(let c, let inCard), .moved(let c, let inCard):
            guard inCard else { return .none }
            if c != anchor { pointerMovedSincePlacement = true }
            guard hoverKeys, pointerMovedSincePlacement, !armed, !opening else { return .none }
            armed = true
            return .makeKey
        case .hoverExit:
            guard hoverKeys, armed else { return .none }
            armed = false
            return .releaseKey
        }
    }

    /// A surface call decided by `step` (applied by `KeyGate.apply`).
    public enum SurfaceCall: Equatable, Sendable { case cancelGiveBack, makeKey, releaseKey }

    /// codex #12 P2: the ONE place a gate effect is turned into surface calls (the App's Card is
    /// the surface), so the click / hover / place / resign wiring is unit-testable.
    /// Arming always cancels a pending focus give-back first (renewed focus wins).
    /// #4 review P1: `step` ONLY mutates and returns the calls; `apply` runs them after the
    /// mutation has ended, because AppKit's canBecomeKey reads `allowsKey` synchronously inside
    /// makeKey() (an overlapping read of a gate being mutated = Swift exclusivity trap).
    /// App call shape: `KeyGate.apply(gate.step(e), to: self)`.
    public mutating func step(_ e: Event) -> [SurfaceCall] {
        let wasArmed = armed
        switch handle(e) {
        case .makeKey: return [.cancelGiveBack, .makeKey]
        case .releaseKey: return [.releaseKey]
        case .none:
            if case .click(true) = e, wasArmed, armed { return [.cancelGiveBack] }
            return []
        }
    }

    /// Non-mutating: callbacks may freely read the gate they came from.
    public static func apply(_ calls: [SurfaceCall], to s: KeySurface) {
        for c in calls {
            switch c {
            case .cancelGiveBack: s.cancelGiveBack()
            case .makeKey: s.makeKey()
            case .releaseKey: s.releaseKey()
            }
        }
    }

    /// Return / keypad Enter = Join (or Open in Calendar); Esc = Ignore. nil = not ours.
    public func action(keyCode: UInt16) -> KeyAction? {
        guard armed else { return nil }
        switch keyCode {
        case 36, 76: return .join
        case 53: return .ignore
        default: return nil
        }
    }
}

/// v2.4 addendum (Scott's click -> exit repro): while a card is "Joining...", every gate step and
/// every Join-title set is logged so a live run shows the sequence. Nothing is logged otherwise, and
/// only event NAMES go out (never event JSON / coordinates).
public extension KeyGate {
    /// "idle" / "armed", prefixed "opening:" while Joining.
    var stateLabel: String { (opening ? "opening:" : "") + (armed ? "armed" : "idle") }

    static func eventLabel(_ e: Event) -> String {
        switch e {
        case .appear: "appear"
        case .placed: "placed"
        case .click(let c): c ? "click" : "click-outside"
        case .hoverEnter(_, let c): c ? "enter" : "enter-outside"
        case .moved(_, let c): c ? "moved" : "moved-outside"
        case .hoverExit: "exit"
        case .resigned: "resigned"
        case .opening(let on): on ? "opening-on" : "opening-off"
        }
    }

    /// nil unless the card was or is opening (no log noise outside Joining) AND the gate state
    /// actually changed (v2.5: pointer moves that leave opening:idle as-is are never logged).
    static func openingLog(id: String, before: KeyGate, after: KeyGate, event: Event) -> String? {
        guard before.opening || after.opening else { return nil }
        guard before.stateLabel != after.stateLabel else { return nil }
        return "opening \(id): gate \(before.stateLabel)->\(after.stateLabel) (\(eventLabel(event)))"
    }

    static func openingTitleLog(id: String, title: String) -> String { "opening \(id): title \"\(title)\"" }
}

/// Provider brand colors: the ONE source (App/Icons.swift draws its glyphs from these too).
public enum Brand {
    public static let meetGreen: UInt32 = 0x34A853, meetYellow: UInt32 = 0xFBBC04
    public static let meetBlue: UInt32 = 0x4285F4, meetRed: UInt32 = 0xEA4335
    public static let zoom: UInt32 = 0x2D8CFF, teams: UInt32 = 0x5B5FC7
    public static let webexCyan: UInt32 = 0x07C1E4, webexGreen: UInt32 = 0x6CC04A
}

/// Provider-colored card outline (Scott 2026-10-06): a 1.3pt stroke on the card edge colored by the
/// card's CURRENT link. Meet / Webex = loop-closed conic stops, Zoom / Teams = one solid color.
/// Multi-link and no-link cards ("calendar"), a forced fixture with no link, and unknown providers: nil.
/// Readability: every stop is composited over cardFill at the per-appearance alpha and must clear
/// `floor` (CardBorderTests), except Meet yellow on light (brand-faithful, CTO ruling; >= 1.5).
public enum CardBorder {
    public static let enabled = true
    public static let width: Double = 1.3
    public static let alphaLight: Double = 0.85, alphaDark: Double = 0.75
    public static let floor: Double = 2.0
    /// Border-only adjustments (not a second brand table): Google yellow 600 for Meet on light,
    /// deepened Webex stops on light, lightened Teams on dark.
    public static let meetYellowLight: UInt32 = 0xF9AB00
    public static let webexCyanLight: UInt32 = 0x0099C2, webexGreenLight: UInt32 = 0x4FA32F
    public static let teamsDark: UInt32 = 0x7B83EB

    /// Stop hexes before alpha (loop not yet closed). nil = no outline.
    public static func hexes(provider: String?, dark: Bool) -> [UInt32]? {
        switch provider {
        case "meet": [Brand.meetGreen, dark ? Brand.meetYellow : meetYellowLight, Brand.meetBlue, Brand.meetRed]
        case "zoom": [Brand.zoom]
        case "teams": [dark ? teamsDark : Brand.teams]
        case "webex": dark ? [Brand.webexCyan, Brand.webexGreen] : [webexCyanLight, webexGreenLight]
        default: nil      // "calendar" (multi-link + no-link), nil link, unknown provider
        }
    }

    public static func colors(for link: VideoLink?, dark: Bool, enabled: Bool = CardBorder.enabled) -> [RGBA]? {
        guard enabled, let hs = hexes(provider: link?.provider, dark: dark) else { return nil }
        let a = dark ? alphaDark : alphaLight
        var cs = hs.map { RGBA(hex: $0, a) }
        if cs.count > 1 { cs.append(cs[0]) }      // conic loop closes on its first stop (no seam)
        return cs
    }

    public static func colors(for m: CardModel, dark: Bool, enabled: Bool = CardBorder.enabled) -> [RGBA]? {
        colors(for: m.link, dark: dark, enabled: enabled)
    }
}
