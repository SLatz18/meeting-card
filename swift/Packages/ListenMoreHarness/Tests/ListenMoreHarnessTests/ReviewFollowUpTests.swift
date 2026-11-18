import XCTest
import ListenMoreCore
@testable import ListenMoreHarness
#if canImport(Glibc)
import Glibc
#endif

/// Review follow-ups: line-scoped tolerance, scrubbed stdout, one watchdog per counter, crash cleanup.
final class ReviewFollowUpTests: XCTestCase {
    let config = try! ListenMoreConfig.builtIn()

    /// Tolerance is tied to the line that justifies it: a cue of a tolerated type elsewhere is false.
    func testToleranceIsScopedToALine() {
        let tol = Tolerance(type: .notListening, window: 10...16, reason: "")
        XCTAssertTrue(tol.covers(CueRecord(t: 12, engineT: 12, type: .notListening, level: nil, source: .gpt, latencyMs: 0)))
        let m = CueOracle.match(expected: [], tolerated: [tol], actual: [
            CueRecord(t: 12, engineT: 12, type: .notListening, level: nil, source: .gpt, latencyMs: 0),
            CueRecord(t: 30, engineT: 30, type: .notListening, level: nil, source: .gpt, latencyMs: 0),
            CueRecord(t: 12, engineT: 12, type: .interrupt, level: nil, source: .local, latencyMs: 0),
        ])
        XCTAssertEqual(m.tolerated.count, 1)
        XCTAssertEqual(m.falseCues.map(\.t), [30, 12])
    }

    /// The live mute-unmute scenario tolerates no interrupt anywhere, so a cut-in inside the unmute
    /// grace is always a false cue; judge tolerance covers only not_listening after replies.
    func testNoToleranceHidesAnInterruptAfterUnmute() throws {
        let t = try Timeline.realize(Scenarios.muteUnmute, shapes: SyntheticVoice.shapes(Scenarios.muteUnmute))
        let live = CueOracle.expected(t, config: config, facts: .init(keyless: false, gptStopT: nil, mode: .live, judgeOn: true))
        XCTAssertFalse(live.tolerated.contains { $0.type == .interrupt })
        XCTAssertTrue(live.tolerated.allSatisfy { $0.type == .notListening })
        let unmute = t.times(.unmute)[0]
        let m = CueOracle.match(expected: live.cues, tolerated: live.tolerated,
                                actual: [CueRecord(t: unmute + 1.5, engineT: 0, type: .interrupt, level: nil, source: .local, latencyMs: 0)])
        XCTAssertEqual(m.falseCues.count, 1)
        let off = CueOracle.expected(t, config: config, facts: .init(keyless: false, gptStopT: nil, mode: .live, judgeOn: false))
        XCTAssertTrue(off.tolerated.isEmpty, "judge off: nothing tolerated")
    }

    /// stdout and stderr lines go through the key scrubber.
    func testStdoutScrubber() {
        let env = [Harness.keyVariable: "sk-scrub-test-0123456789"]
        XCTAssertEqual(Harness.scrub("bad arg sk-scrub-test-0123456789!", environment: env), "bad arg [REDACTED]!")
        XCTAssertEqual(Harness.scrub("nothing here", environment: [:]), "nothing here")
    }
}
