import Foundation

/// Port of `listen_more/local_layer.py`: cut-in, talk-over, monologue, talk share and prosody flags.
/// mic = me, call = everyone else (attribution by stream, no diarization). An optional transcript
/// context answers what the audio can't: a how/why question before a long run, a round-robin handoff,
/// or a number read-back during fast switches. Without it those checks are skipped.
public struct LocalEvent: Equatable, Sendable {
    public enum Kind: String, Equatable, Sendable {
        case interrupt
        case talkOver = "talk_over"
        case monologue
        case talkShare = "talk_share"
        case prosody
        case meOnset = "me_onset"
        case meOffset = "me_offset"
        case othersOnset = "others_onset"
        case othersOffset = "others_offset"
    }

    public var kind: Kind
    /// Audio time the event was raised (end of the frame that triggered it).
    public var t: TimeInterval
    /// Audio time of the underlying behaviour onset.
    public var onset: TimeInterval
    public var share: Double?
    public var prosody: ProsodyReading?
    /// Monologue: soft or strong.
    public var level: CueLevel?
    /// Cut-in: the other side was still active when it was raised, when they last spoke, and whether
    /// it is a trailing candidate (a short overlap that needs their last words to be unfinished).
    public var othersActive: Bool?
    public var othersLastSpeech: TimeInterval?
    public var trailing = false
    /// Talk-over: speaker switches in the episode.
    public var switches: Int?

    public init(kind: Kind, t: TimeInterval, onset: TimeInterval, share: Double? = nil, prosody: ProsodyReading? = nil,
                level: CueLevel? = nil, othersActive: Bool? = nil, othersLastSpeech: TimeInterval? = nil,
                trailing: Bool = false, switches: Int? = nil) {
        self.kind = kind
        self.t = t
        self.onset = onset
        self.share = share
        self.prosody = prosody
        self.level = level
        self.othersActive = othersActive
        self.othersLastSpeech = othersLastSpeech
        self.trailing = trailing
        self.switches = switches
    }

    public var cueType: CueType? {
        switch kind {
        case .interrupt: return .interrupt
        case .talkOver: return .talkOver
        case .monologue: return .monologue
        case .talkShare: return .talkShare
        case .prosody, .meOnset, .meOffset, .othersOnset, .othersOffset: return nil
        }
    }
}

/// Transcript questions the local layer asks (`TextRules` answers them).
public protocol LocalTextContext: AnyObject {
    /// The other side asked how/why just before `t`.
    func howWhyBefore(_ t: TimeInterval) -> Bool
    /// The user's turn starting at `t` is an update slot in a round of updates.
    func updateTurnBefore(_ t: TimeInterval) -> Bool
    /// The fast switches since `t0` are a number read-back, not a fight for the floor.
    func readback(from t0: TimeInterval, now: TimeInterval) -> Bool
}

public final class LocalLayer {
    /// "Speaking" = raw speech within this window (VAD hangover excluded from overlap).
    static let speakingTailS = 0.06
    /// The other side must keep talking through a cut-in's opening overlap, bar VAD flicker this short.
    static let overlapGapS = 0.1
    /// After the mic comes back on, an onset of the user's this soon neither opens a cut-in nor counts
    /// as a speaker switch: the host's echo canceller restarts with the mic and can let call audio
    /// through while it settles, which would read as the user talking over the other side.
    static let unmuteGraceS = 1.0

    struct CutIn {
        var onset: TimeInterval
        var overlap = 0.0
        var gap = 0.0
        var othersAfter = 0.0
        var trailing = false
        var othersEnd = 0.0
    }

    enum Who { case me, others }

    public let me: StreamVAD
    public let others: StreamVAD
    public let prosody: Prosody
    public weak var context: LocalTextContext?
    private let frameS: Double
    private let prosodyEnabled: Bool
    private let cutOverlap, cutContinue, cutBackchannel, cutPause, cutMidPause, cutAfterTalkOver: Double
    private let cutTrailingOverlap, cutTrailingWindow, cutTrailingYield: Double
    private let toSwitches: Int
    private let toWindow, toOverlap, toHold: Double
    private let monoSoft, monoStrong, relFactor, relMinS, relMinRunS, howWhyRaise, monoFloor, monoGap: Double
    private let relMinRuns: Int
    private let shareWindow: Int
    private var shareFrames: [(Bool, Bool)] = []
    private var shareHead = 0
    private var shareCount = (me: 0, others: 0)
    private let shareMax, shareMin: Double
    private var shareArmed = true
    private var cut: CutIn?
    private var lastOnsetWho: Who?
    private var switchLog: [(t: TimeInterval, who: Who)] = []
    private var overlapFrames: [TimeInterval] = []
    private var toDoneAt = -1e9
    private var toFiredAt = -1e9
    private var turnStart: TimeInterval?
    private var turnLevel: CueLevel?
    private var turnRaise: Double?
    private var turnExempt: Bool?
    private var runs: [Double] = []
    private var meLastActive = -1e9
    private var othersSoloSince: TimeInterval?
    /// The user's mic is off (`setMicMuted`): their side reads as silence.
    public private(set) var micMuted = false
    private var unmutePending = false
    private var unmuteGraceUntil: TimeInterval?

    /// `participants`: people on the call (2 = a 1:1), for the talk-share limit.
    public init(config: ListenMoreConfig, participants: Int = 2, context: LocalTextContext? = nil) {
        let l = config.local
        frameS = Double(config.audio.frameMs) / 1000
        me = StreamVAD(config: config)
        others = StreamVAD(config: config)
        prosody = Prosody(config: config)
        self.context = context
        prosodyEnabled = l.prosodyEnabled
        cutOverlap = l.cutInMinOverlapMs / 1000
        cutContinue = l.cutInOthersContinueMs / 1000
        cutBackchannel = l.cutInBackchannelMaxMs / 1000
        cutPause = l.cutInUtteranceGapMs / 1000
        cutMidPause = l.cutInOthersPauseMs / 1000
        cutAfterTalkOver = l.cutInAfterTalkOverS
        cutTrailingOverlap = l.cutInTrailingMinOverlapMs / 1000
        cutTrailingWindow = l.cutInTrailingWindowS
        cutTrailingYield = l.cutInTrailingYieldS
        toSwitches = l.talkOverSwitches
        toWindow = l.talkOverWindowS
        toOverlap = l.talkOverMinOverlapMs / 1000
        toHold = l.talkOverHoldFloorMs / 1000
        monoSoft = l.monologueSoftS
        monoStrong = l.monologueStrongS
        relFactor = l.monologueRelativeFactor
        relMinS = l.monologueRelativeMinS
        relMinRuns = l.monologueRelativeMinRuns
        relMinRunS = l.monologueRelativeMinRunS
        howWhyRaise = l.monologueHowWhyRaise
        monoFloor = l.monologueOthersFloorMs / 1000
        monoGap = l.monologueMeGapResetS
        shareWindow = max(1, Int((l.talkShareWindowS / frameS).rounded(.toNearestOrEven)))
        shareMax = participants <= 2 ? l.talkShareMaxOneOnOne : l.talkShareMaxGroup
        shareMin = l.talkShareMinSpeechS
    }

    /// Length of the user's current run (0 when they do not hold the floor).
    public func meRunS(at t: TimeInterval) -> Double {
        turnStart.map { t - $0 } ?? 0
    }

    private func speaking(_ vad: StreamVAD, _ t: TimeInterval) -> Bool {
        vad.active && t - vad.lastSpeechT <= Self.speakingTailS
    }

    /// The user's mic went off (true) or came back. Either way the user's utterance and turn in
    /// progress are dropped unread (no offset, no prosody reading, no monologue run recorded), a
    /// pending cut-in is dropped and the talk-over switch log starts over, so nothing measured across
    /// the gap can fire. While off, the user's VAD isn't run: they read as silent, which is what the
    /// call heard, so talk share keeps counting the other side and the gap can only lower the user's
    /// share. Back on, the first `unmuteGraceS` seconds open no cut-in and log no switch.
    public func setMicMuted(_ muted: Bool) {
        guard muted != micMuted else { return }
        micMuted = muted
        me.reset()
        prosody.dropUtterance()
        cut = nil
        switchLog.removeAll()
        overlapFrames.removeAll()
        lastOnsetWho = nil
        turnStart = nil
        turnLevel = nil
        turnRaise = nil
        turnExempt = nil
        othersSoloSince = nil
        unmutePending = !muted
        unmuteGraceUntil = nil
    }

    public func step(t: TimeInterval, mic: ArraySlice<Float>, call: ArraySlice<Float>) -> (events: [LocalEvent], me: VadState, others: VadState) {
        var ev: [LocalEvent] = []
        if unmutePending {
            unmutePending = false
            unmuteGraceUntil = t + Self.unmuteGraceS
        }
        let s = micMuted ? VadState(raw: false, active: false, onset: nil, offset: nil, dbfs: AudioMath.rmsDbfs(mic))
                         : me.process(tEnd: t, frame: mic)
        let o = others.process(tEnd: t, frame: call)
        if prosodyEnabled {
            prosody.onFrame(active: s.active || s.offset != nil, raw: s.raw, db: s.dbfs)
        }
        if let on = o.onset {
            ev.append(LocalEvent(kind: .othersOnset, t: t, onset: on))
            onset(on, .others)
        }
        if let off = o.offset { ev.append(LocalEvent(kind: .othersOffset, t: t, onset: off)) }
        if let off = s.offset {
            ev.append(LocalEvent(kind: .meOffset, t: t, onset: off))
            if prosodyEnabled, let p = prosody.onUtteranceEnd(t: off) {
                ev.append(LocalEvent(kind: .prosody, t: t, onset: off, prosody: p))
            }
        }
        if let on = s.onset {
            ev.append(LocalEvent(kind: .meOnset, t: t, onset: on))
            let settling = unmuteGraceUntil.map { on < $0 } ?? false
            if !settling { onset(on, .me) }
            let midSpeech = o.active || on - others.lastSpeechT <= cutMidPause
            let afterTalkOver = on - toFiredAt < cutAfterTalkOver
            if midSpeech && cut == nil && !afterTalkOver && !settling {
                cut = CutIn(onset: on)
            }
        }
        let both = speaking(me, t) && speaking(others, t)
        if both { overlapFrames.append(t) }
        cutIn(t, s, &ev, both)
        talkOver(t, &ev)
        monologue(t, s, o, &ev)
        talkShare(t, s, o, &ev)
        return (ev, s, o)
    }

    private func onset(_ t: TimeInterval, _ who: Who) {
        if let last = lastOnsetWho, last != who { switchLog.append((t, who)) }
        lastOnsetWho = who
    }

    // Cut-in: the user starts while others talk (or inside a pause in their speech shorter than
    // cut_in_others_pause_ms), the overlap from their onset lasts >= cut_in_min_overlap_ms, they keep going
    // >= cut_in_others_continue_ms, and the user's utterance runs past the backchannel length. A shorter
    // overlap that ends with them stopping within cut_in_trailing_window_s of the start is a trailing
    // candidate: it needs them to leave the floor for cut_in_trailing_yield_s, and the engine fires it only
    // if their last words were unfinished.
    private func cutIn(_ t: TimeInterval, _ s: VadState, _ ev: inout [LocalEvent], _ both: Bool) {
        guard var c = cut else { return }
        let othersSpeaking = speaking(others, t)
        if c.overlap < cutOverlap && !c.trailing {
            if othersSpeaking {
                c.gap = 0
                c.overlap += both ? frameS : 0
            } else {
                c.gap += frameS
                if c.gap > Self.overlapGapS {
                    let end = others.lastSpeechT
                    if c.overlap >= cutTrailingOverlap && abs(end - c.onset) <= cutTrailingWindow {
                        c.trailing = true
                        c.othersEnd = end
                    } else {
                        cut = nil
                        return
                    }
                }
            }
        }
        if c.trailing && othersSpeaking {
            cut = nil
            return
        }
        if othersSpeaking && t > c.onset { c.othersAfter += frameS }
        cut = c
        if !s.active {
            if t - me.lastSpeechT > cutPause { cut = nil }
            return
        }
        if c.trailing && t - c.onset >= max(cutBackchannel, cutTrailingYield) {
            ev.append(LocalEvent(kind: .interrupt, t: t, onset: c.onset, othersActive: false, othersLastSpeech: c.othersEnd,
                                 trailing: true))
            cut = nil
        } else if c.overlap >= cutOverlap && c.othersAfter >= cutContinue && t - c.onset >= cutBackchannel {
            ev.append(LocalEvent(kind: .interrupt, t: t, onset: c.onset, othersActive: others.active,
                                 othersLastSpeech: others.lastSpeechT))
            cut = nil
        }
    }

    // Talk-over: >= talk_over_switches speaker switches inside talk_over_window_s, some true overlap, and
    // the user ends up holding the floor.
    private func talkOver(_ t: TimeInterval, _ ev: inout [LocalEvent]) {
        let horizon = toWindow + toHold + 2
        while let first = switchLog.first, t - first.t > horizon { switchLog.removeFirst() }
        while let first = overlapFrames.first, t - first > horizon { overlapFrames.removeFirst() }
        guard switchLog.count >= toSwitches else { return }
        let last = switchLog[switchLog.count - 1]
        let firstT = switchLog[switchLog.count - toSwitches].t
        guard last.who == .me, last.t > toDoneAt, last.t - firstT <= toWindow else { return }
        let holding = speaking(me, t) && t - others.lastSpeechT >= toHold && t - last.t >= toHold
        guard holding else { return }
        let overlap = Double(overlapFrames.filter { firstT - 0.5 <= $0 && $0 <= t }.count) * frameS
        toDoneAt = last.t
        guard overlap >= toOverlap else { return }
        if let context, context.readback(from: firstT, now: t) { return }
        ev.append(LocalEvent(kind: .talkOver, t: t, onset: last.t, switches: switchLog.filter { $0.t >= firstT }.count))
        toFiredAt = t
        cut = nil
    }

    // Monologue: soft at monologue_soft_s, strong at monologue_strong_s; soft earlier when the run passes
    // relative_factor x the user's rolling median run (and relative_min_s); both raised right after the
    // other side asked how/why; none during the user's update turn in a round of updates.
    private func thresholds() -> (soft: Double, strong: Double) {
        var soft = monoSoft
        let done = runs.filter { $0 >= relMinRunS }
        if done.count >= relMinRuns {
            soft = min(soft, max(relFactor * ProsodyMath.median(done), relMinS))
        }
        if turnRaise == nil, let context, let start = turnStart {
            turnRaise = context.howWhyBefore(start) ? howWhyRaise : 1
        }
        let r = turnRaise ?? 1
        return (soft * r, monoStrong * r)
    }

    private func monologue(_ t: TimeInterval, _ s: VadState, _ o: VadState, _ ev: inout [LocalEvent]) {
        if s.active {
            meLastActive = t
            if turnStart == nil {
                turnStart = me.activeSince ?? t
                turnLevel = nil
                turnRaise = nil
                turnExempt = nil
            }
        }
        if o.active && !s.active {
            if othersSoloSince == nil { othersSoloSince = t }
        } else {
            othersSoloSince = nil
        }
        guard let start = turnStart else { return }
        let othersFloor = othersSoloSince.map { t - $0 >= monoFloor } ?? false
        if othersFloor || t - meLastActive >= monoGap {
            runs.append(meLastActive - start)
            if runs.count > 200 { runs.removeFirst(runs.count - 200) }
            turnStart = nil
            return
        }
        let run = t - start
        if run < min(relMinS, monoSoft) { return }
        if turnExempt == nil, let context { turnExempt = context.updateTurnBefore(start) }
        if turnExempt == true { return }
        let (soft, strong) = thresholds()
        if turnLevel == nil && run >= soft {
            turnLevel = .soft
            ev.append(LocalEvent(kind: .monologue, t: t, onset: start + soft, level: .soft))
        } else if turnLevel == .soft && run >= strong {
            turnLevel = .strong
            ev.append(LocalEvent(kind: .monologue, t: t, onset: start + strong, level: .strong))
        }
    }

    // Talk share over a rolling window (talk_share_max_group with 3+ people, talk_share_max_one_on_one in a 1:1).
    private func talkShare(_ t: TimeInterval, _ s: VadState, _ o: VadState, _ ev: inout [LocalEvent]) {
        if shareFrames.count == shareWindow {
            let old = shareFrames[shareHead]
            shareCount.me -= old.0 ? 1 : 0
            shareCount.others -= old.1 ? 1 : 0
            shareFrames[shareHead] = (s.raw, o.raw)
            shareHead = (shareHead + 1) % shareWindow
        } else {
            shareFrames.append((s.raw, o.raw))
        }
        shareCount.me += s.raw ? 1 : 0
        shareCount.others += o.raw ? 1 : 0
        let total = Double(shareCount.me + shareCount.others) * frameS
        if total >= shareMin {
            let share = Double(shareCount.me) / Double(shareCount.me + shareCount.others)
            if shareArmed && share > shareMax {
                ev.append(LocalEvent(kind: .talkShare, t: t, onset: t, share: (share * 1000).rounded(.toNearestOrEven) / 1000))
                shareArmed = false
            } else if !shareArmed && share < shareMax - 0.05 {
                shareArmed = true
            }
        }
    }
}
