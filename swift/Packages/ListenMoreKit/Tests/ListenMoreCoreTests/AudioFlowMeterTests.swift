import XCTest
@testable import ListenMoreCore

final class AudioFlowMeterTests: XCTestCase {
    func buffer(_ level: Float, count: Int = 480) -> [Float] { [Float](repeating: level, count: count) }

    func lines(_ events: [CoachLogEvent]) -> [String] { events.map(\.rendered) }

    func testNothingBeforeStartOrAfterFinish() {
        let m = AudioFlowMeter(source: .call, watchesSilence: true)
        m.record(buffer(0.1))
        XCTAssertEqual(m.tick(now: 100), [])
        m.start(now: 0)
        m.record(buffer(0.1))
        XCTAssertEqual(lines(m.finish(now: 5)), ["audio.flow source=call seconds=5 buffers=1 voiced=1 peakDb=-20"])
        m.record(buffer(0.1))
        XCTAssertEqual(m.tick(now: 30), [], "idle after finish")
    }

    /// One line per ten seconds with the counts and the loudest peak, then the window starts over.
    func testFlowLineEveryTenSeconds() {
        let m = AudioFlowMeter(source: .call, watchesSilence: true)
        m.start(now: 0)
        for _ in 0..<8 { m.record(buffer(0.1)) }
        m.record(buffer(0.0001))
        m.record(buffer(0.5))
        XCTAssertEqual(m.tick(now: 9), [], "not yet")
        XCTAssertEqual(lines(m.tick(now: 10)), ["audio.flow source=call seconds=10 buffers=10 voiced=9 peakDb=-6"])
        for _ in 0..<3 { m.record(buffer(0.01)) }
        XCTAssertEqual(m.tick(now: 15), [])
        XCTAssertEqual(lines(m.tick(now: 20)), ["audio.flow source=call seconds=10 buffers=3 voiced=3 peakDb=-40"])
    }

    func testQuietBuffersAreCountedButNotVoiced() {
        let m = AudioFlowMeter(source: .mic, watchesSilence: false)
        m.start(now: 0)
        m.record(buffer(0.0001))
        XCTAssertEqual(lines(m.tick(now: 10)), ["audio.flow source=mic seconds=10 buffers=1 voiced=0 peakDb=-80"])
    }

    /// Buffers of zeros for fifteen seconds is digital silence, reported once; sound ends it with a note.
    func testDigitalSilenceIsReportedOnceAndEndsWhenSoundReturns() {
        let m = AudioFlowMeter(source: .call, watchesSilence: true)
        m.start(now: 0)
        var all: [String] = []
        for t in 1...30 {
            for _ in 0..<50 { m.record(buffer(0)) }
            all += lines(m.tick(now: Double(t)))
        }
        XCTAssertEqual(all.filter { $0.hasPrefix("callAudio.silent") }, ["callAudio.silent source=call seconds=15 kind=digitalSilence buffers=750"])
        XCTAssertTrue(all.contains("audio.flow source=call seconds=10 buffers=500 voiced=0 peakDb=-120"), "\(all)")
        m.record(buffer(0.2))
        XCTAssertEqual(lines(m.tick(now: 31)), ["callAudio.sound source=call"])
        XCTAssertEqual(m.tick(now: 32), [])
    }

    func testNoBuffersAtAllIsItsOwnKind() {
        let m = AudioFlowMeter(source: .call, watchesSilence: true)
        m.start(now: 0)
        XCTAssertFalse(lines(m.tick(now: 14)).contains { $0.hasPrefix("callAudio.silent") }, "a flow line with zero buffers is fine, a silence report is not due yet")
        XCTAssertTrue(lines(m.tick(now: 15)).contains("callAudio.silent source=call seconds=15 kind=noBuffers buffers=0"))
    }

    func testSoundKeepsTheStreamFromBeingSilent() {
        let m = AudioFlowMeter(source: .call, watchesSilence: true)
        m.start(now: 0)
        for t in 1...60 {
            m.record(buffer(t % 10 == 0 ? 0.05 : 0))
            XCTAssertFalse(lines(m.tick(now: Double(t))).contains { $0.hasPrefix("callAudio.silent") }, "t=\(t)")
        }
    }

    func testTheMicIsNeverReportedSilent() {
        let m = AudioFlowMeter(source: .mic, watchesSilence: false)
        m.start(now: 0)
        for t in 1...60 { XCTAssertFalse(lines(m.tick(now: Double(t))).contains { $0.hasPrefix("callAudio.silent") }) }
    }

    /// The meter keeps numbers only: its API takes samples and returns events; nothing of the audio can come back.
    func testOnlyCountsComeBack() {
        let m = AudioFlowMeter(source: .call, watchesSilence: true)
        m.start(now: 0)
        m.record([0.5, -0.25, 0.125])
        for line in lines(m.finish(now: 1)) {
            XCTAssertNotNil(line.range(of: #"^audio\.flow( [A-Za-z]+=-?[A-Za-z0-9]+)+$"#, options: .regularExpression), line)
        }
    }
}
