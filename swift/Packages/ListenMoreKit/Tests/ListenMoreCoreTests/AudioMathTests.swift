import XCTest
@testable import ListenMoreCore

final class AudioMathTests: XCTestCase {
    func testRmsDbfs() {
        XCTAssertEqual(AudioMath.rmsDbfs([Float]()), -120)
        XCTAssertEqual(AudioMath.rmsDbfs([0, 0, 0]), -120, accuracy: 1e-9)
        XCTAssertEqual(AudioMath.rmsDbfs([1, -1]), 0, accuracy: 1e-9)
        XCTAssertEqual(AudioMath.rmsDbfs([0.1, -0.1]), -20, accuracy: 1e-6)
    }

    func testResampleMatchesNumpyInterp() {
        // np.interp(arange(2) * 1.5, arange(3), [0, 1, 0]) -> [0, 0.5]
        XCTAssertEqual(AudioMath.resample([0, 1, 0][...], from: 24000, to: 16000), [0, 0.5])
        let up = AudioMath.resample([0, 1][...], from: 1, to: 2)
        XCTAssertEqual(up, [0, 0.5, 1, 1])
        XCTAssertEqual(AudioMath.resample([0.25, 0.5][...], from: 16000, to: 16000), [0.25, 0.5])
        XCTAssertEqual(AudioMath.resample([Float](repeating: 0.1, count: 480)[...], from: 24000, to: 16000).count, 320)
    }

    func testPcm16ClipsAndTruncates() {
        XCTAssertEqual(AudioMath.pcm16([0, 1, -1, 2, -2, 0.5, -0.5][...]), [0, 32767, -32767, 32767, -32767, 16383, -16383])
        let d = AudioMath.pcm16Data([1, -1][...])
        XCTAssertEqual([UInt8](d), [0xFF, 0x7F, 0x01, 0x80])
    }

    func testRingBuffer() {
        var r = RingBuffer(capacity: 4)
        XCTAssertEqual(r.read(), [])
        r.push([1, 2][...])
        XCTAssertEqual(r.read(), [1, 2])
        r.push([3, 4, 5][...])
        XCTAssertEqual(r.read(), [2, 3, 4, 5])
        r.push([6, 7, 8, 9, 10, 11][...])
        XCTAssertEqual(r.read(), [8, 9, 10, 11])
        r.clear()
        XCTAssertEqual(r.read(), [])
        var empty = RingBuffer(capacity: 0)
        empty.push([1][...])
        XCTAssertEqual(empty.read(), [])
    }

    func testWebRTCVadRejectsBadFrames() {
        XCTAssertTrue(WebRTCVad.isValid(sampleRate: 16000, frameLength: 320))
        XCTAssertFalse(WebRTCVad.isValid(sampleRate: 16000, frameLength: 300))
        XCTAssertFalse(WebRTCVad.isValid(sampleRate: 24000, frameLength: 480))
        XCTAssertNil(WebRTCVad(mode: 4))
        let vad = WebRTCVad(mode: 3)!
        XCTAssertEqual(vad.isSpeech([Int16](repeating: 0, count: 320), sampleRate: 16000), false)
        XCTAssertNil(vad.isSpeech([Int16](repeating: 0, count: 100), sampleRate: 16000))
    }

    func testFrameAlignerPairsAndPadsSilentStream() {
        var a = FrameAligner(hop: 4, maxLagSamples: 8)
        a.append(.mic, [1, 1, 1, 1, 2, 2])
        XCTAssertTrue(a.popFrames().isEmpty)
        a.append(.call, [9, 9, 9, 9])
        let f = a.popFrames()
        XCTAssertEqual(f.count, 1)
        XCTAssertEqual(f[0].mic, [1, 1, 1, 1])
        XCTAssertEqual(f[0].call, [9, 9, 9, 9])
        a.append(.mic, [Float](repeating: 3, count: 12))
        let padded = a.popFrames()
        XCTAssertEqual(padded.count, 2)
        XCTAssertEqual(padded[0].call, [0, 0, 0, 0])
        XCTAssertEqual(a.paddedFrames, 2)
        XCTAssertEqual(a.buffered.mic, 6)
        a.reset()
        XCTAssertEqual(a.buffered.mic, 0)
    }

    func testProsodyMath() {
        XCTAssertEqual(ProsodyMath.median([3, 1, 2]), 2)
        XCTAssertEqual(ProsodyMath.median([4, 1, 2, 3]), 2.5)
        XCTAssertEqual(ProsodyMath.peakRate([1, 2, 3], frameS: 0.02), 0)
        let flat = [Double](repeating: -30, count: 50)
        XCTAssertEqual(ProsodyMath.peakRate(flat, frameS: 0.02), 0)
        var bumps = [Double](repeating: -40, count: 100)
        for c in stride(from: 10, to: 100, by: 20) { bumps[c] = -20; bumps[c - 1] = -28; bumps[c + 1] = -28 }
        XCTAssertEqual(ProsodyMath.peakRate(bumps, frameS: 0.02), 5 / 2.0, accuracy: 1e-9)
    }
}
