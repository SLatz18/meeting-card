import Foundation
import XCTest
@testable import ListenMoreCore

/// "No audio is sent while paused": the real session, audio gate, engine, GPT layer, realtime
/// transcriber and wire format, with only the mic, the call source and the sockets faked. Pause
/// stops mic and call capture and closes every realtime socket; not one `input_audio_buffer.append`
/// frame is sent until Resume, which opens fresh sockets.
@MainActor
final class PauseSendsNoAudioTests: XCTestCase {
    var config: ListenMoreConfig!
    var connector: FakeConnector!
    var mic: FakeMic!
    var call: FakeCall!
    var session: CoachSession!

    override func setUp() async throws {
        config = try TestConfig.load()
        connector = FakeConnector()
        mic = FakeMic()
        call = FakeCall()
        let engine = LocalCoachEngine(transports: GptTransports(http: FakeHTTP(), webSocket: connector))
        session = CoachSession(config: config, engine: engine, mic: mic, call: call,
                               signal: AudioActivitySignal(provider: FakeAudioStateProvider()),
                               keys: FakeKeys(key: APIKey("sk-test-not-real")), renderer: FakeRenderer(),
                               settings: TriggerSettings(config: config, anyApp: false, ownPid: 1, ownBundleId: nil))
    }

    override func tearDown() async throws {
        session.shutdown()
    }

    var sockets: [FakeSocket] { connector.connections.map(\.socket) }
    var open: [FakeSocket] { sockets.filter { !$0.isClosed } }
    var appends: Int { sockets.reduce(0) { $0 + $1.appends } }

    /// Speech into both streams through the given capture callbacks, in 20 ms buffers.
    func feed(mic m: (@Sendable ([Float]) -> Void)?, call c: (@Sendable ([Float]) -> Void)?, seconds: Double) {
        let speech = Synthetic.speechish(seconds)
        for i in stride(from: 0, to: speech.count, by: 480) {
            let chunk = Array(speech[i..<min(i + 480, speech.count)])
            m?(chunk)
            c?(chunk)
        }
        session.drainEngineForTesting()
    }

    func testPauseStopsCaptureAndSendsNoAudioFramesUntilResume() async {
        session.startManual()
        let connected = await eventually { self.call.handler != nil && self.open.count == 2 }
        XCTAssertTrue(connected, "one realtime socket per stream")
        feed(mic: mic.handler, call: call.handler, seconds: 2)
        let streamed = await eventually { self.appends > 0 }
        XCTAssertTrue(streamed, "audio is streamed while listening")

        let lateMic = mic.handler
        let lateCall = call.handler
        session.setPaused(true)
        XCTAssertNil(mic.handler, "mic capture stopped")
        let closed = await eventually { self.open.isEmpty && self.call.stops >= 1 }
        XCTAssertTrue(closed, "call capture stopped and every realtime socket closed")
        let appendsAtPause = appends
        let socketsAtPause = sockets.count

        // Late device callbacks while paused go nowhere.
        feed(mic: lateMic, call: lateCall, seconds: 2)
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(appends, appendsAtPause, "no audio frames sent while paused")
        XCTAssertEqual(sockets.reduce(0) { $0 + $1.sendsAfterClose }, 0, "nothing sent on a closed socket")
        XCTAssertEqual(sockets.count, socketsAtPause, "no socket opened while paused")

        session.setPaused(false)
        let reopened = await eventually { self.open.count == 2 && self.mic.handler != nil }
        XCTAssertTrue(reopened, "Resume opens fresh sockets")
        let fresh = open
        feed(mic: lateMic, call: lateCall, seconds: 1)
        try? await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertTrue(fresh.allSatisfy { $0.appends == 0 }, "pre-pause callbacks never reach the resumed session")
        feed(mic: mic.handler, call: call.handler, seconds: 2)
        let resumed = await eventually { fresh.contains { $0.appends > 0 } }
        XCTAssertTrue(resumed, "streaming resumes after Resume")

        session.stopManual()
        let ended = await eventually { self.open.isEmpty }
        XCTAssertTrue(ended)
        XCTAssertNil(mic.handler)
    }

    final class FakeCallState: CallStateProvider {
        var states: [String: CallState] = [:]
        func callStates() -> [String: CallState] { states }
    }

    /// Muted in the call app (a "Use Zoom/Meet controls" report) takes the same path as Pause.
    func testMuteInTheCallAppSendsNoAudioFramesUntilUnmute() async {
        session.shutdown()
        let audio = FakeAudioStateProvider()
        audio.zoomCall()
        let calls = FakeCallState()
        var settings = TriggerSettings(config: config, anyApp: false, ownPid: 1, ownBundleId: nil)
        settings.startAfterS = 0
        session = CoachSession(config: config, engine: LocalCoachEngine(transports: GptTransports(http: FakeHTTP(), webSocket: connector)),
                               mic: mic, call: call, signal: AudioActivitySignal(provider: audio),
                               keys: FakeKeys(key: APIKey("sk-test-not-real")), renderer: FakeRenderer(), settings: settings,
                               callState: calls)
        session.tick()
        XCTAssertEqual(session.indicator, .listening)
        let connected = await eventually { self.call.handler != nil && self.open.count == 2 }
        XCTAssertTrue(connected)
        feed(mic: mic.handler, call: call.handler, seconds: 2)
        let streamed = await eventually { self.appends > 0 }
        XCTAssertTrue(streamed)

        let lateMic = mic.handler
        let lateCall = call.handler
        calls.states = ["us.zoom.xos": .muted]
        session.tick()
        XCTAssertEqual(session.indicator, .muted)
        XCTAssertNil(mic.handler, "mic capture stopped while muted")
        let closed = await eventually { self.open.isEmpty }
        XCTAssertTrue(closed, "every realtime socket closed while muted")
        let appendsAtMute = appends
        feed(mic: lateMic, call: lateCall, seconds: 2)
        session.tick()
        try? await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(appends, appendsAtMute, "no audio frames sent while muted")
        XCTAssertEqual(sockets.reduce(0) { $0 + $1.sendsAfterClose }, 0)

        calls.states = ["us.zoom.xos": .started]
        session.tick()
        XCTAssertEqual(session.indicator, .listening)
        let reopened = await eventually { self.open.count == 2 && self.mic.handler != nil }
        XCTAssertTrue(reopened, "unmute resumes on fresh sockets")
        let fresh = open
        feed(mic: mic.handler, call: call.handler, seconds: 2)
        let resumed = await eventually { fresh.contains { $0.appends > 0 } }
        XCTAssertTrue(resumed)
    }

    func testSwitchingOffClosesEverything() async {
        session.startManual()
        _ = await eventually { self.open.count == 2 }
        session.setEnabled(false)
        XCTAssertNil(mic.handler)
        let closed = await eventually { self.open.isEmpty && self.call.stops >= 1 }
        XCTAssertTrue(closed)
    }
}
