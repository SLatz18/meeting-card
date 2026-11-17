import XCTest
@testable import ListenMoreCore

/// Pause, Stop and switching the coach off fully stop capture and close the OpenAI streams: no
/// audio is captured or sent while paused.
final class CoachRunnerTests: XCTestCase {
    final class FakeCapture: CoachCapture {
        var onMic: (([Float]) -> Void)?
        var onCall: (([Float]) -> Void)?
        var starts: [[String]] = []
        var stops = 0
        var running: Bool { onMic != nil }

        func start(bundleIds: [String], onMic: @escaping ([Float]) -> Void, onCall: @escaping ([Float]) -> Void) {
            starts.append(bundleIds)
            self.onMic = onMic
            self.onCall = onCall
        }

        func stop() {
            stops += 1
            onMic = nil
            onCall = nil
        }

        /// What a real device would deliver: only while capture is running.
        func deliver(_ seconds: Double) {
            let speech = Synthetic.speechish(seconds)
            for i in stride(from: 0, to: speech.count, by: 960) {
                onMic?(Array(speech[i..<min(i + 960, speech.count)]))
                onCall?([Float](repeating: 0, count: min(960, speech.count - i)))
            }
        }
    }

    final class Transport: GptTransportFactory {
        var made: [MockTranscriber] = []
        func transcriber(config: ListenMoreConfig, key: APIKey, speaker: Speaker) -> Transcriber {
            let t = MockTranscriber(script: [], speaker: speaker)
            made.append(t)
            return t
        }
        func judge(config: ListenMoreConfig, key: APIKey) -> Judge { MockJudge() }
        var bytesSent: Int { made.reduce(0) { $0 + $1.audioBytes } }
        var open: [MockTranscriber] { made.filter { !$0.closed } }
    }

    var config: ListenMoreConfig!
    var capture: FakeCapture!
    var transport: Transport!
    var engine: LocalCoachEngine!
    var runner: CoachRunner!
    var trigger: CoachTrigger!

    override func setUpWithError() throws {
        config = try TestConfig.load()
        capture = FakeCapture()
        transport = Transport()
        engine = LocalCoachEngine(transport: transport)
        runner = CoachRunner(config: config, engine: engine, capture: capture, readKey: { APIKey("sk-test-not-real") })
        trigger = CoachTrigger(settings: TriggerSettings(config: config, anyApp: false, ownPid: 1, ownBundleId: nil), enabled: true)
    }

    func apply(_ a: [TriggerAction]) {
        runner.apply(a, session: trigger.session)
        engine.flush()
    }

    func testPauseStopsCaptureAndClosesStreams() {
        apply(trigger.manualStart(now: 0))
        XCTAssertTrue(capture.running)
        XCTAssertEqual(transport.open.count, 2, "one transcription session per stream")
        capture.deliver(2)
        engine.flush()
        let sentBeforePause = transport.bytesSent
        XCTAssertGreaterThan(sentBeforePause, 0)

        apply(trigger.setPaused(true))
        XCTAssertFalse(capture.running)
        XCTAssertFalse(runner.isCapturing)
        XCTAssertFalse(engine.isRunning)
        XCTAssertTrue(transport.open.isEmpty, "every OpenAI stream is closed while paused")
        capture.deliver(2)
        engine.ingest(.mic, samples: Synthetic.speechish(1))   // even a straggler buffer goes nowhere
        engine.flush()
        XCTAssertEqual(transport.bytesSent, sentBeforePause, "no audio is sent while paused")

        apply(trigger.setPaused(false))
        XCTAssertTrue(capture.running)
        XCTAssertEqual(transport.open.count, 2, "resume opens fresh sessions")
        XCTAssertEqual(capture.starts.count, 2)
    }

    func testStopAndDisableStopCapture() {
        apply(trigger.manualStart(now: 0))
        apply(trigger.manualStop())
        XCTAssertFalse(capture.running)
        XCTAssertTrue(transport.open.isEmpty)
        apply(trigger.manualStart(now: 1))
        XCTAssertTrue(capture.running)
        apply(trigger.setEnabled(false))
        XCTAssertFalse(capture.running)
        XCTAssertTrue(transport.open.isEmpty)
        XCTAssertEqual(capture.stops, 2)
    }

    func testNothingCapturedBeforeASessionStarts() {
        let snap = AudioStateSnapshot(defaultInputRunning: true, processes: [
            AudioProcessState(pid: 9, bundleId: "us.zoom.xos", isRunningInput: true, isRunningOutput: true)])
        apply(trigger.tick(snap, now: 0))
        apply(trigger.tick(snap, now: 2))
        XCTAssertTrue(capture.starts.isEmpty, "detection reads running state only; capture waits for the session")
        apply(trigger.tick(snap, now: 3))
        XCTAssertEqual(capture.starts, [["us.zoom.xos"]])
    }

    func testManualStartCapturesAllCallApps() {
        apply(trigger.manualStart(now: 0))
        XCTAssertEqual(capture.starts.first, config.captureTargets.map(\.bundleId))
    }

    func testNoKeyRunsLocalOnly() {
        runner = CoachRunner(config: config, engine: engine, capture: capture, readKey: { nil })
        apply(trigger.manualStart(now: 0))
        XCTAssertTrue(capture.running)
        XCTAssertTrue(transport.made.isEmpty, "nothing goes to OpenAI without a key")
    }
}
