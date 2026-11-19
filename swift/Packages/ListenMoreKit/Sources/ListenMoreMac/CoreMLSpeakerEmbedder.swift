import CoreML
import Foundation
import ListenMoreCore

/// Loads the bundled model on first use. A missing or unusable model switches this session to MFCC.
public final class CoreMLSpeakerEmbedder: SpeakerEmbedder, @unchecked Sendable {
    private static let samplesPerRow = 160_000
    private static let maskPerRow = 589
    private let lock = NSLock()
    private let fallback = MFCCSpeakerEmbedder()
    private var model: MLModel?
    private var unavailable = false

    public init() {}

    public func embed(_ samples: [Float], sampleRate: Int) -> SpeakerEmbedding? {
        guard sampleRate > 0, samples.count >= sampleRate / 2 else { return nil }
        return lock.withLock {
            if !unavailable {
                do {
                    if model == nil {
                        guard let url = Bundle.module.url(forResource: "wespeaker_int8", withExtension: "mlmodelc",
                                                          subdirectory: "Models") else { throw ModelError.missingResource }
                        let configuration = MLModelConfiguration()
                        configuration.computeUnits = .cpuAndGPU
                        model = try MLModel(contentsOf: url, configuration: configuration)
                    }
                    if let model { return try Self.predict(model, samples, rate: sampleRate) }
                } catch {
                    unavailable = true
                    model = nil
                }
            }
            return fallback.embed(samples, sampleRate: sampleRate)
        }
    }

    private static func predict(_ model: MLModel, _ audio: [Float], rate: Int) throws -> SpeakerEmbedding? {
        let pcm = AudioMath.resample(audio.prefix(rate * 10), from: rate, to: 16_000)
        guard !pcm.isEmpty else { return nil }
        // The model expects a 10-second clip. Repeat-pad the voiced samples as in the upstream extractor.
        let waveform = try array(width: samplesPerRow) { pcm[$0 % pcm.count] }
        let mask = try array(width: maskPerRow) { _ in 1 }
        let inputs = try MLDictionaryFeatureProvider(dictionary: ["waveform": waveform, "mask": mask])
        guard let result = try model.prediction(from: inputs).featureValue(for: "embedding")?.multiArrayValue,
              result.shape.map(\.intValue) == [3, 256] else { throw ModelError.invalidOutput }
        let values = (0..<256).map { result[[0, NSNumber(value: $0)]].floatValue }
        return SpeakerEmbedding(model: "wespeaker-resnet34-lm-int8-v1", values: values)
    }

    private static func array(width: Int, value: (Int) -> Float) throws -> MLMultiArray {
        let array = try MLMultiArray(shape: [3, NSNumber(value: width)], dataType: .float32)
        let data = array.dataPointer.assumingMemoryBound(to: Float.self)
        let rowStride = array.strides[0].intValue, columnStride = array.strides[1].intValue
        for row in 0..<3 {
            for column in 0..<width { data[row * rowStride + column * columnStride] = row == 0 ? value(column) : 0 }
        }
        return array
    }

    private enum ModelError: Error { case missingResource, invalidOutput }
}
