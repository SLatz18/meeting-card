import Foundation

public protocol SpeakerEmbedder: Sendable {
    func embed(_ samples: [Float], sampleRate: Int) -> SpeakerEmbedding?
}

public struct SpeakerEmbedding: Codable, Equatable, Sendable {
    public let model: String
    public let values: [Float]

    public init?(model: String, values: [Float]) {
        guard let unit = Self.unit(values), !model.isEmpty else { return nil }
        self.model = model
        self.values = unit
    }

    private static func unit(_ values: [Float]) -> [Float]? {
        let norm = sqrt(values.reduce(0) { $0 + Double($1) * Double($1) })
        guard norm.isFinite, norm > 1e-8 else { return nil }
        return values.map { Float(Double($0) / norm) }
    }

    public func similarity(to other: SpeakerEmbedding) -> Float? {
        guard model == other.model, values.count == other.values.count,
              let a = Self.unit(values), let b = Self.unit(other.values) else { return nil }
        return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
    }

    var clusterThreshold: Float { model == MFCCSpeakerEmbedder.model ? 0.88 : 0.65 }
    var profileThreshold: Float { model == MFCCSpeakerEmbedder.model ? 0.95 : 0.78 }
}

public struct SpeakerClusters: Sendable {
    private struct Cluster: Sendable {
        var centroid: SpeakerEmbedding
        var count: Int
    }

    private var clusters: [Cluster] = []
    private let threshold: Float?
    private let limit: Int

    public init(threshold: Float? = nil, limit: Int = 32) {
        self.threshold = threshold
        self.limit = limit
    }

    public mutating func assign(_ embedding: SpeakerEmbedding) -> (number: Int, centroid: SpeakerEmbedding)? {
        let best = clusters.enumerated().compactMap { index, cluster in
            cluster.centroid.similarity(to: embedding).map { (index, $0) }
        }.max { $0.1 < $1.1 }
        if let (i, score) = best, score >= (threshold ?? embedding.clusterThreshold) {
            let weight = Float(clusters[i].count)
            let values = zip(clusters[i].centroid.values, embedding.values).map { $0 * weight + $1 }
            clusters[i].centroid = SpeakerEmbedding(model: embedding.model, values: values) ?? embedding
            clusters[i].count = min(clusters[i].count + 1, 30)
            return (i + 1, clusters[i].centroid)
        }
        guard clusters.count < limit else { return nil }
        clusters.append(Cluster(centroid: embedding, count: 1))
        return (clusters.count, embedding)
    }
}

/// A low-cost fallback: pooled mean and spread of 13 mel cepstra, omitting the energy term.
public struct MFCCSpeakerEmbedder: SpeakerEmbedder {
    static let model = "mfcc-v1"
    private static let rate = 16_000
    private static let size = 400
    private static let fft = 512
    private static let bands = 26
    private static let cepstra = 13
    private static let window = (0..<size).map { 0.54 - 0.46 * cos(2 * .pi * Double($0) / Double(size - 1)) }
    private static let melBins: [Double] = (0...bands + 1).map {
        let hi = log1p(7600.0 / 700)
        let lo = log1p(80.0 / 700)
        return 700 * expm1(lo + (hi - lo) * Double($0) / Double(bands + 1)) * Double(fft) / Double(rate)
    }
    private static let dct: [[Double]] = (1...cepstra).map { k in
        (0..<bands).map { cos(.pi * Double(k) * (Double($0) + 0.5) / Double(bands)) }
    }

    public init() {}

    public func embed(_ samples: [Float], sampleRate: Int) -> SpeakerEmbedding? {
        guard sampleRate > 0 else { return nil }
        let pcm = AudioMath.resample(samples.prefix(sampleRate * 8), from: sampleRate, to: Self.rate)
        guard pcm.count >= Self.rate / 2 else { return nil }
        var means = [Double](repeating: 0, count: Self.cepstra)
        var squares = means
        var frames = 0
        for start in stride(from: 0, through: pcm.count - Self.size, by: 320) {
            let frame = pcm[start..<start + Self.size]
            guard AudioMath.rmsDbfs(frame) > -60 else { continue }
            let power = Self.spectrum(frame)
            let mel = (0..<Self.bands).map { i -> Double in
                let l = Self.melBins[i], c = Self.melBins[i + 1], r = Self.melBins[i + 2]
                var energy = 0.0
                for bin in Int(ceil(l))...Int(r) {
                    let b = Double(bin)
                    energy += power[bin] * min((b - l) / (c - l), (r - b) / (r - c))
                }
                return log(max(1e-10, energy))
            }
            for i in means.indices {
                let c = zip(mel, Self.dct[i]).reduce(0.0) { $0 + $1.0 * $1.1 }
                means[i] += c
                squares[i] += c * c
            }
            frames += 1
        }
        guard frames >= 8 else { return nil }
        let n = Double(frames)
        let avg = means.map { $0 / n }
        let spread = zip(avg, squares).map { sqrt(max(0, $1 / n - $0 * $0)) }
        return SpeakerEmbedding(model: Self.model, values: (avg + spread).map(Float.init))
    }

    private static func spectrum(_ frame: ArraySlice<Float>) -> [Double] {
        var re = [Double](repeating: 0, count: fft)
        var im = re
        var j = 0
        for i in 0..<fft {
            if i < size {
                let s = Double(frame[frame.startIndex + i])
                let prev = i == 0 ? s : Double(frame[frame.startIndex + i - 1])
                re[j] = (s - 0.97 * prev) * window[i]
            }
            var bit = fft >> 1
            while bit > 0 && j & bit != 0 { j ^= bit; bit >>= 1 }
            j ^= bit
        }
        var width = 2
        while width <= fft {
            for k in 0..<(width / 2) {
                let angle = -2 * Double.pi * Double(k) / Double(width)
                let a = cos(angle), b = sin(angle)
                for i in stride(from: k, to: fft, by: width) {
                    let j = i + width / 2
                    let r = re[j] * a - im[j] * b
                    let s = re[j] * b + im[j] * a
                    re[j] = re[i] - r; im[j] = im[i] - s
                    re[i] += r; im[i] += s
                }
            }
            width *= 2
        }
        return (0...fft / 2).map { re[$0] * re[$0] + im[$0] * im[$0] }
    }
}
