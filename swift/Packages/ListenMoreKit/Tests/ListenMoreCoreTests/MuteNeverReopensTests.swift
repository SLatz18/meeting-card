import Foundation
import XCTest
@testable import ListenMoreCore

/// The user's Mute holds the mic device closed through every path that could reopen it: a call-state
/// blip in `syncMic`, a route restart, a diagnostics change and a resume from Pause. Unmute reopens it
/// on the routes of that moment, and the session's kept handler feeds the engine again. The session
/// runs with a real `RoutedMic` over fake routes, inputs and clock.
@MainActor
final class MuteNeverReopensTests: XCTestCase {
    final class FakeCallState: CallStateProvider {
        var states: [String: CallState] = [:]
        func callStates() -> [String: CallState] { states }
    }

    let zoom = "us.zoom.xos"
    let mac15 = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
    let speakersOut = AudioDeviceInfo(id: 1, transport: .builtIn)
    let airPods = AudioDeviceInfo(id: 2, transport: .bluetooth)
    let builtInMic = AudioDeviceInfo(id: 3, transport: .builtIn)
    var speakers: AudioRoutes { AudioRoutes(output: speakersOut, outputSource: .speakers, defaultInput: builtInMic, builtInInput: builtInMic) }
    var bluetooth: AudioRoutes { AudioRoutes(output: airPods, defaultInput: airPods, builtInInput: builtInMic) }
    let buffer = [Float](repeating: 0.1, count: 480)

    var config: ListenMoreConfig!
    var engine: RecordingEngine!
    var call: FakeCall!
    var audio: FakeAudioStateProvider!
    var calls: FakeCallState!
    var routes: FakeRoutes!
    var opener: FakeOpener!
    var scheduler: ManualScheduler!
    var mic: RoutedMic!
    let clock = ManualClock(1000)

    override func setUp() async throws {
        config = try TestConfig.load()
        engine = RecordingEngine()
        call = FakeCall()
        audio = FakeAudioStateProvider()
        calls = FakeCallState()
        routes = FakeRoutes(speakers)
        opener = FakeOpener()
        scheduler = ManualScheduler()
        mic = RoutedMic(routes: routes, opener: opener, scheduler: scheduler, macOS: mac15)
        mic.silenceTimeout = 1e9
    }

    var openInputs: [FakeInput] { opener.opened.filter { !$0.stopped } }

    func poll(_ s: CoachSession, seconds: Double) {
        var t = 0.0
        while t < seconds - 1e-9 {
            clock.advance(config.trigger.pollS)
            scheduler.advance(config.trigger.pollS)
            s.tick()
            t += config.trigger.pollS
        }
    }

    func mutedWhileListening() -> CoachSession {
        let clock = clock
        let s = CoachSession(config: config, engine: engine, mic: mic, call: call, signal: AudioActivitySignal(provider: audio),
                             keys: FakeKeys(key: nil), renderer: FakeRenderer(),
                             settings: TriggerSettings(config: config, anyApp: false, ownPid: 1, ownBundleId: "com.example.hostapp"),
                             callState: calls, wallClock: { clock.now() })
        audio.zoomCall()
        calls.states = [zoom: .started]
        s.tick()
        poll(s, seconds: config.trigger.startAfterS)
        XCTAssertEqual(s.indicator, .listening)
        XCTAssertEqual(openInputs.count, 1, "listening with the mic open")
        s.setMicMuted(true)
        XCTAssertEqual(s.indicator, .micOff)
        XCTAssertTrue(openInputs.isEmpty, "Mute closes the device")
        return s
    }

    func testMuteSurvivesAnEndedStartedBlip() async {
        let s = mutedWhileListening()
        calls.states = [zoom: .ended]
        poll(s, seconds: 1)
        calls.states = [zoom: .started]
        poll(s, seconds: 1)
        XCTAssertTrue(s.micMuted)
        XCTAssertNotNil(s.session)
        XCTAssertTrue(openInputs.isEmpty, "syncMic doesn't reopen a muted mic")
        XCTAssertEqual(opener.opened.count, 1)
    }

    func testMuteSurvivesARouteRestart() async {
        let s = mutedWhileListening()
        routes.set(bluetooth)
        poll(s, seconds: 2)
        routes.set(speakers)
        poll(s, seconds: 2)
        XCTAssertTrue(openInputs.isEmpty)
        XCTAssertEqual(opener.opened.count, 1)
    }

    func testMuteSurvivesADiagnosticsChange() async {
        let s = mutedWhileListening()
        mic.setDiagnostics(MicDiagnostics(speakerVoiceProcessing: false, speakerMicSource: .builtIn))
        poll(s, seconds: 1)
        XCTAssertTrue(openInputs.isEmpty)
        XCTAssertEqual(opener.opened.count, 1)
    }

    func testMuteSurvivesAResumeFromPause() async {
        let s = mutedWhileListening()
        s.setPaused(true)
        XCTAssertEqual(s.indicator, .paused)
        s.setPaused(false)
        XCTAssertEqual(s.indicator, .micOff)
        poll(s, seconds: 2)
        XCTAssertTrue(openInputs.isEmpty, "Resume starts the mic muted: nothing opens")
        XCTAssertEqual(opener.opened.count, 1)
    }

    func testMuteSurvivesAllOfThemTogether() async {
        let s = mutedWhileListening()
        s.setPaused(true)
        routes.set(bluetooth)
        mic.setDiagnostics(MicDiagnostics(speakerVoiceProcessing: false))
        calls.states = [zoom: .ended]
        poll(s, seconds: 1)
        s.setPaused(false)
        calls.states = [zoom: .started]
        poll(s, seconds: 2)
        XCTAssertTrue(s.micMuted)
        XCTAssertTrue(openInputs.isEmpty)
        XCTAssertEqual(opener.opened.count, 1)
    }

    func testUnmuteReopensOnTheCurrentRouteWithTheKeptHandler() async {
        let s = mutedWhileListening()
        routes.set(bluetooth)
        poll(s, seconds: 2)
        s.setMicMuted(false)
        XCTAssertEqual(s.indicator, .listening)
        XCTAssertEqual(openInputs.count, 1)
        XCTAssertEqual(openInputs.first?.plan.route, .bluetooth, "the routes of this moment")
        XCTAssertEqual(openInputs.first?.plan.micSource, .builtIn)
        XCTAssertEqual(mic.isStarted, true, "never stopped: the session's handler is the one kept")
        openInputs.first?.deliver(buffer)
        s.drainEngineForTesting()
        XCTAssertEqual(engine.ingested[.mic], 480, "the kept handler feeds the engine again")
    }

    func testAudioDeliveredWhileMutedNeverReachesTheEngine() async {
        let s = mutedWhileListening()
        let closed = opener.opened[0]
        closed.handler(buffer)
        s.drainEngineForTesting()
        XCTAssertNil(engine.ingested[.mic], "the gate is closed while muted")
    }
}
