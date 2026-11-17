import Foundation

/// Loudness + speech-rate jump vs the user's own earlier baseline in the same call (port of
/// `prosody.py`). Rate proxy = syllable-like peaks per voiced second in the 20 ms frame-level dB
/// envelope. Only numbers are kept (in RAM); no audio is retained.
public struct ProsodyFlags: Equatable, Sendable {
    public var t: Double
    public var baselineReady: Bool
    public var flagged: Bool
    public var loudnessJumpDb: Double
    public var rateJumpPct: Double
}

public final class Prosody {
    let frameS: Double
    let baseMin: Double
    let jumpDb: Double
    let jumpPct: Double
    private var baseDb: [Double] = []
    private var baseRates: [(rate: Double, seconds: Double)] = []
    public private(set) var baseline: (db: Double, rate: Double)?
    private var cur: [Double] = []

    public init(config: ListenMoreConfig) {
        frameS = config.frameS
        baseMin = config.local.prosodyBaselineMinS
        jumpDb = config.local.prosodyLoudnessJumpDb
        jumpPct = config.local.prosodyRateJumpPct
    }

    public static func peakRate(_ db: [Double], frameS: Double, prominenceDb: Double = 3, minGapFrames: Int = 5) -> Double {
        guard db.count >= 5 else { return 0 }
        let n = db.count
        // np.convolve(db, ones(3)/3, mode="same"): zero-padded 3-tap mean.
        let x: [Double] = (0..<n).map { i in
            let prev: Double = i > 0 ? db[i - 1] : 0
            let next: Double = i < n - 1 ? db[i + 1] : 0
            return (prev + db[i] + next) / 3
        }
        var peaks = 0, last = -minGapFrames
        for i in 1..<(n - 1) where x[i] >= x[i - 1] && x[i] > x[i + 1] && i - last >= minGapFrames {
            let left = x[max(0, i - 6)..<i].min() ?? x[i]
            let right = x[(i + 1)..<min(n, i + 7)].min() ?? x[i]
            if x[i] - min(left, right) >= prominenceDb {
                peaks += 1
                last = i
            }
        }
        return Double(peaks) / (Double(n) * frameS)
    }

    static func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        let n = s.count
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    public func onFrame(active: Bool, db: Double) {
        if active { cur.append(db) }
    }

    public func onUtteranceEnd(t: Double) -> ProsodyFlags? {
        let frames = cur
        cur = []
        let dur = Double(frames.count) * frameS
        guard dur >= 0.8 else { return nil }
        let voiced = frames.filter { $0 > -45 }
        guard !voiced.isEmpty else { return nil }
        let loud = Self.median(voiced)
        let rate = Self.peakRate(frames, frameS: frameS)
        guard let (bDb, bRate) = baseline else {
            baseDb += voiced
            baseRates.append((rate, dur))
            let total = baseRates.reduce(0) { $0 + $1.seconds }
            if total >= baseMin {
                let bRate = baseRates.reduce(0) { $0 + $1.rate * $1.seconds } / total
                baseline = (Self.median(baseDb), bRate)
            }
            return ProsodyFlags(t: t, baselineReady: baseline != nil, flagged: false, loudnessJumpDb: 0, rateJumpPct: 0)
        }
        let lJump = loud - bDb
        let rJump = bRate > 0 ? 100 * (rate - bRate) / bRate : 0
        return ProsodyFlags(t: t, baselineReady: true, flagged: lJump >= jumpDb || rJump >= jumpPct,
                            loudnessJumpDb: (lJump * 10).rounded() / 10, rateJumpPct: (rJump * 10).rounded() / 10)
    }
}
