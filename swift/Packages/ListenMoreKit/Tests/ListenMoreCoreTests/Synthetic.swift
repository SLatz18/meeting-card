import Foundation
@testable import ListenMoreCore

/// Generated test audio. No recordings and no TTS: a voiced, syllable-modulated harmonic signal,
/// the same construction as the Python reference tests' `speechish` (24 harmonics at 1/k amplitude,
/// 4 Hz envelope, 0.2 peak). Phases come from a fixed LCG instead of numpy's RNG.
enum Synthetic {
    static let sr = 24000

    static func speechish(_ dur: Double, seed: Int = 0, f0: Double = 130) -> [Float] {
        let n = Int(dur * Double(sr))
        var state = UInt64(seed &+ 1) &* 6364136223846793005 &+ 1442695040888963407
        func uniform() -> Double {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Double(state >> 11) / Double(1 << 53)
        }
        // Rotating phasors per harmonic: one complex multiply per sample instead of a sin() call.
        var re: [Double] = [], im: [Double] = [], wr: [Double] = [], wi: [Double] = []
        for k in 1...24 {
            let ph = uniform() * 6
            re.append(cos(ph)); im.append(sin(ph))
            let w = 2 * Double.pi * f0 * Double(k) / Double(sr)
            wr.append(cos(w)); wi.append(sin(w))
        }
        var x = [Double](repeating: 0, count: n)
        var peak = 0.0
        for i in 0..<n {
            var s = 0.0
            for k in 0..<24 {
                s += im[k] / Double(k + 1)
                let r = re[k] * wr[k] - im[k] * wi[k]
                im[k] = re[k] * wi[k] + im[k] * wr[k]
                re[k] = r
            }
            x[i] = s
            peak = max(peak, abs(s))
        }
        return (0..<n).map { i in
            let t = Double(i) / Double(sr)
            let env = 0.5 + 0.5 * sin(2 * Double.pi * 4 * t)
            return Float(0.2 * x[i] * env / peak)
        }
    }

    static func track(_ total: Double, _ spans: [(Double, Double)], f0: Double) -> [Float] {
        var x = [Float](repeating: 0, count: Int(total * Double(sr)))
        for (i, (a, b)) in spans.enumerated() {
            let seg = speechish(b - a, seed: i, f0: f0)
            let start = Int(a * Double(sr))
            for j in 0..<seg.count where start + j < x.count { x[start + j] = seg[j] }
        }
        return x
    }

    /// Deterministic white noise at roughly `dbfs` RMS.
    static func noise(_ dur: Double, dbfs: Double, seed: UInt64 = 7) -> [Float] {
        var state = seed
        let amp = pow(10, dbfs / 20) * 3.0.squareRoot()
        return (0..<Int(dur * Double(sr))).map { _ in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return Float((Double(state >> 11) / Double(1 << 53) * 2 - 1) * amp)
        }
    }

    /// Runs the local layer frame by frame like the Python `run_local` helper; returns cue events.
    static func runLocal(_ config: ListenMoreConfig, mic: [Float], call: [Float]) -> [LocalEvent] {
        let ll = LocalLayer(config: config)
        let hop = config.frameSamples
        var out: [LocalEvent] = []
        for i in 0..<(min(mic.count, call.count) / hop) {
            let r = ll.step(t: Double(i + 1) * config.frameS, mic: mic[(i * hop)..<((i + 1) * hop)],
                            call: call[(i * hop)..<((i + 1) * hop)])
            out += r.events.filter { $0.cueType != nil }
        }
        return out
    }
}

enum TestConfig {
    static func load() throws -> ListenMoreConfig { try ListenMoreConfig.builtIn() }
}
