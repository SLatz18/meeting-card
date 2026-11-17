import Foundation

/// What the pipeline needs from a GPT layer each frame. `LocalCoachEngine` adapts the async
/// `GptLayer`; a harness can drive `GptCore` on a simulated clock.
public protocol PipelineGpt: AnyObject {
    func onLocal(_ event: LocalEvent)
    func feed(me: [Float], meVad: VadState, others: [Float], othersVad: VadState, meRunS: Double)
    /// Transcripts and verdicts that landed since the last frame, oldest first.
    func drain(now: TimeInterval) -> [GptOutput]
}

public enum GptOutput: Equatable, Sendable {
    /// A transcript (RAM only), with the reference time and the audio time it arrived.
    case segment(Speaker, String, refT: TimeInterval, now: TimeInterval)
    case offer(label: String, t: TimeInterval, refT: TimeInterval, confidence: Double)
}

/// One frame of the engine, in the order of the Python engine's loop (`engine.run_streams`): local
/// layer, GPT feed, landed transcripts and verdicts, transcript rules, cut-in checks, then the cue
/// policy (one cue at a time, priority order, global and per-type cooldowns, quiet after a closing
/// phrase). Synchronous and single-owner. The transcript rules run only with a GPT layer.
public final class CoachPipeline {
    public enum CutInVerdict: Equatable { case fire, drop, wait }

    public let local: LocalLayer
    public let text: TextRules?
    public let policy: CuePolicy
    public let gpt: PipelineGpt?
    private let frameS: Double
    private let cutWait: Double
    private var cutIns: [LocalEvent] = []
    private var inbox: [CueSuggestion] = []

    public init(config: ListenMoreConfig, gpt: PipelineGpt?, participants: Int = 2, meetingOffsetS: Double = 0) {
        let text = gpt == nil ? nil : TextRules(config: config, participants: participants, meetingOffsetS: meetingOffsetS)
        self.text = text
        local = LocalLayer(config: config, participants: participants, context: text)
        policy = CuePolicy(config: config.cues)
        self.gpt = gpt
        frameS = config.frameS
        cutWait = config.local.cutInTextWaitMs / 1000
    }

    /// One aligned frame ending at audio time `t`. Returns the cues the policy let through.
    public func process(t: TimeInterval, mic: ArraySlice<Float>, call: ArraySlice<Float>) -> [Cue] {
        let r = local.step(t: t, mic: mic, call: call)
        var cands: [CueSuggestion] = []
        for ev in r.events {
            gpt?.onLocal(ev)
            text?.onLocal(ev)
            if ev.kind == .interrupt {
                cutIns.append(ev)
            } else if [.talkOver, .monologue, .talkShare].contains(ev.kind), let type = ev.cueType {
                cands.append(CueSuggestion(type: type, t: ev.t, onset: ev.onset, source: .local, level: ev.level))
            }
        }
        if let gpt {
            gpt.feed(me: Array(mic), meVad: r.me, others: Array(call), othersVad: r.others, meRunS: local.meRunS(at: t))
            for out in gpt.drain(now: t) {
                switch out {
                case let .segment(speaker, said, refT, now):
                    if let text { inbox += text.onSegment(speaker, text: said, refT: refT, now: now) }
                case let .offer(label, ct, refT, confidence):
                    if let type = CueType(gptLabel: label) {
                        inbox.append(CueSuggestion(type: type, t: ct, onset: refT, source: .gpt, confidence: confidence))
                    }
                }
            }
        }
        if let text { cands += text.onTick(now: t, userActive: r.me.active, frameS: frameS) }
        cands += inbox
        inbox.removeAll()
        var waiting: [LocalEvent] = []
        for ev in cutIns {
            switch Self.cutInVerdict(ev, t: t, text: text, waitS: cutWait) {
            case .fire: cands.append(CueSuggestion(type: .interrupt, t: t, onset: ev.onset, source: .local))
            case .wait: waiting.append(ev)
            case .drop: break
            }
        }
        cutIns = waiting
        guard !cands.isEmpty else { return [] }
        let quiet = text?.closingActive(now: t) ?? false
        let cues = policy.offerMany(cands, quiet: quiet)
        for cue in cues { text?.shown(cue.type) }
        return cues
    }

    /// Port of `cut_in_verdict`: drop a cut-in that answers a question; wait briefly for the other side's
    /// last words to be transcribed when they had already stopped. A trailing cut-in counts only when
    /// their last words were unfinished; without a transcript it is dropped.
    public static func cutInVerdict(_ ev: LocalEvent, t: TimeInterval, text: TextRules?, waitS: Double) -> CutInVerdict {
        if ev.trailing {
            guard let text, !text.questionNear(ev.onset) else { return .drop }
            guard let unfinished = text.trailingUnfinished(ev.othersLastSpeech ?? ev.onset) else {
                return t - ev.t >= waitS ? .drop : .wait
            }
            return unfinished ? .fire : .drop
        }
        guard let text else { return .fire }
        if text.questionNear(ev.onset) { return .drop }
        if ev.othersActive == true || text.othersTextSince((ev.othersLastSpeech ?? ev.onset) - 0.1) { return .fire }
        return t - ev.t >= waitS ? .fire : .wait
    }

    /// Drops transcript state (RAM only) at the end of a session.
    public func clear() {
        text?.clear()
        cutIns.removeAll()
        inbox.removeAll()
    }
}
