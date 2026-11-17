import Foundation

/// Local, deterministic layer (port of `local_layer.py`): interrupt, talk-over, monologue, talk
/// share, prosody flags. Mic stream = the user ("me"), call stream = everyone else; attribution is by
/// stream, no diarization.
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
    public var t: Double
    /// Audio time of the underlying behaviour onset.
    public var onset: Double
    public var prosody: ProsodyFlags?
    public var share: Double?

    /// The local events that are cues by themselves.
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

public final class LocalLayer {
    let frameS: Double
    public let me: StreamVAD
    public let others: StreamVAD
    let prosody: Prosody
    let confirm: Double
    let othersMin: Double
    let talkOver: Double
    let monoS: Double
    let monoFloor: Double
    let monoGap: Double
    let shareWindow: Int
    let shareMax: Double
    let shareMin: Double

    private var shareWin: [(me: Bool, others: Bool)] = []
    private var shareHead = 0
    private var shareCounts = (me: 0, others: 0)
    private var shareArmed = true
    private var pendingInterrupt: Double?
    private var overlapSince: Double?
    private var overlapFired = false
    private var turnStart: Double?
    private var turnFired = false
    private var meLastActive = -1e9

    public init(config: ListenMoreConfig) {
        let loc = config.local
        frameS = config.frameS
        me = StreamVAD(config: config)
        others = StreamVAD(config: config)
        prosody = Prosody(config: config)
        confirm = loc.interruptConfirmMs / 1000
        othersMin = loc.interruptOthersMinActiveMs / 1000
        talkOver = loc.talkOverMs / 1000
        monoS = loc.monologueS
        monoFloor = loc.monologueOthersFloorMs / 1000
        monoGap = loc.monologueMeGapResetS
        shareWindow = max(1, Int((loc.talkShareWindowS / frameS).rounded()))
        shareMax = loc.talkShareMax
        shareMin = loc.talkShareMinSpeechS
    }

    public func step(t: Double, mic: ArraySlice<Float>, call: ArraySlice<Float>) -> (events: [LocalEvent], me: VadState, others: VadState) {
        var ev: [LocalEvent] = []
        let s = me.process(tEnd: t, frame: mic)
        let o = others.process(tEnd: t, frame: call)
        prosody.onFrame(active: s.active || s.offset != nil, db: s.dbfs)
        if let on = o.onset { ev.append(LocalEvent(kind: .othersOnset, t: t, onset: on)) }
        if let off = o.offset { ev.append(LocalEvent(kind: .othersOffset, t: t, onset: off)) }
        if let off = s.offset {
            ev.append(LocalEvent(kind: .meOffset, t: t, onset: off))
            if let p = prosody.onUtteranceEnd(t: off) {
                ev.append(LocalEvent(kind: .prosody, t: t, onset: off, prosody: p))
            }
        }

        // Interrupt: I start while others are mid-speech, and both are still talking after a grace window.
        if let on = s.onset {
            ev.append(LocalEvent(kind: .meOnset, t: t, onset: on))
            if o.active, let since = others.activeSince, on - since >= othersMin {
                pendingInterrupt = on
            }
        }
        if let pending = pendingInterrupt {
            if !(s.active && o.active) {
                pendingInterrupt = nil
            } else if t - pending >= confirm - 1e-9 {
                pendingInterrupt = nil
                // Still voicing at the end of the grace window (filters "yeah"/"mm-hm" backchannels).
                if t - me.lastSpeechT <= 0.06 {
                    ev.append(LocalEvent(kind: .interrupt, t: t, onset: pending))
                }
            }
        }
        rest(t: t, s: s, o: o, ev: &ev)
        return (ev, s, o)
    }

    public func step(t: Double, mic: [Float], call: [Float]) -> (events: [LocalEvent], me: VadState, others: VadState) {
        step(t: t, mic: mic[...], call: call[...])
    }

    private func rest(t: Double, s: VadState, o: VadState, ev: inout [LocalEvent]) {
        // Talk-over: sustained overlap > ~1 s (either side started it).
        if s.active && o.active {
            if overlapSince == nil {
                overlapSince = max(me.activeSince ?? t, others.activeSince ?? t)
                overlapFired = false
            }
            if let since = overlapSince, !overlapFired, t - since >= talkOver - 1e-9 {
                ev.append(LocalEvent(kind: .talkOver, t: t, onset: since))
                overlapFired = true
            }
        } else {
            overlapSince = nil
        }

        // Monologue fallback.
        if s.active {
            meLastActive = t
            if turnStart == nil {
                turnStart = me.activeSince ?? t
                turnFired = false
            }
        }
        if let start = turnStart {
            let othersFloor = o.active && others.activeSince.map { t - $0 >= monoFloor } == true
            if othersFloor || t - meLastActive >= monoGap {
                turnStart = nil
            } else if !turnFired && t - start >= monoS {
                ev.append(LocalEvent(kind: .monologue, t: t, onset: start + monoS))
                turnFired = true
            }
        }

        // Talk-share fallback (rolling window).
        if shareWin.count == shareWindow {
            let old = shareWin[shareHead]
            shareCounts.me -= old.me ? 1 : 0
            shareCounts.others -= old.others ? 1 : 0
            shareWin[shareHead] = (s.raw, o.raw)
            shareHead = (shareHead + 1) % shareWindow
        } else {
            shareWin.append((s.raw, o.raw))
        }
        shareCounts.me += s.raw ? 1 : 0
        shareCounts.others += o.raw ? 1 : 0
        let speechFrames = shareCounts.me + shareCounts.others
        if Double(speechFrames) * frameS >= shareMin {
            let share = Double(shareCounts.me) / Double(speechFrames)
            if shareArmed && share > shareMax {
                ev.append(LocalEvent(kind: .talkShare, t: t, onset: t, share: (share * 1000).rounded() / 1000))
                shareArmed = false
            } else if !shareArmed && share < shareMax - 0.05 {
                shareArmed = true
            }
        }
    }
}
