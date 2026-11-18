import Foundation
import XCTest
@testable import ListenMoreCore

/// The mic (and with it voice processing's ducking and any Bluetooth headset hold) is released while
/// Paused, while the call app reports muted, and on the first poll that sees a call-end report. The
/// `stop_after_s` tail keeps it open only when there is no report for the session's app. Resume
/// latency is counted in polls (`trigger.poll_s`, 0.5 s); the device's own start time is on top.
@MainActor
final class MicReleaseTests: XCTestCase {
    final class FakeCallState: CallStateProvider {
        var states: [String: CallState] = [:]
        func callStates() -> [String: CallState] { states }
    }

    let zoom = "us.zoom.xos"
    var config: ListenMoreConfig!
    var engine: RecordingEngine!
    var mic: FakeMic!
    var call: FakeCall!
    var audio: FakeAudioStateProvider!
    let clock = ManualClock(1000)

    override func setUp() async throws {
        config = try TestConfig.load()
        engine = RecordingEngine()
        mic = FakeMic()
        call = FakeCall()
        audio = FakeAudioStateProvider()
    }

    func makeSession(callState: CallStateProvider?) -> CoachSession {
        let clock = clock
        let settings = TriggerSettings(config: config, anyApp: false, ownPid: 1, ownBundleId: "com.example.hostapp")
        return CoachSession(config: config, engine: engine, mic: mic, call: call, signal: AudioActivitySignal(provider: audio),
                            keys: FakeKeys(key: nil), renderer: FakeRenderer(), settings: settings, callState: callState,
                            wallClock: { clock.now() })
    }

    func poll(_ s: CoachSession, seconds: Double) {
        var t = 0.0
        while t < seconds - 1e-9 {
            clock.advance(config.trigger.pollS)
            s.tick()
            t += config.trigger.pollS
        }
    }

    func listening(_ calls: FakeCallState? = nil) -> CoachSession {
        let s = makeSession(callState: calls)
        audio.zoomCall()
        calls?.states = [zoom: .started]
        s.tick()
        poll(s, seconds: config.trigger.startAfterS)
        XCTAssertEqual(s.indicator, .listening)
        XCTAssertEqual(mic.started, 1)
        return s
    }

    func testDefaultsAreThreeSecondsAfterACallEndAndThirtyWithout() {
        XCTAssertEqual(config.trigger.endedStopAfterS, 3)
        XCTAssertEqual(config.trigger.stopAfterS, 30)
        XCTAssertEqual(config.trigger.pollS, 0.5)
    }

    func testCallEndReleasesTheMicOnTheFirstPollAndTheSessionEndsThreeSecondsLater() async {
        let calls = FakeCallState()
        let s = listening(calls)
        calls.states = [zoom: .ended]
        poll(s, seconds: 0.5)
        XCTAssertEqual(mic.muted, [true], "device closed on the poll that sees the report")
        XCTAssertFalse(mic.isOpen)
        XCTAssertEqual(mic.stopped, 0, "the mic stays started with the session's handler")
        XCTAssertTrue(s.micDeviceOff)
        XCTAssertNotNil(s.session, "the session itself still waits out ended_stop_after_s")
        XCTAssertEqual(s.capturingBundleIds, [zoom])
        s.drainEngineForTesting()
        XCTAssertEqual(engine.stops, 0, "the engine and call capture keep running until the session ends")
        XCTAssertEqual(call.stops, 0)

        poll(s, seconds: 3)
        XCTAssertNil(s.session)
        XCTAssertTrue(s.capturingBundleIds.isEmpty)
        XCTAssertEqual(mic.stopped, 1, "stopped once, at the session's end")
        XCTAssertEqual(mic.muted, [true], "never reopened for an ended call")
        XCTAssertEqual(mic.started, 1)
        XCTAssertFalse(s.micDeviceOff)
        poll(s, seconds: 10)
        XCTAssertEqual(mic.started, 1)
    }

    func testAnEndedBlipReopensOnlyTheMic() async {
        let calls = FakeCallState()
        let s = listening(calls)
        _ = await eventually { self.call.starts.count == 1 }
        calls.states = [zoom: .ended]
        poll(s, seconds: 1)
        XCTAssertEqual(mic.muted, [true])
        calls.states = [zoom: .started]
        poll(s, seconds: 0.5)
        XCTAssertEqual(mic.muted, [true, false], "reopened on the next poll")
        XCTAssertTrue(mic.isOpen)
        XCTAssertEqual(mic.started, 1, "same start, same handler")
        XCTAssertFalse(s.micDeviceOff)
        s.drainEngineForTesting()
        XCTAssertEqual(engine.startedWithKey.count, 1, "no engine (or OpenAI session) restart")
        XCTAssertEqual(engine.stops, 0)
        XCTAssertEqual(call.starts.count, 1, "call capture untouched")
        poll(s, seconds: 5)
        XCTAssertEqual(s.indicator, .listening)
        XCTAssertEqual(mic.muted, [true, false])
    }

    func testReopenedMicFeedsTheSameSession() async {
        let calls = FakeCallState()
        let s = listening(calls)
        calls.states = [zoom: .ended]
        poll(s, seconds: 0.5)
        calls.states = [zoom: .started]
        poll(s, seconds: 0.5)
        mic.handler?([Float](repeating: 0, count: 480))
        let flowed = await eventually { self.engine.ingested[.mic] == 480 }
        XCTAssertTrue(flowed)
    }

    func testWithoutACallSignalTheMicRunsThroughTheThirtySecondTail() {
        let s = listening()
        audio.silence()
        poll(s, seconds: 29)
        XCTAssertNotNil(s.session)
        XCTAssertEqual(mic.stopped, 0, "no call signal: the tail keeps listening")
        XCTAssertTrue(mic.muted.isEmpty)
        XCTAssertFalse(s.micDeviceOff)
        poll(s, seconds: 1.5)
        XCTAssertNil(s.session)
        XCTAssertEqual(mic.stopped, 1)
    }

    func testAReportForAnotherAppIsNoSignalForThisSession() {
        let calls = FakeCallState()
        let s = listening(calls)
        calls.states = ["company.thebrowser.dia": .ended]
        audio.silence()
        poll(s, seconds: 29)
        XCTAssertNotNil(s.session)
        XCTAssertEqual(mic.stopped, 0)
        poll(s, seconds: 1.5)
        XCTAssertNil(s.session)
        XCTAssertEqual(mic.stopped, 1)
    }

    /// Pause to Resume: zero polls; Resume reopens the mic inside the call.
    func testPauseReleasesAndResumeReopensSynchronously() {
        let s = listening()
        s.setPaused(true)
        XCTAssertEqual(mic.stopped, 1)
        XCTAssertNil(mic.handler)
        s.setPaused(false)
        XCTAssertEqual(mic.started, 2)
        XCTAssertNotNil(mic.handler)
    }

    /// Mute to unmute: one poll after the call app's report changes.
    func testMuteReleasesAndUnmuteReopensOnTheNextPoll() {
        let calls = FakeCallState()
        let s = listening(calls)
        calls.states = [zoom: .muted]
        poll(s, seconds: 0.5)
        XCTAssertEqual(s.indicator, .muted)
        XCTAssertEqual(mic.stopped, 1)
        XCTAssertNil(mic.handler)
        calls.states = [zoom: .started]
        poll(s, seconds: 0.5)
        XCTAssertEqual(s.indicator, .listening)
        XCTAssertEqual(mic.started, 2)
        XCTAssertNotNil(mic.handler)
    }

    func testResumingDuringACallEndKeepsTheMicClosed() {
        let calls = FakeCallState()
        let s = listening(calls)
        s.setPaused(true)
        calls.states = [zoom: .ended]
        poll(s, seconds: 0.5)
        s.setPaused(false)
        XCTAssertEqual(s.capturingBundleIds, [zoom])
        XCTAssertEqual(mic.muted, [true], "muted before it starts")
        XCTAssertEqual(mic.started, 2)
        XCTAssertFalse(mic.isOpen, "an ended call never opens the device, not even briefly")
        XCTAssertTrue(s.micDeviceOff)
        poll(s, seconds: 3)
        XCTAssertNil(s.session)
        XCTAssertEqual(mic.muted, [true])
    }

    /// While the device is held closed, nothing in the session reopens it: not polls, not fallback
    /// restarts of call capture, not a blip that ends in another ended report.
    func testNothingReopensAClosedDeviceUntilItsReasonClears() async {
        let calls = FakeCallState()
        let s = listening(calls)
        calls.states = [zoom: .ended]
        for _ in 0..<5 { poll(s, seconds: 0.5) }
        XCTAssertEqual(mic.muted, [true])
        XCTAssertFalse(mic.isOpen)
        XCTAssertEqual(mic.started, 1)
    }
}
