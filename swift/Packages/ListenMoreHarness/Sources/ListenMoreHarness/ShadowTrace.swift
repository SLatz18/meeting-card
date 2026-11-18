import Foundation
import ListenMoreCore

/// The run's own audio replayed through `LocalLayer` after the fact, with the same Mutes and Pauses
/// (a new layer at each Resume, as the engine gets): what the local rules saw frame by frame. It
/// explains a missed or false local cue without guessing: if the shadow raises a cue the session
/// didn't show, the loss is in the engine or session; if it doesn't, the audio didn't meet the rule.
public struct ShadowTrace: Sendable {
    public struct Frame: Sendable {
        public var t: Double
        public var meRaw: Bool
        public var meActive: Bool
        public var othersRaw: Bool
        public var othersActive: Bool
    }

    public struct Event: Sendable {
        public var kind: LocalEvent.Kind
        public var t: Double
        public var onset: Double
    }

    public var frames: [Frame] = []
    public var events: [Event] = []

    static func record(config: ListenMoreConfig, tracks: Tracks, applied: [(kind: ControlKind, t: Double)]) -> ShadowTrace {
        var trace = ShadowTrace()
        let hop = config.frameSamples
        var layer: LocalLayer? = LocalLayer(config: config)
        var controls = applied
        var callOn = true
        for k in 0..<(tracks.mic.count / hop) {
            let tStart = Double(k) * config.frameS
            while let c = controls.first, c.t <= tStart + 1e-9 {
                controls.removeFirst()
                switch c.kind {
                case .mute: layer?.setMicMuted(true)
                case .unmute: layer?.setMicMuted(false)
                case .pause, .stopCoach: layer = nil
                case .resume: layer = LocalLayer(config: config)
                case .callEnds: callOn = false
                case .renameThem, .deleteTranscript: break
                }
            }
            guard let l = layer else { continue }
            let t = tStart + config.frameS
            let range = (k * hop)..<((k + 1) * hop)
            let call = callOn ? tracks.call[range] : ArraySlice([Float](repeating: 0, count: hop))
            let r = l.step(t: t, mic: tracks.mic[range], call: call)
            trace.frames.append(Frame(t: t, meRaw: r.me.raw, meActive: r.me.active, othersRaw: r.others.raw, othersActive: r.others.active))
            for e in r.events where e.kind != .prosody { trace.events.append(Event(kind: e.kind, t: e.t, onset: e.onset)) }
        }
        return trace
    }

    /// Why a cut-in did or didn't happen around one You line: the shadow's interrupts, You's onsets,
    /// whether Them were talking at each, and Them's longest raw-speech gap in the 0.6 s after it.
    public func explainCutIn(around window: ClosedRange<Double>, config: ListenMoreConfig) -> String {
        let span = (window.lowerBound - 3)...(window.upperBound + 1)
        let raised = events.filter { $0.kind == .interrupt && span.contains($0.t) }.map { String(format: "%.2f", $0.t) }
        let onsets = events.filter { $0.kind == .meOnset && span.contains($0.onset) }.map(\.onset)
        let overlapS = config.local.cutInMinOverlapMs / 1000
        let notes = onsets.prefix(4).map { on -> String in
            let at = frames.first { $0.t >= on }
            let window = frames.filter { $0.t > on && $0.t <= on + overlapS }
            var gap = 0.0, longest = 0.0
            for f in window {
                gap = f.othersRaw ? 0 : gap + config.frameS
                longest = max(longest, gap)
            }
            return String(format: "You onset %.2f: Them %@, longest Them gap in the next %.1f s %.2f s", on,
                          at?.othersActive == true ? "talking" : "not talking", overlapS, longest)
        }
        let head = raised.isEmpty ? "shadow local layer: no interrupt" : "shadow local layer: interrupt at \(raised.joined(separator: ", ")) s"
        return ([head] + notes).joined(separator: "; ")
    }
}
