import Foundation

/// In-RAM audio helpers, ported from `listen_more/audio.py`. Arithmetic mirrors numpy (Double
/// intermediates, Float32 storage) so frames classify the same way in both cores. Nothing touches disk.
public enum AudioMath {
    /// `rms_dbfs`: Double accumulation, floor at 1e-6 (-120 dBFS); empty input is -120.
    public static func rmsDbfs(_ x: ArraySlice<Float>) -> Double {
        guard !x.isEmpty else { return -120 }
        var acc = 0.0
        for v in x {
            let d = Double(v)
            acc += d * d
        }
        let r = (acc / Double(x.count)).squareRoot()
        return 20 * log10(max(r, 1e-6))
    }

    public static func rmsDbfs(_ x: [Float]) -> Double {
        rmsDbfs(x[...])
    }

    /// `resample`: linear interpolation on the sample grid, like `np.interp(arange(n_out) * src/dst, arange(n), x)`.
    public static func resample(_ x: ArraySlice<Float>, from src: Int, to dst: Int) -> [Float] {
        guard src != dst, !x.isEmpty else { return Array(x) }
        let n = x.count
        let nOut = Int((Double(n) * Double(dst) / Double(src)).rounded(.toNearestOrEven))
        let step = Double(src) / Double(dst)
        let base = x.startIndex
        var out = [Float](repeating: 0, count: nOut)
        for i in 0..<nOut {
            let t = Double(i) * step
            if t >= Double(n - 1) {
                out[i] = x[base + n - 1]
                continue
            }
            let j = Int(t)
            let y0 = Double(x[base + j])
            if t == Double(j) {
                out[i] = Float(y0)
            } else {
                let slope = Double(x[base + j + 1]) - y0
                out[i] = Float(slope * (t - Double(j)) + y0)
            }
        }
        return out
    }

    /// `to_pcm16`: clip to [-1, 1], scale by 32767 in Float32, truncate toward zero.
    public static func pcm16(_ x: ArraySlice<Float>) -> [Int16] {
        x.map { v in
            let c = min(max(v, -1), 1)
            return Int16(c * 32767)
        }
    }

    /// Little-endian PCM16 bytes, the realtime transcription input format.
    public static func pcm16Data(_ x: ArraySlice<Float>) -> Data {
        var data = Data(capacity: x.count * 2)
        for s in pcm16(x) {
            var le = s.littleEndian
            withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
        }
        return data
    }
}

/// Fixed-size Float32 ring buffer (RAM only), ported from `audio.RingBuffer`.
public struct RingBuffer {
    public let capacity: Int
    private var buf: [Float]
    private var pos = 0
    public private(set) var filled = 0

    public init(capacity: Int) {
        self.capacity = max(0, capacity)
        buf = [Float](repeating: 0, count: self.capacity)
    }

    public mutating func push(_ x: ArraySlice<Float>) {
        guard capacity > 0, !x.isEmpty else { return }
        let tail = x.suffix(capacity)
        for v in tail {
            buf[pos] = v
            pos = (pos + 1) % capacity
        }
        filled = min(capacity, filled + tail.count)
    }

    /// Oldest first.
    public func read() -> [Float] {
        guard filled > 0 else { return [] }
        let start = (pos - filled + capacity) % capacity
        return (0..<filled).map { buf[(start + $0) % capacity] }
    }

    public mutating func clear() {
        pos = 0
        filled = 0
        for i in buf.indices { buf[i] = 0 }
    }
}
