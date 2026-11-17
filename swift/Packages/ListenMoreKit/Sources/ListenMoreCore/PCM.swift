import Foundation

/// In-RAM audio helpers. Nothing here writes to disk.
public enum PCM {
    public static func rmsDbfs(_ x: ArraySlice<Float>) -> Double {
        guard !x.isEmpty else { return -120 }
        var acc = 0.0
        for v in x { acc += Double(v) * Double(v) }
        let r = (acc / Double(x.count)).squareRoot()
        return 20 * log10(max(r, 1e-6))
    }

    public static func rmsDbfs(_ x: [Float]) -> Double { rmsDbfs(x[...]) }

    /// Little-endian 16-bit PCM, clipped.
    public static func pcm16(_ x: ArraySlice<Float>) -> Data {
        var out = Data(count: x.count * 2)
        out.withUnsafeMutableBytes { raw in
            let p = raw.bindMemory(to: Int16.self)
            for (i, v) in x.enumerated() {
                p[i] = Int16(max(-1, min(1, v)) * 32767).littleEndian
            }
        }
        return out
    }

    public static func pcm16(_ x: [Float]) -> Data { pcm16(x[...]) }
}

/// Fixed-size Float ring buffer (RAM only), used for the transcription pre-roll.
public struct RingBuffer: Sendable {
    private var buf: [Float]
    private var pos = 0
    public private(set) var filled = 0
    public var capacity: Int { buf.count }

    public init(capacity: Int) {
        buf = [Float](repeating: 0, count: max(1, capacity))
    }

    public mutating func push(_ x: ArraySlice<Float>) {
        for v in x.suffix(buf.count) {
            buf[pos] = v
            pos = (pos + 1) % buf.count
            filled = min(buf.count, filled + 1)
        }
    }

    /// Oldest first.
    public func read() -> [Float] {
        let start = (pos - filled + buf.count) % buf.count
        return (0..<filled).map { buf[(start + $0) % buf.count] }
    }

    public mutating func clear() {
        pos = 0
        filled = 0
    }
}
