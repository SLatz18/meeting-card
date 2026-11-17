import Foundation

// The call coach card and its minimized pill, as plain values: copy, nudges and how long they hold,
// what each control shows, where the card goes, how it moves, and what it hides from screen
// shares. The App draws these (App/CoachCard*.swift); the tests check them here.

/// Approved copy for the coach card and pill. The nesting follows the spec's string IDs
/// (`coach.button.stop` is `Button.stop`, `coach.a11y.skipped` is `A11y.skipped`, and so on).
public enum CoachCardCopy {
    public enum Button {
        /// Replaces "Skip this call": ends the coach for the rest of this call.
        public static let stop = "Stop coach"
    }

    public enum Tooltip {
        public static let mute = "Mute your mic"
        public static let unmute = "Unmute your mic"
        public static let pause = "Pause coach"
        public static let resume = "Resume coach"
        public static let stop = "Stop coach for this call"
        public static let expand = "Expand coach"
        public static let minimize = "Minimize coach"
    }

    public enum A11y {
        public static let skipped = "Call coach is off for the rest of this call."
        public static let mute = "Mute your Zoom mic"
        public static let unmute = "Unmute your Zoom mic"
        public static let pause = "Pause call coach"
        public static let resume = "Resume call coach"
        public static let stop = "Stop call coach for the rest of this call"
        public static let expand = "Expand call coach card"
        public static let minimize = "Minimize call coach card"
    }

    public enum Captions {
        public static let empty = "Captions will show here once someone talks."
    }

    /// Why Mute can't act from the card, shown as its tooltip and accessibility help.
    public enum MuteBlock: String, CaseIterable, Equatable, Sendable {
        /// The call is in Google Meet, whose mute can't be reached.
        case meet
        /// "Use Zoom/Meet controls" is off.
        case controlsOff
        /// Zoom, but MeetingCard isn't allowed under Accessibility.
        case permission
        /// Any other call app (or none yet).
        case unsupportedApp

        public var text: String {
            switch self {
            case .meet: "Mute from the Meet window"
            case .controlsOff: "Turn on \"Use Zoom/Meet controls\" in Settings to mute here."
            case .permission: "Allow MeetingCard in Privacy & Security to mute here."
            case .unsupportedApp: "Mute from your call app's window"
            }
        }
    }
}

// MARK: nudges

/// A cue as the card shows it: words beside the coach glyph (so color is never the only cue), a
/// rose or amber tint, and a line for VoiceOver.
public struct CoachNudge: Equatable, Sendable {
    public enum Tone: Equatable, Sendable { case rose, amber }

    /// The coach's cue types (ListenMoreKit `CueType` raw values).
    public enum Kind: String, CaseIterable, Equatable, Sendable {
        case interrupt
        case talkOver = "talk_over"
        case aggressive
        case notListening = "not_listening"
        case missedQuestion = "missed_question"
        case monologue
        case talkShare = "talk_share"
    }

    public var kind: Kind
    public var tone: Tone

    public init(kind: Kind, tone: Tone) {
        self.kind = kind
        self.tone = tone
    }

    public var words: String {
        switch kind {
        case .interrupt: "Let them finish"
        case .talkOver: "You're both talking"
        case .aggressive: "Ease the tone"
        case .notListening: "Respond to their point"
        case .missedQuestion: "Answer their question"
        case .monologue: "Pause and hand over"
        case .talkShare: "Leave room for others"
        }
    }

    /// `coach.a11y.nudge.<kind>`: announced to VoiceOver when the nudge shows.
    public var announcement: String {
        switch kind {
        case .interrupt: "Call coach: you interrupted. Let them finish."
        case .talkOver: "Call coach: you're talking over someone."
        case .aggressive: "Call coach: your tone is heating up."
        case .notListening: "Call coach: respond to the point they just made."
        case .missedQuestion: "Call coach: a question went unanswered."
        case .monologue: "Call coach: you've been talking a while. Pause and hand over."
        case .talkShare: "Call coach: you're doing most of the talking."
        }
    }
}

/// The nudge on show: the latest cue, for `CardStyle.Coach.nudgeHold` after it arrived. A newer
/// cue replaces it and restarts the hold.
public struct CoachNudgeHold: Equatable, Sendable {
    public let hold: TimeInterval
    public private(set) var nudge: CoachNudge?
    public private(set) var until: TimeInterval?

    public init(hold: TimeInterval = CardStyle.Coach.nudgeHold) { self.hold = hold }

    public mutating func show(_ n: CoachNudge, now: TimeInterval) {
        nudge = n
        until = now + hold
    }

    public func active(now: TimeInterval) -> CoachNudge? {
        guard let until, now < until else { return nil }
        return nudge
    }

    /// Drops a nudge whose hold is over; true if one was dropped.
    @discardableResult
    public mutating func expire(now: TimeInterval) -> Bool {
        guard let until, now >= until else { return false }
        clear()
        return true
    }

    public mutating func clear() {
        nudge = nil
        until = nil
    }
}

/// Nudge colors as plain sRGB values (standard contrast), for contrast checks. The App tints with
/// the glow's live rose and amber (`Theme.Glow`), so Increase Contrast flows through there too.
public enum CoachNudgeColors {
    public static func tone(_ t: CoachNudge.Tone, dark: Bool) -> RGBA {
        switch t {
        case .rose: Theme.Glow.rose(dark: dark)
        case .amber: Theme.Glow.amber(dark: dark)
        }
    }

    /// The tint over the card's surface.
    public static func tint(_ t: CoachNudge.Tone, dark: Bool, increasedContrast: Bool) -> RGBA {
        let c = tone(t, dark: dark), a = CardStyle.Coach.nudgeTint(dark: dark, increasedContrast: increasedContrast)
        return RGBA(c.r, c.g, c.b, a).over(CardStyle.for(dark: dark).surface)
    }

    /// The leading bar and the outline.
    public static func edge(_ t: CoachNudge.Tone, dark: Bool, increasedContrast: Bool) -> RGBA {
        let c = tone(t, dark: dark)
        return RGBA(c.r, c.g, c.b, CardStyle.Coach.nudgeEdgeAlpha(dark: dark, increasedContrast: increasedContrast))
    }

    /// Nudge words (the primary text role) against the tint.
    public static func textContrast(_ t: CoachNudge.Tone, dark: Bool, increasedContrast: Bool) -> Double {
        let bg = tint(t, dark: dark, increasedContrast: increasedContrast)
        return RGBA.contrast(CardStyle.primaryTextSRGB(dark: dark, increasedContrast: increasedContrast).over(bg), bg)
    }

    public static func meetsContrast(_ ratio: Double) -> Bool { ratio >= CardStyle.Coach.nudgeMinContrast }
}

// MARK: controls

/// What the coach card or pill shows: the coach's status, whether Mute can act, the nudge on show,
/// and whether it's the full card or the pill.
public struct CoachCardState: Equatable, Sendable {
    public enum Status: Equatable, Sendable, CaseIterable {
        /// Coach on, no session yet (`CoachCopy.coachOn`).
        case idle
        case listening
        case paused
        /// Held while the call app reports the mic muted.
        case muted
    }

    public enum Mute: Equatable, Sendable {
        case available(muted: Bool)
        case blocked(CoachCardCopy.MuteBlock)
    }

    public enum Mode: Equatable, Sendable { case card, pill }

    public var status: Status
    public var mute: Mute
    public var nudge: CoachNudge?
    public var mode: Mode
    public var increasedContrast: Bool

    public init(status: Status, mute: Mute, nudge: CoachNudge? = nil, mode: Mode = .card, increasedContrast: Bool = false) {
        self.status = status
        self.mute = mute
        self.nudge = nudge
        self.mode = mode
        self.increasedContrast = increasedContrast
    }

    /// The coach glyph takes the live tint only while listening.
    public var live: Bool { status == .listening }
    /// Not capturing: drawn with the held text role, like the paused chip.
    public var held: Bool { status == .paused || status == .muted }
    public var tone: CoachNudge.Tone? { nudge?.tone }
}

/// One control as drawn: SF Symbol, tooltip, VoiceOver label (and help when it can't act).
public struct CoachControl: Equatable, Sendable {
    public var symbol: String
    public var tooltip: String
    public var accessibilityLabel: String
    public var accessibilityHelp: String?
    public var enabled: Bool

    public init(symbol: String, tooltip: String, accessibilityLabel: String, accessibilityHelp: String? = nil, enabled: Bool = true) {
        self.symbol = symbol
        self.tooltip = tooltip
        self.accessibilityLabel = accessibilityLabel
        self.accessibilityHelp = accessibilityHelp
        self.enabled = enabled
    }
}

public extension CoachCardState {
    var muteControl: CoachControl {
        let s = Theme.CoachCard.Symbols.self
        switch mute {
        case .available(let muted):
            return muted ? CoachControl(symbol: s.unmute, tooltip: CoachCardCopy.Tooltip.unmute, accessibilityLabel: CoachCardCopy.A11y.unmute)
                         : CoachControl(symbol: s.mute, tooltip: CoachCardCopy.Tooltip.mute, accessibilityLabel: CoachCardCopy.A11y.mute)
        case .blocked(let why):
            return CoachControl(symbol: s.mute, tooltip: why.text, accessibilityLabel: CoachCardCopy.A11y.mute,
                                accessibilityHelp: why.text, enabled: false)
        }
    }

    /// Pause while listening or muted, Resume while paused; nothing to pause before a session starts.
    var pauseControl: CoachControl {
        let s = Theme.CoachCard.Symbols.self
        switch status {
        case .paused:
            return CoachControl(symbol: s.resume, tooltip: CoachCardCopy.Tooltip.resume, accessibilityLabel: CoachCardCopy.A11y.resume)
        case .idle:
            return CoachControl(symbol: s.pause, tooltip: CoachCardCopy.Tooltip.pause, accessibilityLabel: CoachCardCopy.A11y.pause,
                                enabled: false)
        case .listening, .muted:
            return CoachControl(symbol: s.pause, tooltip: CoachCardCopy.Tooltip.pause, accessibilityLabel: CoachCardCopy.A11y.pause)
        }
    }

    var stopControl: CoachControl {
        CoachControl(symbol: Theme.CoachCard.Symbols.stop, tooltip: CoachCardCopy.Tooltip.stop, accessibilityLabel: CoachCardCopy.A11y.stop)
    }

    /// Minimize on the card, Expand on the pill.
    var sizeControl: CoachControl {
        let s = Theme.CoachCard.Symbols.self
        switch mode {
        case .card: return CoachControl(symbol: s.minimize, tooltip: CoachCardCopy.Tooltip.minimize, accessibilityLabel: CoachCardCopy.A11y.minimize)
        case .pill: return CoachControl(symbol: s.expand, tooltip: CoachCardCopy.Tooltip.expand, accessibilityLabel: CoachCardCopy.A11y.expand)
        }
    }

    /// The pill's width: wider while a nudge's words show.
    func pillWidth(wordsWidth: Double) -> Double {
        Theme.CoachPill.width(wordsWidth: nudge == nil ? nil : wordsWidth)
    }
}

// MARK: placement

/// A display as placement sees it (Cocoa coordinates, bottom-left origin).
public struct CoachDisplay: Equatable, Sendable {
    public typealias Frame = Theme.CoachCard.Frame
    public var id: Int
    public var frame: Frame
    public var visibleFrame: Frame
    /// The notch's safe-area inset (0 without a notch).
    public var safeAreaTop: Double
    /// Holds the built-in camera.
    public var builtIn: Bool

    public init(id: Int, frame: Frame, visibleFrame: Frame, safeAreaTop: Double = 0, builtIn: Bool = false) {
        self.id = id
        self.frame = frame
        self.visibleFrame = visibleFrame
        self.safeAreaTop = safeAreaTop
        self.builtIn = builtIn
    }

    public var menuBarHeight: Double { frame.maxY - visibleFrame.maxY }
}

/// A dragged card's top-center, relative to its default spot.
public struct CoachOffset: Equatable, Sendable {
    public var dx: Double, dy: Double
    public init(dx: Double, dy: Double) { self.dx = dx; self.dy = dy }
}

/// Top-center under the menu bar and notch, with room for the call app's top bar. It goes on the
/// call's display, as the coach already knows it from the glow (when that's the built-in display,
/// the card sits right under the camera); until then on the reminder card's display. Nothing here
/// reads a window.
public enum CoachPlacement {
    public static func display(call: Int?, card: Int?, displays: [CoachDisplay]) -> CoachDisplay? {
        if let call, let d = displays.first(where: { $0.id == call }) { return d }
        if let card, let d = displays.first(where: { $0.id == card }) { return d }
        return displays.first(where: \.builtIn) ?? displays.first
    }

    public static func topOffset(on d: CoachDisplay) -> Double {
        CardStyle.Coach.topOffset(screenMetric: CardStyle.Coach.screenMetric(safeAreaTop: d.safeAreaTop, menuBarHeight: d.menuBarHeight))
    }

    /// The default spot's top-center.
    public static func defaultTopCenter(on d: CoachDisplay) -> (x: Double, top: Double) {
        (d.frame.x + d.frame.width / 2, d.frame.maxY - topOffset(on: d))
    }

    /// Origin of a surface `size` big at default + `offset`, kept inside the visible frame.
    public static func origin(size: (w: Double, h: Double), on d: CoachDisplay, offset: CoachOffset? = nil) -> (x: Double, y: Double) {
        let c = defaultTopCenter(on: d)
        let o = offset ?? CoachOffset(dx: 0, dy: 0)
        return clamp(origin: (c.x + o.dx - size.w / 2, c.top + o.dy - size.h), size: size, on: d)
    }

    public static func clamp(origin: (x: Double, y: Double), size: (w: Double, h: Double), on d: CoachDisplay) -> (x: Double, y: Double) {
        let v = d.visibleFrame
        return Theme.Settings.clamp(origin: origin, size: size, visible: (v.x, v.y, v.width, v.height))
    }

    /// Where a dragged surface sits, relative to the default spot (stored for the next call).
    public static func offset(origin: (x: Double, y: Double), size: (w: Double, h: Double), on d: CoachDisplay) -> CoachOffset {
        let c = defaultTopCenter(on: d)
        return CoachOffset(dx: origin.x + size.w / 2 - c.x, dy: origin.y + size.h - c.top)
    }

    /// Card and pill share a top-center: switching keeps it and stays inside the visible frame.
    public static func resize(origin: (x: Double, y: Double), from old: (w: Double, h: Double), to new: (w: Double, h: Double),
                              on d: CoachDisplay) -> (x: Double, y: Double) {
        clamp(origin: (origin.x + old.w / 2 - new.w / 2, origin.y + old.h - new.h), size: new, on: d)
    }
}

// MARK: motion

/// How the coach surface changes, from its frame and content now to a target frame and content.
public enum CoachTransition: Equatable, Sendable, CaseIterable {
    /// The reminder card becomes the coach card, in place.
    case morph
    /// To the placement spot.
    case glide
    case collapse
    case expand
    /// The pill widening or narrowing for a nudge.
    case widen
    /// No card to morph from: the coach card shows at its spot.
    case appear
}

public struct CoachMotionStep: Equatable, Sendable {
    public var duration: TimeInterval
    /// The window frame's progress toward its target at the end of the step (0 start, 1 target).
    public var frameProgress: Double
    /// The frame animates over the step; otherwise it is set as the step starts.
    public var animatesFrame: Bool
    /// The outgoing content's and the incoming content's alpha at the end of the step.
    public var outgoingAlpha: Double
    public var incomingAlpha: Double
    /// The whole surface's alpha at the end of the step.
    public var surfaceAlpha: Double
}

public enum CoachMotion {
    /// Steps for `t`, run in order. Reduce Motion never animates a frame: the surface fades out,
    /// moves or resizes, and fades back in (the crossfade, half each way).
    public static func steps(_ t: CoachTransition, reduceMotion: Bool) -> [CoachMotionStep] {
        let m = CardStyle.Motion.self
        switch t {
        case .appear:
            return []
        case .widen:
            return reduceMotion ? [CoachMotionStep(duration: 0, frameProgress: 1, animatesFrame: false, outgoingAlpha: 0, incomingAlpha: 1, surfaceAlpha: 1)]
                                : [CoachMotionStep(duration: m.move, frameProgress: 1, animatesFrame: true, outgoingAlpha: 0, incomingAlpha: 1, surfaceAlpha: 1)]
        case .glide where reduceMotion, .morph where reduceMotion, .collapse where reduceMotion, .expand where reduceMotion:
            return [CoachMotionStep(duration: m.reduceMotionCrossfade / 2, frameProgress: 0, animatesFrame: false,
                                    outgoingAlpha: 1, incomingAlpha: 0, surfaceAlpha: 0),
                    CoachMotionStep(duration: m.reduceMotionCrossfade / 2, frameProgress: 1, animatesFrame: false,
                                    outgoingAlpha: 0, incomingAlpha: 1, surfaceAlpha: 1)]
        case .glide:
            return [CoachMotionStep(duration: m.move, frameProgress: 1, animatesFrame: true, outgoingAlpha: 0, incomingAlpha: 1, surfaceAlpha: 1)]
        case .morph, .collapse, .expand:
            let k = m.morphKeyframes, total = m.morph
            return [CoachMotionStep(duration: k[1] - k[0], frameProgress: k[1] / total, animatesFrame: true,
                                    outgoingAlpha: 0, incomingAlpha: 0, surfaceAlpha: 1),
                    CoachMotionStep(duration: k[2] - k[1], frameProgress: 1, animatesFrame: true,
                                    outgoingAlpha: 0, incomingAlpha: 1, surfaceAlpha: 1)]
        }
    }

    public static func duration(_ t: CoachTransition, reduceMotion: Bool) -> TimeInterval {
        steps(t, reduceMotion: reduceMotion).reduce(0) { $0 + $1.duration }
    }
}

// MARK: screen sharing

/// Everything the coach card draws. All of it lives in one panel that screen shares leave out.
public enum CoachSurface: CaseIterable, Equatable, Sendable {
    case card
    case pill
    /// The reminder card's image while it morphs, and the card mid-collapse or mid-expand.
    case morph
    case cardNudge
    case pillNudge

    public enum Sharing: Equatable, Sendable { case excluded, shared }

    public var sharing: Sharing { .excluded }

    public static func surface(for state: CoachCardState, transitioning: Bool) -> CoachSurface {
        if transitioning { return .morph }
        switch (state.mode, state.nudge != nil) {
        case (.card, false): return .card
        case (.card, true): return .cardNudge
        case (.pill, false): return .pill
        case (.pill, true): return .pillNudge
        }
    }
}
