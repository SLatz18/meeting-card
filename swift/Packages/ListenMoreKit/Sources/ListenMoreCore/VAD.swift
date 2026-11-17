import Foundation

public struct VadState: Equatable, Sendable {
    public var raw: Bool
    public var active: Bool
    /// Set on the frame where activity is confirmed (back-dated to the first speech frame).
    public var onset: Double?
    /// Set on the frame where activity is released (time of last speech).
    public var offset: Double?
    public var dbfs: Double = -120
}

/// Per-stream voice activity detection: energy gate + voicing detector + onset/hangover smoothing.
///
/// The Python reference uses WebRTC VAD for the per-frame speech decision. That library is not
/// available to Swift without vendoring C, so the per-frame decision here is an energy gate plus a
/// periodicity (voicing) check: the normalized autocorrelation peak over the pitch range of a
/// 40 ms window decimated to ~8 kHz. Everything after the per-frame decision (onset window,
/// back-dated onset, hangover) is a line-for-line port. Voiced speech passes; broadband noise does
/// not. Thresholds are in config (`vad`) and still need tuning against real speech on a Mac.
public final class StreamVAD {
    let rate: Int
    let frameS: Double
    let onsetFrames: Int
    let window: Int
    let hangFrames: Int
    let minDb: Double
    let voicingThreshold: Double
    let decimation: Int
    let minLag: Int
    let maxLag: Int

    private var recent: [(t: Double, raw: Bool)] = []
    public private(set) var active = false
    private var silentRun = 0
    public private(set) var lastSpeechT = 0.0
    public private(set) var activeSince: Double?
    /// Previous frame, decimated: the voicing window spans the previous and current frame.
    private var prevDecimated: [Float] = []

    public init(config: ListenMoreConfig) {
        let v = config.vad
        rate = config.audio.sampleRate
        frameS = config.frameS
        onsetFrames = v.onsetFrames
        window = v.onsetWindow
        hangFrames = max(1, Int((Double(v.hangoverMs) / Double(config.audio.frameMs)).rounded()))
        minDb = v.minRmsDbfs
        voicingThreshold = v.voicingThreshold
        decimation = max(1, rate / 8000)
        let dRate = Double(rate) / Double(decimation)
        minLag = max(2, Int(dRate / v.voicingMaxHz))
        maxLag = Int(dRate / v.voicingMinHz)
    }

    public func process(tEnd: Double, frame: ArraySlice<Float>) -> VadState {
        let tStart = tEnd - frameS
        let db = PCM.rmsDbfs(frame)
        let dec = decimate(frame)
        let raw = db >= minDb && isVoiced(prevDecimated + dec)
        prevDecimated = dec
        recent.append((tStart, raw))
        if recent.count > window { recent.removeFirst(recent.count - window) }
        var st = VadState(raw: raw, active: active, dbfs: db)
        if raw {
            lastSpeechT = tEnd
            silentRun = 0
        } else {
            silentRun += 1
        }
        if !active {
            if recent.filter(\.raw).count >= onsetFrames, let first = recent.first(where: \.raw) {
                active = true
                activeSince = first.t
                st.onset = first.t
            }
        } else if silentRun >= hangFrames {
            active = false
            activeSince = nil
            st.offset = lastSpeechT
            recent.removeAll()
        }
        st.active = active
        return st
    }

    public func process(tEnd: Double, frame: [Float]) -> VadState { process(tEnd: tEnd, frame: frame[...]) }

    /// Box-filter decimation to ~8 kHz (crude low-pass; good enough for a pitch-range periodicity check).
    func decimate(_ x: ArraySlice<Float>) -> [Float] {
        guard decimation > 1 else { return Array(x) }
        let n = x.count / decimation
        var out = [Float](repeating: 0, count: n)
        Array(x).withUnsafeBufferPointer { p in
            for i in 0..<n {
                var s: Float = 0
                for j in 0..<decimation { s += p[i * decimation + j] }
                out[i] = s / Float(decimation)
            }
        }
        return out
    }

    /// Max normalized autocorrelation over the pitch lag range.
    func isVoiced(_ y: [Float]) -> Bool {
        let n = y.count
        guard n > maxLag + 8 else { return false }
        let mean = y.reduce(0, +) / Float(n)
        var best: Float = 0
        y.withUnsafeBufferPointer { raw in
            var z = [Float](repeating: 0, count: n)
            var prefix = [Float](repeating: 0, count: n + 1)
            for i in 0..<n {
                z[i] = raw[i] - mean
                prefix[i + 1] = prefix[i] + z[i] * z[i]
            }
            z.withUnsafeBufferPointer { p in
                for lag in minLag...min(maxLag, n - 8) {
                    var acc: Float = 0
                    let m = n - lag
                    for i in 0..<m { acc += p[i] * p[i + lag] }
                    let e0 = prefix[m], e1 = prefix[n] - prefix[lag]
                    let den = (e0 * e1).squareRoot()
                    if den > 0 { best = max(best, acc / den) }
                }
            }
        }
        return Double(best) >= voicingThreshold
    }
}
