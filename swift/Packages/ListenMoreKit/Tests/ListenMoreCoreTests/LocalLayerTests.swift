import XCTest
@testable import ListenMoreCore

/// Ports of the reference engine's tests/test_local_layer.py, same scenarios and tolerances, on
/// generated audio.
final class LocalLayerTests: XCTestCase {
    var config: ListenMoreConfig!
    typealias S = Synthetic

    override func setUpWithError() throws {
        config = try TestConfig.load()
    }

    func testVadOnsetOffset() {
        let x = [Float](repeating: 0, count: S.sr) + S.speechish(2) + [Float](repeating: 0, count: S.sr)
        let v = StreamVAD(config: config)
        var on: [Double] = [], off: [Double] = []
        for i in 0..<(x.count / 480) {
            let s = v.process(tEnd: Double(i + 1) * 0.02, frame: x[(i * 480)..<((i + 1) * 480)])
            if let o = s.onset { on.append(o) }
            if let o = s.offset { off.append(o) }
        }
        XCTAssertEqual(on.count, 1)
        XCTAssertEqual(on.first ?? -1, 1.0, accuracy: 0.1)
        XCTAssertEqual(off.count, 1)
        XCTAssertEqual(off.first ?? -1, 3.0, accuracy: 0.15)
    }

    func testVadRejectsNoise() {
        let x = S.noise(3, dbfs: -25)
        let v = StreamVAD(config: config)
        var onsets = 0
        for i in 0..<(x.count / 480) where v.process(tEnd: Double(i + 1) * 0.02, frame: x[(i * 480)..<((i + 1) * 480)]).onset != nil {
            onsets += 1
        }
        XCTAssertEqual(onsets, 0)
    }

    func testVadRejectsQuietSpeech() {
        let x = S.speechish(2).map { $0 * 0.001 }
        let v = StreamVAD(config: config)
        XCTAssertFalse((0..<(x.count / 480)).contains { v.process(tEnd: Double($0 + 1) * 0.02, frame: x[($0 * 480)..<(($0 + 1) * 480)]).raw })
    }

    func testInterruptFiresUnder500ms() {
        let call = S.track(8, [(1.0, 5.0)], f0: 210)     // other person talks 1-5 s
        let mic = S.track(8, [(3.0, 6.5)], f0: 120)      // I cut in at 3.0 s
        let ev = S.runLocal(config, mic: mic, call: call).filter { $0.kind == .interrupt }
        XCTAssertEqual(ev.count, 1)
        XCTAssertEqual(ev.first?.onset ?? -1, 3.0, accuracy: 0.1)
        XCTAssertLessThan((ev.first?.t ?? 99) - 3.0, 0.5)
    }

    func testBackchannelDoesNotFire() {
        let call = S.track(8, [(1.0, 6.0)], f0: 210)
        let mic = S.track(8, [(3.0, 3.2)], f0: 120)      // 200 ms "yeah"
        XCTAssertEqual(S.runLocal(config, mic: mic, call: call).filter { $0.kind == .interrupt }, [])
    }

    func testTurnTakingIsNotAnInterrupt() {
        let call = S.track(8, [(1.0, 3.0)], f0: 210)
        let mic = S.track(8, [(3.15, 5.0)], f0: 120)     // 150 ms gap after the other person stops
        XCTAssertEqual(S.runLocal(config, mic: mic, call: call), [])
    }

    func testTalkOverWhenIKeepTalking() throws {
        let mic = S.track(10, [(1.0, 8.0)], f0: 120)     // I'm talking
        let call = S.track(10, [(3.0, 5.5)], f0: 210)    // someone tries to come in, I don't yield
        let ev = S.runLocal(config, mic: mic, call: call)
        let kinds = ev.map(\.kind)
        XCTAssertTrue(kinds.contains(.talkOver))
        XCTAssertFalse(kinds.contains(.interrupt))
        let to = try XCTUnwrap(ev.first { $0.kind == .talkOver })
        XCTAssertEqual(to.onset, 3.0, accuracy: 0.1)
        XCTAssertGreaterThanOrEqual(to.t - to.onset, 0.95)
        XCTAssertLessThan(to.t - to.onset, 1.3)
    }

    func testMonologueFallback() {
        let spans: [(Double, Double)] = (0..<20).map { (i: Int) -> (Double, Double) in
            let s = 1 + Double(i) * 4.3
            return (s, s + 4.0)
        }   // ~86 s, 300 ms pauses
        let ev = S.runLocal(config, mic: S.track(90, spans, f0: 120), call: S.track(90, [], f0: 210))
        let mono = ev.filter { $0.kind == .monologue }
        XCTAssertEqual(mono.count, 1)
        XCTAssertEqual(mono.first?.t ?? -1, 76.0, accuracy: 0.5)
    }

    func testTalkShareFallback() {
        var me: [(Double, Double)] = [], others: [(Double, Double)] = []
        var t = 0.5
        while t < 200 {
            me.append((t, t + 14)); t += 14.5
            others.append((t, t + 6)); t += 6.5
        }
        let ev = S.runLocal(config, mic: S.track(220, me, f0: 120), call: S.track(220, others, f0: 210))
        XCTAssertEqual(ev.filter { $0.kind == .talkShare }.count, 1)
        XCTAssertFalse(ev.contains { $0.kind == .monologue })
    }

    func testProsodyFlagsLoudnessJump() {
        let p = Prosody(config: config)
        for _ in 0..<4 {   // 8 s of baseline at -30 dB
            for _ in 0..<100 { p.onFrame(active: true, db: -30) }
            XCTAssertEqual(p.onUtteranceEnd(t: 0)?.flagged, false)
        }
        XCTAssertNotNil(p.baseline)
        for _ in 0..<100 { p.onFrame(active: true, db: -22) }
        let f = p.onUtteranceEnd(t: 10)
        XCTAssertEqual(f?.flagged, true)
        XCTAssertEqual(f?.loudnessJumpDb ?? 0, 8, accuracy: 0.01)
        for _ in 0..<10 { p.onFrame(active: true, db: -10) }
        XCTAssertNil(p.onUtteranceEnd(t: 11), "utterances under 0.8 s are ignored")
    }

    func testPeakRateCountsSyllables() {
        // 4 Hz envelope peaks for 2 s at 20 ms frames -> ~4 peaks/s.
        let db = (0..<100).map { -30 + 10 * sin(2 * Double.pi * 4 * Double($0) * 0.02) }
        XCTAssertEqual(Prosody.peakRate(db, frameS: 0.02), 4, accuracy: 0.6)
    }
}
