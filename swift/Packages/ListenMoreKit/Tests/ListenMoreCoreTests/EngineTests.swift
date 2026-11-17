import XCTest
@testable import ListenMoreCore

final class EngineTests: XCTestCase {
    typealias S = Synthetic

    final class Collector: CoachEngineDelegate {
        let lock = NSLock()
        var cues: [CueSuggestion] = []
        var disabled: [GptErrorKind] = []
        func engine(_ engine: CoachEngine, didSuggest cue: CueSuggestion) {
            lock.lock(); cues.append(cue); lock.unlock()
        }
        func engine(_ engine: CoachEngine, gptDisabled reason: GptErrorKind) {
            lock.lock(); disabled.append(reason); lock.unlock()
        }
    }

    final class MockTransport: GptTransportFactory {
        let script: [MockTranscriber.Utterance]
        let judge = MockJudge()
        var transcribers: [Speaker: MockTranscriber] = [:]
        init(script: [MockTranscriber.Utterance]) { self.script = script }
        func transcriber(config: ListenMoreConfig, key: APIKey, speaker: Speaker) -> Transcriber {
            let t = MockTranscriber(script: script, speaker: speaker)
            transcribers[speaker] = t
            return t
        }
        func judge(config: ListenMoreConfig, key: APIKey) -> Judge { judge }
    }

    /// Feeds both streams in uneven chunks, the way capture callbacks deliver them.
    func feed(_ e: LocalCoachEngine, mic: [Float], call: [Float], chunk: Int = 1024) {
        var i = 0
        while i < max(mic.count, call.count) {
            if i < mic.count { e.ingest(.mic, samples: Array(mic[i..<min(i + chunk, mic.count)])) }
            if i < call.count { e.ingest(.call, samples: Array(call[i..<min(i + chunk, call.count)])) }
            i += chunk
        }
        e.flush()
    }

    /// Port of test_engine_fast_mode_cooldown: two interrupts 7 s apart -> the second is suppressed.
    func testEngineCooldown() throws {
        let config = try TestConfig.load()
        let call = S.track(30, [(1, 5), (8, 12)], f0: 210)
        let mic = S.track(30, [(3, 6), (10, 13)], f0: 120)
        let e = LocalCoachEngine()
        let c = Collector()
        e.delegate = c
        e.start(config: config, apiKey: nil)
        feed(e, mic: mic, call: call)
        let policy = CuePolicy(config: config.cues)
        let shown = c.cues.compactMap { policy.offer($0.type, t: $0.t, onset: $0.onset, source: $0.source, confidence: $0.confidence) }
        let ints = shown.filter { $0.type == .interrupt }
        XCTAssertEqual(ints.count, 1)
        XCTAssertEqual(ints.first?.color, .red)
        XCTAssertGreaterThanOrEqual(policy.suppressed, 1)
        XCTAssertEqual(e.counters.frames, 30 * 50)
        e.stop()
        e.flush()
        XCTAssertFalse(e.isRunning)
    }

    func testMissingCallStreamIsPaddedWithSilence() throws {
        let config = try TestConfig.load()
        let e = LocalCoachEngine()
        e.start(config: config, apiKey: nil)
        feed(e, mic: [Float](repeating: 0, count: 24000), call: [])
        XCTAssertGreaterThan(e.counters.paddedFrames, 30)
        XCTAssertGreaterThan(e.counters.frames, 30)
    }

    func testIngestBeforeStartIsDropped() throws {
        let e = LocalCoachEngine()
        e.ingest(.mic, samples: [Float](repeating: 0, count: 4800))
        e.flush()
        XCTAssertEqual(e.counters.frames, 0)
    }

    /// With a key, the engine runs the GPT layer: turns are committed at VAD offsets and the judge's
    /// "aggressive" verdict comes back as a gpt cue.
    func testGptLayerThroughEngineWithMocks() throws {
        var config = try TestConfig.load()
        config.gpt.judgeMinIntervalS = 0
        let mic = S.track(6, [(1.0, 3.0)], f0: 120)
        let call = S.track(6, [], f0: 210)
        let transport = MockTransport(script: [MockTranscriber.Utterance(speaker: .me, end: 3.0, text: "utterance-1 \(MockJudge.hostileMarker)")])
        let e = LocalCoachEngine(transport: transport)
        let c = Collector()
        e.delegate = c
        e.start(config: config, apiKey: APIKey("sk-test-not-real"))
        feed(e, mic: mic, call: call)
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline && !c.cues.contains(where: { $0.source == .gpt }) {
            RunLoop.current.run(until: Date().addingTimeInterval(0.05))
            e.flush()
        }
        let gpt = try XCTUnwrap(c.cues.first { $0.source == .gpt })
        XCTAssertEqual(gpt.type, .aggressive)
        XCTAssertEqual(gpt.confidence ?? 0, 0.9, accuracy: 1e-9)
        XCTAssertGreaterThan(transport.transcribers[.me]?.audioBytes ?? 0, 0)
        XCTAssertEqual(transport.transcribers[.others]?.audioBytes, 0, "silence is never streamed")
        XCTAssertTrue(transport.judge.prompts.last?.contains("] ME: utterance-1") ?? false)
        XCTAssertTrue(c.disabled.isEmpty)
        e.stop()
    }
}
