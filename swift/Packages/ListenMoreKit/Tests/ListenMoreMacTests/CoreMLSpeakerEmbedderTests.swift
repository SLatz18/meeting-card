import XCTest
import ListenMoreMac

final class CoreMLSpeakerEmbedderTests: XCTestCase {
    func testBundledModelProducesAnEmbeddingWithoutNetwork() throws {
        let rate = 16_000
        let input = (0..<(rate * 2)).map { i -> Float in
            let t = Double(i) / Double(rate)
            return Float(0.12 * sin(2 * .pi * 180 * t) + 0.04 * sin(2 * .pi * 540 * t))
        }
        let result = try XCTUnwrap(CoreMLSpeakerEmbedder().embed(input, sampleRate: rate))
        XCTAssertEqual(result.model, "wespeaker-resnet34-lm-int8-v1")
        XCTAssertEqual(result.values.count, 256)
    }
}
