#if DEBUG || MEETINGCARD_TEST_ID
import Foundation

// The coaching-display prototype (docs/COACHING_DISPLAY.md): how the coach's cues could show on the
// coach card and pill. Test builds only: Debug (the unit tests) and `scripts/build.sh --test-id`
// (MEETINGCARD_TEST_ID). The shipping Release build compiles none of it; CI checks both binaries.
// Plain values here (pacing, conflicts, anchors, timelines); the SwiftUI side is CueDisplayViews.swift.

/// Names the prototype in the built binaries, for CI's strings check.
public enum CueDisplayPrototype {
    public static let marker = "MeetingCard cue display prototype"
}

/// The display options built in the prototype. The doc's fourth option (a short stack with decay)
/// is compared on paper only.
public enum CueDisplayOption: String, CaseIterable, Sendable, Identifiable {
    /// One line: the status line turns into the cue's words for the nudge hold, then back.
    case rotatingLine = "rotating-line"
    /// The status glyph turns into the cue's glyph in its tone and fades back over the linger;
    /// the words show on hover (card) or in the tooltip (pill).
    case glyphState = "glyph-state"
    /// The rotating line, plus a mark on the caption row that triggered the cue.
    case captionAnchored = "caption-anchored"

    public var id: String { rawValue }
}

/// What a cue asks the user to do. Two cues conflict when one says stop talking and the other says
/// talk (answer, respond).
public enum CueDirection: Equatable, Sendable {
    case yield
    case engage
    case tone

    public func conflicts(with other: CueDirection) -> Bool {
        (self == .yield && other == .engage) || (self == .engage && other == .yield)
    }
}

/// When a cue can be acted on.
public enum CueUrgency: Equatable, Sendable {
    /// Right now, mid-sentence: stop, yield.
    case now
    /// At the next turn or sentence.
    case nextTurn
    /// A trend over minutes.
    case trend
}

/// Whose caption line a cue belongs to.
public enum CueAnchorSpeaker: Equatable, Sendable {
    case you
    case them
}

public extension CoachNudge.Kind {
    /// ListenMoreCore's `cues.priority` (DefaultConfig): candidates raised together are tried in this order.
    static let priorityOrder: [CoachNudge.Kind] = [.talkOver, .interrupt, .missedQuestion, .aggressive, .monologue, .notListening, .talkShare]

    var priority: Int { Self.priorityOrder.firstIndex(of: self) ?? Self.priorityOrder.count }

    /// ListenMoreCore's `cues.colors`: red cues are rose on the card, the rest amber.
    var tone: CoachNudge.Tone {
        switch self {
        case .interrupt, .talkOver, .aggressive: .rose
        case .notListening, .missedQuestion, .monologue, .talkShare: .amber
        }
    }

    var direction: CueDirection {
        switch self {
        case .interrupt, .talkOver, .monologue, .talkShare: .yield
        case .missedQuestion, .notListening: .engage
        case .aggressive: .tone
        }
    }

    var urgency: CueUrgency {
        switch self {
        case .interrupt, .talkOver, .monologue: .now
        case .aggressive, .missedQuestion, .notListening: .nextTurn
        case .talkShare: .trend
        }
    }

    /// Can the user act on it without finishing their sentence first.
    var actionableMidSentence: Bool {
        switch self {
        case .interrupt, .talkOver, .monologue: true
        case .aggressive, .missedQuestion, .notListening, .talkShare: false
        }
    }

    /// How long after the behavior's onset the cue still makes sense. A cue held back by the
    /// display gate past this is dropped, not shown late. From the rules' own windows: a cut-in or
    /// talk-over is over a few seconds after it fires (~1.2 s latency plus the 4.5 s hold); heat
    /// scores a 15 s window; a missed question escalates after 20 s of the user's reply; monologue
    /// strong follows soft by 30 s; talk share is a 10 min trend.
    var shelfLife: TimeInterval {
        switch self {
        case .interrupt, .talkOver: 6
        case .notListening: 10
        case .aggressive: 15
        case .missedQuestion: 20
        case .monologue: 30
        case .talkShare: 60
        }
    }

    /// The caption line a cue is about: the line cut into, the question left unanswered, or the
    /// user's own line. Talk share is about the whole call: no line.
    var anchor: CueAnchorSpeaker? {
        switch self {
        case .interrupt, .missedQuestion: .them
        case .talkOver, .aggressive, .notListening, .monologue: .you
        case .talkShare: nil
        }
    }
}

// MARK: tokens

public extension Theme {
    /// The prototype's look, derived from the coach card's tokens.
    enum CueDisplay {
        /// One SF Symbol per cue type for the glyph-state option and the caption marks. Never a mic
        /// (Mute in Zoom's), a waveform (the coach's hearing state) or an ear (the coach itself).
        public static func glyph(_ kind: CoachNudge.Kind) -> String {
            switch kind {
            case .interrupt: "hand.raised.fill"
            case .talkOver: "bubble.left.and.bubble.right.fill"
            case .aggressive: "thermometer.medium"
            case .notListening: "arrowshape.turn.up.left.fill"
            case .missedQuestion: "questionmark.bubble.fill"
            case .monologue: "timer"
            case .talkShare: "chart.pie.fill"
            }
        }

        /// Behind the snapshots and the lab's preview, so the card's edge shows.
        public static func backdrop(style: CardStyle) -> RGBA { style.controlFill(.normal).over(style.surface) }
        /// Around a surface in a snapshot.
        public static let snapshotPadding = CardStyle.Spacing.stack
        /// Between the frames of a snapshot strip, and from a frame to its time label.
        public static let stripGap = CardStyle.Spacing.stack
        public static let stripLabelFont = CardStyle.Typography.caption
        public static let stripLabelText = CardStyle.Text.secondary
        /// The glyph-state detail's age, and the pill's hover tooltip.
        public static let ageFont = CardStyle.Typography.caption
        public static let ageText = CardStyle.Text.secondary
        public static let tooltipFont = CardStyle.Typography.caption
        public static let tooltipRadius = CardStyle.Radius.control
        public static let tooltipPadding = CardStyle.Spacing.control
        /// A cue's glyph after its hold, while it lingers: the held text role, no tone.
        public static let lingerText = Theme.Coach.heldText
        /// A caption row's mark: the nudge tint behind the row, and the cue's glyph at the caption
        /// size in the gutter left of it (the card's leading inset, less the chip's control inset).
        public static let markGlyphSize = CardStyle.Typography.caption.size
        public static let markRadius = Theme.Coach.pauseButtonRadius
        public static let markGutter = CardStyle.Spacing.leading - Theme.Coach.controlInset
    }
}

// MARK: timelines

/// A cue as the session showed it.
public struct CueEvent: Equatable, Sendable {
    public enum Level: String, Equatable, Sendable { case soft, strong }

    /// Timeline seconds the session showed it.
    public var t: TimeInterval
    /// When the behavior that caused it started.
    public var onset: TimeInterval
    public var kind: CoachNudge.Kind
    public var level: Level?

    public init(t: TimeInterval, onset: TimeInterval, kind: CoachNudge.Kind, level: Level? = nil) {
        self.t = t
        self.onset = onset
        self.kind = kind
        self.level = level
    }

    public var nudge: CoachNudge { CoachNudge(kind: kind, tone: kind.tone) }
}

/// One caption line: who spoke, when, and what. Shown word by word while it's spoken, like the
/// live captions' partials.
public struct CueCaptionLine: Equatable, Sendable {
    public var own: Bool
    public var start: TimeInterval
    public var end: TimeInterval
    public var text: String

    public init(own: Bool, start: TimeInterval, end: TimeInterval, text: String) {
        self.own = own
        self.start = start
        self.end = end
        self.text = text
    }

    public func text(at t: TimeInterval) -> String? {
        guard t >= start else { return nil }
        guard t < end else { return text }
        let words = text.split(separator: " ")
        let n = Int((Double(words.count) * (t - start) / max(end - start, .ulpOfOne)).rounded(.up))
        return words.prefix(max(1, n)).joined(separator: " ")
    }
}

/// A recorded or synthetic call: its caption lines and the cues the session showed.
public struct CueTimeline: Equatable, Sendable, Identifiable {
    public enum Origin: Equatable, Sendable {
        /// ListenMoreHarness, offline: the real pipeline on synthetic voices. `paced`: the shipped
        /// cue policy; otherwise its cooldowns set to 0, to see what the rules raise before pacing.
        case harness(paced: Bool)
        case synthetic
    }

    public var id: String
    public var title: String
    public var origin: Origin
    public var duration: TimeInterval
    public var captions: [CueCaptionLine]
    public var events: [CueEvent]
    /// Moments worth a snapshot.
    public var moments: [TimeInterval]

    public init(id: String, title: String, origin: Origin, duration: TimeInterval, captions: [CueCaptionLine],
                events: [CueEvent], moments: [TimeInterval]) {
        self.id = id
        self.title = title
        self.origin = origin
        self.duration = duration
        self.captions = captions
        self.events = events.sorted { $0.t < $1.t }
        self.moments = moments
    }

    /// The caption rows the card shows at `t`: the newest `rows` lines that have started.
    public func visibleCaptions(at t: TimeInterval, rows: Int = Theme.Captions.cardRows) -> [(index: Int, line: CueCaptionLine, text: String)] {
        let started = captions.enumerated().compactMap { i, l in l.text(at: t).map { (index: i, line: l, text: $0) } }
        return Array(started.suffix(rows))
    }
}

// MARK: pacing

public enum CueDisplayPacing {
    /// N: at most one new cue appears per this many seconds, on any option. At least twice the
    /// nudge hold, so every cue gets its whole hold and the card then rests in its normal state at
    /// least as long, and two cues never read as one blinking element. At most the cue policy's
    /// `cues.global_cooldown_s` (20 s), so with the shipped config this gate never holds back a
    /// cue the policy let through: pacing stays the engine's (harness-tested) job, and the gate
    /// only acts when a config or a judge provider lets cues through faster. 10 s is about 26
    /// spoken words (TextRules' 2.6 words/s): one new instruction per couple of sentences at most.
    public static let minNewCueGap: TimeInterval = 10
    /// How long a cue's words show (the shipped nudge hold).
    public static let hold = CardStyle.Coach.nudgeHold
    /// How long the glyph-state option keeps the cue's glyph (full for the hold, then fading),
    /// and the caption-anchored option its row mark: the policy's per-type cooldown, so a mark is
    /// gone before the same cue can come back.
    public static let linger: TimeInterval = 20
}

/// A cue on the card, from when it showed.
public struct ShownCue: Equatable, Sendable {
    public var event: CueEvent
    public var shownAt: TimeInterval

    public var kind: CoachNudge.Kind { event.kind }
    public var nudge: CoachNudge { event.nudge }

    public func age(at t: TimeInterval) -> TimeInterval { max(0, t - shownAt) }
}

/// What the display did with a cue (the lab's log, and the tests).
public enum CueDecision: Equatable, Sendable {
    /// Shown, `waited` seconds after the session showed it.
    case shown(CoachNudge.Kind, at: TimeInterval, waited: TimeInterval)
    /// Arrived inside the gap; waits for it to open.
    case deferred(CoachNudge.Kind, at: TimeInterval)
    /// A waiting cue lost its place to a newer one: one that conflicts with it, or outranks it.
    case replaced(CoachNudge.Kind, by: CoachNudge.Kind, at: TimeInterval)
    /// Its moment passed before the gap opened: dropped, never shown late.
    case stale(CoachNudge.Kind, at: TimeInterval)
    /// A shown cue still lingering, cleared by a newer one that asks the opposite.
    case superseded(CoachNudge.Kind, by: CoachNudge.Kind, at: TimeInterval)
}

/// What the card shows at one moment.
public struct CueDisplayFrame: Equatable, Sendable {
    public var t: TimeInterval
    /// The cue whose words show (within its hold).
    public var line: ShownCue?
    /// The cue whose glyph and row mark show (within the linger).
    public var lingering: ShownCue?
    /// The linger's strength: 1 through the hold, then down to 0 at the end of the linger.
    public var strength: Double
    /// A cue held back by the gap, waiting.
    public var pending: CueEvent?
    public var decisions: [CueDecision]

    public var words: String? { line?.nudge.words }
}

/// Replays the session's cues up to a moment, through one gate for every option: at most one new
/// cue per `minNewCueGap`. A cue inside the gap waits (one deep). While one waits, a newer cue
/// that asks the opposite replaces it (the conversation moved on), otherwise the higher priority
/// keeps the place. When the gap opens the waiting cue shows, unless its shelf life has passed.
public enum CueDisplayPacer {
    public static func frame(at t: TimeInterval, events: [CueEvent], gap: TimeInterval = CueDisplayPacing.minNewCueGap,
                             hold: TimeInterval = CueDisplayPacing.hold, linger: TimeInterval = CueDisplayPacing.linger) -> CueDisplayFrame {
        var decisions: [CueDecision] = []
        var current: ShownCue?
        var lastShown: TimeInterval?
        var pending: CueEvent?

        func show(_ e: CueEvent, at x: TimeInterval) {
            if let c = current, x - c.shownAt < linger, c.kind.direction.conflicts(with: e.kind.direction) {
                decisions.append(.superseded(c.kind, by: e.kind, at: x))
            }
            current = ShownCue(event: e, shownAt: x)
            lastShown = x
            decisions.append(.shown(e.kind, at: x, waited: x - e.t))
        }
        func openGate(until x: TimeInterval) {
            guard let p = pending, let last = lastShown, last + gap <= x else { return }
            pending = nil
            let open = last + gap
            if open - p.onset > p.kind.shelfLife {
                decisions.append(.stale(p.kind, at: open))
            } else {
                show(p, at: open)
            }
        }

        for e in events.sorted(by: { $0.t < $1.t }) where e.t <= t {
            openGate(until: e.t)
            if lastShown.map({ e.t - $0 >= gap }) ?? true {
                show(e, at: e.t)
            } else if let p = pending {
                let keepNew = p.kind.direction.conflicts(with: e.kind.direction) || e.kind.priority <= p.kind.priority
                let (winner, loser) = keepNew ? (e, p) : (p, e)
                decisions.append(.replaced(loser.kind, by: winner.kind, at: e.t))
                pending = winner
            } else {
                pending = e
                decisions.append(.deferred(e.kind, at: e.t))
            }
        }
        openGate(until: t)

        let age = current.map { t - $0.shownAt } ?? .infinity
        let strength = age < hold ? 1 : max(0, 1 - (age - hold) / max(linger - hold, .ulpOfOne))
        return CueDisplayFrame(t: t, line: age < hold ? current : nil, lingering: age < linger ? current : nil,
                               strength: age < linger ? strength : 0, pending: pending, decisions: decisions)
    }

    /// The caption row (an index into `timeline.visibleCaptions(at:)`) the lingering cue marks in
    /// the caption-anchored option: the latest line of the cue's speaker that had started by the
    /// cue's onset, while that line is still on the card.
    public static func anchorRow(_ frame: CueDisplayFrame, in timeline: CueTimeline) -> Int? {
        guard let cue = frame.lingering, let speaker = cue.kind.anchor else { return nil }
        let own = speaker == .you
        guard let line = timeline.captions.indices.last(where: {
            timeline.captions[$0].own == own && timeline.captions[$0].start <= cue.event.onset + anchorSlack
        }) else { return nil }
        return timeline.visibleCaptions(at: frame.t).firstIndex { $0.index == line }
    }

    /// A line that starts this soon after the onset still counts as the one that triggered the cue
    /// (VAD onsets lead the caption's start slightly).
    public static let anchorSlack: TimeInterval = 0.5
}

// MARK: copy

/// The prototype's new strings. PLACEHOLDER copy, not approved: final user-facing strings come from
/// the writer (each is listed in the PR). The cue words and VoiceOver announcements themselves are
/// the shipped, approved `CoachNudge.words` and `CoachNudge.announcement`.
public enum CueDisplayCopy {
    /// True until a writer replaces the strings below.
    public static let isPlaceholder = true

    /// The status line while listening, and the caption speaker labels: the App's approved
    /// `CoachCopy.coachListening`, `captionsYou` and `captionsThem` (tests keep them equal).
    public static let statusListening = "Coach on, listening"
    public static let you = "You"
    public static let them = "Them"

    /// The glyph-state option's detail (hover on the card, the pill's tooltip): how long ago.
    public static let justNow = "Just now"
    public static func secondsAgo(_ s: Int) -> String { "\(s) s ago" }
    public static func age(_ seconds: TimeInterval) -> String {
        seconds < CueDisplayPacing.hold ? justNow : secondsAgo(Int(seconds.rounded(.down)))
    }

    /// VoiceOver: the glyph-state status line while a cue lingers.
    public static func glyphLabel(status: String, words: String, age: String) -> String { "\(status). Last cue: \(words), \(age)." }
    /// VoiceOver: a caption row with a cue mark.
    public static func anchoredRowLabel(speaker: String, text: String, words: String) -> String { "Cue: \(words). \(speaker): \(text)" }

    /// The test build's lab window.
    public enum Lab {
        public static let title = "Cue Display Prototype (test build)"
        public static let menuItem = "Cue Display Prototype…"
        public static let option = "Option"
        public static let timeline = "Timeline"
        public static let surface = "Surface"
        public static let card = "Card"
        public static let pill = "Pill"
        public static let hover = "Show hover detail"
        public static let appearance = "Appearance"
        public static let system = "System"
        public static let light = "Light"
        public static let dark = "Dark"
        public static let play = "Play"
        public static let pause = "Pause"
        public static let restart = "Restart"
        public static let speed = "Speed"
        public static let log = "What the display did"
        public static let note = "Placeholder copy. Synthetic and harness timelines only: no call, no audio, nothing saved."
        public static func gap(_ n: TimeInterval) -> String { "At most one new cue every \(Int(n)) s" }

        public static func name(_ o: CueDisplayOption) -> String {
            switch o {
            case .rotatingLine: "Rotating line"
            case .glyphState: "Glyph state"
            case .captionAnchored: "Caption-anchored"
            }
        }

        public static func describe(_ d: CueDecision) -> String {
            func n(_ k: CoachNudge.Kind) -> String { k.rawValue }
            func s(_ t: TimeInterval) -> String { String(format: "%.1f s", t) }
            switch d {
            case let .shown(k, at, waited): return waited > 0 ? "\(s(at)) shown \(n(k)) (waited \(s(waited)))" : "\(s(at)) shown \(n(k))"
            case let .deferred(k, at): return "\(s(at)) held \(n(k)) for the gap"
            case let .replaced(k, by, at): return "\(s(at)) \(n(by)) replaced waiting \(n(k))"
            case let .stale(k, at): return "\(s(at)) dropped \(n(k)): too late to act on"
            case let .superseded(k, by, at): return "\(s(at)) \(n(by)) cleared \(n(k)) (opposite advice)"
            }
        }
    }
}
#endif
