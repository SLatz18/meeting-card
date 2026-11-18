import Foundation
import ListenMoreCore

/// Offline audio: a voiced, syllable-modulated harmonic signal generated at run time (the Kit's
/// `Synthetic.speechish` construction: harmonics at 1/k amplitude, a 4 Hz envelope, 0.2 peak). Each
/// voice has its own pitch. No recordings and no TTS; nothing is written anywhere.
public enum SyntheticVoice {
    public static func f0(_ voice: Voice) -> Double {
        switch voice {
        case .you: return 125
        case .themA: return 210
        case .themB: return 160
        }
    }

    static let harmonics = 16

    public static func speech(seconds: Double, seed: Int, f0: Double, sampleRate: Int) -> [Float] {
        let n = max(0, Int(seconds * Double(sampleRate)))
        guard n > 0 else { return [] }
        var state = UInt64(truncatingIfNeeded: seed &+ 1) &* 6364136223846793005 &+ 1442695040888963407
        func uniform() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(UInt64(1) << 53)
        }
        var re: [Double] = [], im: [Double] = [], wr: [Double] = [], wi: [Double] = []
        for k in 1...harmonics {
            let ph = uniform() * 6
            re.append(cos(ph)); im.append(sin(ph))
            let w = 2 * Double.pi * f0 * Double(k) / Double(sampleRate)
            wr.append(cos(w)); wi.append(sin(w))
        }
        var x = [Double](repeating: 0, count: n)
        var peak = 1e-9
        for i in 0..<n {
            var s = 0.0
            for k in 0..<harmonics {
                s += im[k] / Double(k + 1)
                let r = re[k] * wr[k] - im[k] * wi[k]
                im[k] = re[k] * wi[k] + im[k] * wr[k]
                re[k] = r
            }
            x[i] = s
            peak = max(peak, abs(s))
        }
        let sr = Double(sampleRate)
        return (0..<n).map { i in
            let env = 0.5 + 0.5 * sin(2 * Double.pi * 4 * Double(i) / sr)
            return Float(0.2 * x[i] * env / peak)
        }
    }

    /// Offline shapes: no leading silence, voiced for the line's synthetic length.
    public static func shapes(_ scenario: Scenario) -> [String: ClipShape] {
        Dictionary(uniqueKeysWithValues: scenario.lines.map {
            ($0.id, ClipShape(lead: 0, voiced: $0.syntheticSeconds, total: $0.syntheticSeconds))
        })
    }

    public static func clips(_ scenario: Scenario, sampleRate: Int) -> [String: [Float]] {
        var out: [String: [Float]] = [:]
        for (i, line) in scenario.lines.enumerated() {
            out[line.id] = speech(seconds: line.syntheticSeconds, seed: i, f0: f0(line.voice), sampleRate: sampleRate)
        }
        return out
    }
}

/// The two device streams for one run, sample-aligned on the scenario clock.
public struct Tracks: Sendable {
    public var mic: [Float]
    public var call: [Float]
    public let sampleRate: Int

    public init(timeline: Timeline, clips: [String: [Float]], sampleRate: Int) {
        self.sampleRate = sampleRate
        let n = Int((timeline.duration * Double(sampleRate)).rounded(.up))
        mic = [Float](repeating: 0, count: n)
        call = [Float](repeating: 0, count: n)
        for p in timeline.lines {
            guard let clip = clips[p.line.id] else { continue }
            let start = Int((p.clipStart * Double(sampleRate)).rounded())
            switch p.line.voice.stream {
            case .mic: Self.mix(clip, into: &mic, at: start)
            case .call: Self.mix(clip, into: &call, at: start)
            }
        }
    }

    static func mix(_ clip: [Float], into track: inout [Float], at start: Int) {
        guard start < track.count else { return }
        for j in 0..<min(clip.count, track.count - start) { track[start + j] += clip[j] }
    }

    /// Voiced on `stream` at scenario time `t` (RMS over 20 ms above -45 dBFS).
    public func voiced(_ stream: AudioStream, at t: Double) -> Bool {
        let x = stream == .mic ? mic : call
        let hop = sampleRate / 50
        let i = Int(t * Double(sampleRate))
        guard i >= 0, i + hop <= x.count else { return false }
        return AudioMath.rmsDbfs(x[i..<(i + hop)]) > -45
    }
}

/// Leading silence and voiced length of a clip (a TTS clip has silence around the speech).
public enum ClipMeasure {
    public static func shape(_ clip: [Float], sampleRate: Int, thresholdDbfs: Double = -45) -> ClipShape {
        let hop = max(1, sampleRate / 100)
        var first: Int?
        var last: Int?
        var i = 0
        while i + hop <= clip.count {
            if AudioMath.rmsDbfs(clip[i..<(i + hop)]) > thresholdDbfs {
                if first == nil { first = i }
                last = i + hop
            }
            i += hop
        }
        let total = Double(clip.count) / Double(sampleRate)
        guard let f = first, let l = last else { return ClipShape(lead: 0, voiced: 0, total: total) }
        return ClipShape(lead: Double(f) / Double(sampleRate), voiced: Double(l - f) / Double(sampleRate), total: total)
    }
}
