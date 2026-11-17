import AppKit
import XCTest
import ListenMoreCore
@testable import ListenMoreMac

/// The Mac service wired with a fake audio-state provider and a fake capture: off by default means
/// no capture; auto-start after the debounce; Pause and Stop stop capture.
@MainActor
final class CoachServiceTests: XCTestCase {
    final class FakeProvider: AudioStateProvider {
        var snap = AudioStateSnapshot(defaultInputRunning: false, processes: [])
        var reads = 0
        func snapshot() -> AudioStateSnapshot { reads += 1; return snap }
    }

    final class FakeCapture: CoachCapture {
        var running = false
        var starts = 0
        func start(bundleIds: [String], onMic: @escaping ([Float]) -> Void, onCall: @escaping ([Float]) -> Void) {
            running = true
            starts += 1
        }
        func stop() { running = false }
    }

    var provider: FakeProvider!
    var capture: FakeCapture!

    override func setUp() {
        super.setUp()
        _ = NSApplication.shared
        provider = FakeProvider()
        capture = FakeCapture()
    }

    func service(enabled: Bool) -> CoachService {
        CoachService(config: try! .builtIn(), glowStyle: testGlowStyle, enabled: enabled, anyApp: false,
                     ownBundleId: "com.slatz.meetingcard.swift", provider: provider, capture: capture,
                     transport: nil, readKey: { nil })
    }

    func testOffByDefaultNeverReadsOrCaptures() {
        let s = service(enabled: false)
        XCTAssertEqual(s.state, .off)
        s.start()
        XCTAssertFalse(capture.running)
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        XCTAssertEqual(provider.reads, 0, "no polling while off")
    }

    func testCallAppStartsAfterDebounceAndPauseStopsCapture() {
        let s = service(enabled: true)
        provider.snap = AudioStateSnapshot(defaultInputRunning: true, processes: [
            AudioProcessState(pid: 77, bundleId: "us.zoom.xos", isRunningInput: true, isRunningOutput: true)])
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        XCTAssertEqual(s.state, .idle, "still debouncing")
        XCTAssertFalse(capture.running)
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        XCTAssertEqual(s.state, .active(paused: false))
        XCTAssertTrue(capture.running)
        s.pause()
        XCTAssertEqual(s.state, .active(paused: true))
        XCTAssertFalse(capture.running)
        XCTAssertFalse(s.isCapturing)
        s.resume()
        XCTAssertTrue(capture.running)
        s.stop()
        XCTAssertEqual(s.state, .idle)
        XCTAssertFalse(capture.running)
        s.setEnabled(false)
        XCTAssertEqual(s.state, .off)
    }

    func testDisablingStopsCapture() {
        let s = service(enabled: true)
        s.start()
        XCTAssertTrue(capture.running)
        s.setEnabled(false)
        XCTAssertFalse(capture.running)
    }

    func testSelfNeverTriggers() {
        let s = service(enabled: true)
        s.setAnyApp(true)
        provider.snap = AudioStateSnapshot(defaultInputRunning: true, processes: [
            AudioProcessState(pid: getpid(), bundleId: "com.example.whatever", isRunningInput: true, isRunningOutput: true),
            AudioProcessState(pid: 9, bundleId: "com.slatz.meetingcard.swift", isRunningInput: true, isRunningOutput: true)])
        RunLoop.main.run(until: Date().addingTimeInterval(4.2))
        XCTAssertEqual(s.state, .idle)
        XCTAssertEqual(capture.starts, 0)
    }

    func testIndicatorFollowsPrewarmRunAndPause() {
        let s = service(enabled: true)
        XCTAssertEqual(s.indicator, .hidden)
        s.joinHint(endsAt: Date().addingTimeInterval(600))
        XCTAssertEqual(s.indicator, .on, "Join pre-warms; nothing is captured yet")
        XCTAssertFalse(capture.running)
        s.start()
        XCTAssertEqual(s.indicator, .listening)
        s.pause()
        XCTAssertEqual(s.indicator, .paused)
        s.setEnabled(false)
        XCTAssertEqual(s.indicator, .hidden)
    }

    func testGlowGoesToTheCallDisplayBehindTheCard() {
        let s = service(enabled: true)
        var asked: (String?, NSRect?)?
        let callScreen = NSRect(x: 1440, y: 0, width: 1920, height: 1080)
        let cardScreen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        s.locateScreen = { app, fallback in asked = (app, fallback); return callScreen }
        s.fallbackScreen = { cardScreen }
        provider.snap = AudioStateSnapshot(defaultInputRunning: true, processes: [
            AudioProcessState(pid: 77, bundleId: "us.zoom.xos", isRunningInput: true, isRunningOutput: true)])
        RunLoop.main.run(until: Date().addingTimeInterval(4.2))
        XCTAssertEqual(s.state, .active(paused: false))
        (s as CoachEngineDelegate).engine(s.engine, didSuggest: CueSuggestion(type: .interrupt, t: 10, onset: 9.7, source: .local, confidence: nil))
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(asked?.0, "us.zoom.xos")
        XCTAssertEqual(asked?.1, cardScreen)
        XCTAssertEqual(s.cuesShown, 1)
        s.glow.hideAll()
        s.stop()
    }

    func testEditedAllowlistReplacesDefaults() {
        let s = service(enabled: true)
        s.setAllowlist(["com.example.callapp"])
        provider.snap = AudioStateSnapshot(defaultInputRunning: true, processes: [
            AudioProcessState(pid: 77, bundleId: "us.zoom.xos", isRunningInput: true, isRunningOutput: true)])
        RunLoop.main.run(until: Date().addingTimeInterval(4.2))
        XCTAssertEqual(s.state, .idle, "removed from the allowlist")
        provider.snap = AudioStateSnapshot(defaultInputRunning: true, processes: [
            AudioProcessState(pid: 78, bundleId: "com.example.callapp", isRunningInput: true, isRunningOutput: true)])
        RunLoop.main.run(until: Date().addingTimeInterval(4.2))
        XCTAssertEqual(s.state, .active(paused: false))
        s.stop()
    }

    func testCoreAudioProviderReadsWithoutCrashing() {
        let snap = CoreAudioStateProvider().snapshot()
        XCTAssertFalse(snap.processes.contains { $0.pid == getpid() && $0.isRunningInput }, "tests never open the mic")
    }
}
