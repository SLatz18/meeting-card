import AppKit
import XCTest
@testable import ListenMoreCore
@testable import ListenMoreMac

/// The Mac service wired with a fake audio-state provider and fake capture: off means no polling
/// and no capture; auto-start after the debounce; Pause, Stop and skip-this-call stop or prevent capture.
@MainActor
final class CoachServiceTests: XCTestCase {
    final class FakeProvider: AudioStateProvider {
        var snap = AudioStateSnapshot(defaultInputRunning: false, processes: [])
        var reads = 0
        func snapshot() -> AudioStateSnapshot { reads += 1; return snap }
    }

    final class FakeMic: MicSource {
        var running = false
        var starts = 0
        func start(sampleRate: Int, handler: @escaping @Sendable ([Float]) -> Void) throws { running = true; starts += 1 }
        func stop() { running = false }
    }

    final class FakeCall: CallSource, @unchecked Sendable {
        func start(bundleIds: [String], stage: CaptureStage, sampleRate: Int,
                   handler: @escaping @Sendable ([Float]) -> Void) async throws {}
        func stop() async {}
    }

    struct NoKey: APIKeyProvider {
        func readKey() throws -> APIKey? { nil }
    }

    var provider: FakeProvider!
    var mic: FakeMic!

    override func setUp() async throws {
        _ = NSApplication.shared
        provider = FakeProvider()
        mic = FakeMic()
    }

    func service(enabled: Bool) -> CoachService {
        let glow = GlowOverlayController(style: testGlowStyle, screenFrames: { [NSRect(x: 0, y: 0, width: 400, height: 300)] })
        return CoachService(config: try! .builtIn(), glowStyle: testGlowStyle, enabled: enabled, anyApp: false,
                            ownBundleId: "com.example.hostapp", keys: NoKey(), provider: provider,
                            mic: mic, call: FakeCall(), engine: LocalCoachEngine(), glow: glow)
    }

    let zoom = AudioStateSnapshot(defaultInputRunning: true, processes: [
        AudioProcessState(pid: 77, bundleId: "us.zoom.xos", isRunningInput: true, isRunningOutput: true)])

    func testOffByDefaultNeverReadsOrCaptures() {
        let s = service(enabled: false)
        XCTAssertEqual(s.state, .off)
        s.start()
        XCTAssertFalse(mic.running)
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        XCTAssertEqual(provider.reads, 0, "no polling while off")
    }

    func testCallAppStartsAfterDebounceAndPauseStopsCapture() {
        let s = service(enabled: true)
        provider.snap = zoom
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        XCTAssertEqual(s.state, .idle, "still debouncing")
        XCTAssertEqual(s.indicator, .on)
        XCTAssertFalse(mic.running)
        RunLoop.main.run(until: Date().addingTimeInterval(3))
        XCTAssertEqual(s.state, .active(paused: false))
        XCTAssertTrue(mic.running)
        s.pause()
        XCTAssertEqual(s.state, .active(paused: true))
        XCTAssertFalse(mic.running)
        XCTAssertFalse(s.isCapturing)
        s.resume()
        XCTAssertTrue(mic.running)
        s.stop()
        XCTAssertEqual(s.state, .idle)
        XCTAssertFalse(mic.running)
        s.setEnabled(false)
        XCTAssertEqual(s.state, .off)
    }

    func testChipControlSkipsThisCallWhilePrewarmed() {
        let s = service(enabled: true)
        provider.snap = zoom
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        XCTAssertEqual(s.indicator, .on)
        s.chipControl()
        XCTAssertEqual(s.indicator, .hidden)
        RunLoop.main.run(until: Date().addingTimeInterval(3.5))
        XCTAssertEqual(s.state, .idle, "the skipped call never starts")
        XCTAssertEqual(mic.starts, 0)
    }

    func testDisablingStopsCapture() {
        let s = service(enabled: true)
        s.start()
        XCTAssertTrue(mic.running)
        s.setEnabled(false)
        XCTAssertFalse(mic.running)
    }

    func testSelfAndExcludedNeverTrigger() {
        let s = service(enabled: true)
        s.setAnyApp(true)
        provider.snap = AudioStateSnapshot(defaultInputRunning: true, processes: [
            AudioProcessState(pid: getpid(), bundleId: "com.example.whatever", isRunningInput: true, isRunningOutput: true),
            AudioProcessState(pid: 9, bundleId: "com.example.hostapp", isRunningInput: true, isRunningOutput: true),
            AudioProcessState(pid: 10, bundleId: "com.listenmore.mac", isRunningInput: true, isRunningOutput: true)])
        RunLoop.main.run(until: Date().addingTimeInterval(4.2))
        XCTAssertEqual(s.state, .idle)
        XCTAssertEqual(mic.starts, 0)
    }

    func testHostExclusionsAreInjectable() {
        let glow = GlowOverlayController(style: testGlowStyle, screenFrames: { [NSRect(x: 0, y: 0, width: 400, height: 300)] })
        let s = CoachService(config: try! .builtIn(), glowStyle: testGlowStyle, enabled: true, anyApp: false,
                             ownBundleId: "com.example.hostapp", excludedBundleIds: ["us.zoom.xos"], keys: NoKey(),
                             provider: provider, mic: mic, call: FakeCall(), engine: LocalCoachEngine(), glow: glow)
        provider.snap = zoom
        RunLoop.main.run(until: Date().addingTimeInterval(4.2))
        XCTAssertEqual(s.state, .idle)
        XCTAssertTrue(s.session.trigger.settings.excludedBundleIds.contains("com.example.hostapp"))
    }

    func testIndicatorFollowsPrewarmRunAndPause() {
        let s = service(enabled: true)
        XCTAssertEqual(s.indicator, .hidden)
        s.joinHint(endsAt: Date().addingTimeInterval(600))
        XCTAssertEqual(s.indicator, .on, "Join pre-warms; nothing is captured yet")
        XCTAssertFalse(mic.running)
        s.start()
        XCTAssertEqual(s.indicator, .listening)
        s.chipControl()
        XCTAssertEqual(s.indicator, .paused)
        s.chipControl()
        XCTAssertEqual(s.indicator, .listening)
        s.setEnabled(false)
        XCTAssertEqual(s.indicator, .hidden)
    }

    func testGlowGoesToTheCallDisplayBehindTheHostWindow() {
        let s = service(enabled: true)
        var asked: (String?, NSRect?)?
        let callScreen = NSRect(x: 1440, y: 0, width: 1920, height: 1080)
        let cardScreen = NSRect(x: 0, y: 0, width: 1440, height: 900)
        s.locateScreen = { app, fallback in asked = (app, fallback); return callScreen }
        s.fallbackScreen = { cardScreen }
        s.hostWindowNumber = { 0 }
        provider.snap = zoom
        RunLoop.main.run(until: Date().addingTimeInterval(4.2))
        XCTAssertEqual(s.state, .active(paused: false))
        s.session.deliverForTesting(CueSuggestion(type: .interrupt, t: 10, onset: 9.7, source: .local))
        XCTAssertEqual(asked?.0, "us.zoom.xos")
        XCTAssertEqual(asked?.1, cardScreen)
        XCTAssertEqual(s.cuesShown, 1)
        s.glow.hideAll()
        s.stop()
    }

    func testEditedAllowlistReplacesDefaults() {
        let s = service(enabled: true)
        s.setAllowlist(["com.example.callapp"])
        provider.snap = zoom
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
