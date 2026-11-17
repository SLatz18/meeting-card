import Foundation

/// Port of `listen_more/prosody.py`: loudness + speech-rate jump vs the user's own earlier baseline in the
/// same call. Only numbers are kept in RAM; no audio is retained.
public struct ProsodyReading: Equatable, Sendable {
    public var t: TimeInterval
    public var baselineReady: Bool
    public var flagged: Bool
    public var loudnessJumpDb: Double
    public var rateJumpPct: Double
}

public enum ProsodyMath {
    /// Syllable-like peaks per voiced second in the frame dB envelope (`peak_rate`).
    public static func peakRate(_ db: [Double], frameS: Double, prominenceDb: Double = 3, minGapFrames: Int = 5) -> Double {
        guard db.count >= 5 else { return 0 }
        let n = db.count
        // np.convolve(x, ones(3)/3, mode="same"), zero padded at both ends.
        let third = 1.0 / 3.0
        var x = [Double](repeating: 0, count: n)
        for i in 0..<n {
            let a = i > 0 ? db[i - 1] : 0
            let b = db[i]
            let c = i + 1 < n ? db[i + 1] : 0
            x[i] = a * third + b * third + c * third
        }
        var peaks = 0
        var last = -minGapFrames
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

    /// numpy median (mean of the two middle values for even counts).
    public static func median(_ v: [Double]) -> Double {
        let s = v.sorted()
        let n = s.count
        guard n > 0 else { return .nan }
        return n % 2 == 1 ? s[n / 2] : (s[n / 2 - 1] + s[n / 2]) / 2
    }

    /// Python `round(x, 1)` for the reported jumps.
    static func round1(_ x: Double) -> Double {
        (x * 10).rounded(.toNearestOrEven) / 10
    }
}

public final class Prosody {
    private let frameS: Double
    private let baseMin: Double
    private let baseMax: Double
    private let jumpDb: Double
    private let jumpPct: Double
    private var baseDb: [Double] = []
    private var baseRates: [(rate: Double, seconds: Double)] = []
    public private(set) var baseline: (db: Double, rate: Double)?
    private var cur: [Double] = []

    public init(config: ListenMoreConfig) {
        let l = config.local
        frameS = Double(config.audio.frameMs) / 1000
        baseMin = l.prosodyBaselineMinS
        baseMax = l.prosodyBaselineMaxS
        jumpDb = l.prosodyLoudnessJumpDb
        jumpPct = l.prosodyRateJumpPct
    }

    public func onFrame(active: Bool, raw: Bool, db: Double) {
        if active { cur.append(db) }
    }

    public func onUtteranceEnd(t: TimeInterval) -> ProsodyReading? {
        let frames = cur
        cur = []
        let dur = Double(frames.count) * frameS
        guard dur >= 0.8 else { return nil }
        let voiced = frames.filter { $0 > -45 }
        guard !voiced.isEmpty else { return nil }
        let loud = ProsodyMath.median(voiced)
        let rate = ProsodyMath.peakRate(frames, frameS: frameS)
        guard let b = baseline else {
            baseDb += voiced
            baseRates.append((rate, dur))
            let total = baseRates.reduce(0) { $0 + $1.seconds }
            if total >= baseMin {
                let bRate = baseRates.reduce(0) { $0 + $1.rate * $1.seconds } / total
                baseline = (ProsodyMath.median(baseDb), bRate)
            }
            return ProsodyReading(t: t, baselineReady: baseline != nil, flagged: false, loudnessJumpDb: 0, rateJumpPct: 0)
        }
        let lJump = loud - b.db
        let rJump = b.rate > 0 ? 100 * (rate - b.rate) / b.rate : 0
        let flagged = lJump >= jumpDb || rJump >= jumpPct
        return ProsodyReading(t: t, baselineReady: true, flagged: flagged,
                              loudnessJumpDb: ProsodyMath.round1(lJump), rateJumpPct: ProsodyMath.round1(rJump))
    }
}
