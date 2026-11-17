import Foundation
import XCTest
import ListenMoreCore
@testable import ListenMoreMac

/// Proof for the copy line "No audio is sent while paused": the real capture gate, engine,
/// realtime transcriber and wire format, with only the mic, the call source and the WebSocket
/// faked. Pause stops mic and call capture and closes every realtime socket; not one
/// `input_audio_buffer.append` frame is sent until Resume, which opens fresh sockets.
final class PauseSendsNoAudioTests: XCTestCase {
    final class FakeSocket: RealtimeSocket {
        private let lock = NSLock()
        private var _sent: [String] = []
        private var _cancelled = false
        var sent: [String] { lock.lock(); defer { lock.unlock() }; return _sent }
        var cancelled: Bool { lock.lock(); defer { lock.unlock() }; return _cancelled }
        var appends: Int { sent.filter { $0.contains("\"input_audio_buffer.append\"") }.count }

        func resume() {}
        func send(_ text: String, completion: @escaping (Error?) -> Void) {
            lock.lock()
            _sent.append(text)   // recorded even after cancel, so a send on a closed socket shows up
            lock.unlock()
            completion(nil)
        }
        func receive(_ completion: @escaping (Result<Data, Error>) -> Void) {}
        func cancel() { lock.lock(); _cancelled = true; lock.unlock() }
    }

    final class Sockets {
        private let lock = NSLock()
        private var _all: [FakeSocket] = []
        var all: [FakeSocket] { lock.lock(); defer { lock.unlock() }; return _all }
        var open: [FakeSocket] { all.filter { !$0.cancelled } }
        var appends: Int { all.reduce(0) { $0 + $1.appends } }
        func make(_ req: URLRequest) -> RealtimeSocket {
            let s = FakeSocket()
            lock.lock(); _all.append(s); lock.unlock()
            return s
        }
    }

    final class FakeMic: MicSource {
        var handler: (([Float]) -> Void)?
        /// Kept after stop(): a late device callback can still fire.
        var lastHandler: (([Float]) -> Void)?
        var running: Bool { handler != nil }
        func start(handler: @escaping ([Float]) -> Void) throws { self.handler = handler; lastHandler = handler }
        func stop() { handler = nil }
    }

    final class FakeCall: CallSource {
        private let lock = NSLock()
        private var _handler: (([Float]) -> Void)?
        private var _last: (([Float]) -> Void)?
        var running: Bool { lock.lock(); defer { lock.unlock() }; return _handler != nil }
        var lastHandler: (([Float]) -> Void)? { lock.lock(); defer { lock.unlock() }; return _last }
        func start(bundleIds: [String], stage: CaptureStage, handler: @escaping ([Float]) -> Void) async throws {
            lock.lock(); _handler = handler; _last = handler; lock.unlock()
        }
        func stop() async { lock.lock(); _handler = nil; lock.unlock() }
        func helperPids(bundleIds: [String]) async -> Set<pid_t> { [] }
    }

    var config: ListenMoreConfig!
    var sockets: Sockets!
    var mic: FakeMic!
    var call: FakeCall!
    var engine: LocalCoachEngine!
    var runner: CoachRunner!
    var trigger: CoachTrigger!

    override func setUpWithError() throws {
        config = try ListenMoreConfig.builtIn()
        sockets = Sockets()
        mic = FakeMic()
        call = FakeCall()
        let s = sockets!
        engine = LocalCoachEngine(transport: OpenAITransport(makeSocket: { s.make($0) }, makeJudge: { _, _ in MockJudge() }))
        let capture = CoachAudioCapture(config: config, mic: mic, call: call)
        runner = CoachRunner(config: config, engine: engine, capture: capture, readKey: { APIKey("sk-test-not-real") })
        trigger = CoachTrigger(settings: TriggerSettings(config: config, anyApp: false, ownPid: 1, ownBundleId: nil), enabled: true)
    }

    func apply(_ a: [TriggerAction]) {
        runner.apply(a, session: trigger.session)
        engine.flush()
    }

    func waitUntil(_ cond: @autoclosure () -> Bool, _ timeout: TimeInterval = 3) {
        let end = Date().addingTimeInterval(timeout)
        while !cond() && Date() < end { RunLoop.current.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// Feeds speech through the given mic and call callbacks (20 ms buffers).
    func feed(mic m: (([Float]) -> Void)?, call c: (([Float]) -> Void)?, seconds: Double) {
        let speech = Self.speechish(seconds)
        for i in stride(from: 0, to: speech.count, by: 480) {
            let chunk = Array(speech[i..<min(i + 480, speech.count)])
            m?(chunk)
            c?(chunk)
        }
        engine.flush()
    }

    func testPauseStopsCaptureAndSendsNoAudioFramesUntilResume() {
        apply(trigger.manualStart(now: 0))
        waitUntil(self.call.running)
        XCTAssertTrue(mic.running)
        XCTAssertTrue(call.running)
        XCTAssertEqual(sockets.open.count, 2, "one realtime socket per stream")

        feed(mic: mic.handler, call: call.lastHandler, seconds: 2)
        waitUntil(self.sockets.appends > 0)
        XCTAssertGreaterThan(sockets.appends, 0, "audio is streamed while listening")

        apply(trigger.setPaused(true))
        XCTAssertFalse(mic.running, "mic capture stopped")
        waitUntil(!self.call.running)
        XCTAssertFalse(call.running, "call capture stopped")
        XCTAssertTrue(sockets.open.isEmpty, "every realtime socket closed")
        let appendsAtPause = sockets.appends
        let socketsAtPause = sockets.all.count

        // Late device callbacks and a straggler buffer while paused go nowhere.
        feed(mic: mic.lastHandler, call: call.lastHandler, seconds: 2)
        engine.ingest(.mic, samples: Self.speechish(1))
        engine.flush()
        RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(sockets.appends, appendsAtPause, "no audio frames sent while paused")
        XCTAssertEqual(sockets.all.count, socketsAtPause, "no socket opened while paused")

        apply(trigger.setPaused(false))
        waitUntil(self.call.running)
        XCTAssertTrue(mic.running)
        XCTAssertEqual(sockets.open.count, 2, "Resume opens fresh sockets")
        let fresh = sockets.open
        feed(mic: mic.handler, call: call.lastHandler, seconds: 2)
        waitUntil(fresh.contains { $0.appends > 0 })
        XCTAssertTrue(fresh.contains { $0.appends > 0 }, "streaming resumes after Resume")

        apply(trigger.manualStop())
        XCTAssertTrue(sockets.open.isEmpty)
        XCTAssertFalse(mic.running)
    }

    func testSwitchingOffClosesEverything() {
        apply(trigger.manualStart(now: 0))
        waitUntil(self.call.running)
        apply(trigger.setEnabled(false))
        XCTAssertFalse(mic.running)
        waitUntil(!self.call.running)
        XCTAssertFalse(call.running)
        XCTAssertTrue(sockets.open.isEmpty)
    }

    /// Generated voiced audio (harmonic series with a syllable envelope); no recordings.
    static func speechish(_ dur: Double, f0: Double = 130) -> [Float] {
        let sr = 24000.0
        let n = Int(dur * sr)
        var x = [Float](repeating: 0, count: n)
        for i in 0..<n {
            let t = Double(i) / sr
            var s = 0.0
            for k in 1...12 { s += sin(2 * .pi * f0 * Double(k) * t + Double(k)) / Double(k) }
            x[i] = Float(0.1 * s * (0.5 + 0.5 * sin(2 * .pi * 4 * t)))
        }
        return x
    }
}
