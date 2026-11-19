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
        func setMuted(_ muted: Bool) -> Bool { true }
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

    func service(enabled: Bool, callWindows: CallWindowTracker? = nil, callState: CallStateProvider? = nil) -> CoachService {
        let glow = GlowOverlayController(style: testGlowStyle, screenFrames: { [NSRect(x: 0, y: 0, width: 400, height: 300)] })
        return CoachService(config: try! .builtIn(), glowStyle: testGlowStyle, enabled: enabled, anyApp: false,
                            ownBundleId: "com.example.hostapp", keys: NoKey(), provider: provider, callState: callState,
                            mic: mic, call: FakeCall(), engine: LocalCoachEngine(), glow: glow, callWindows: callWindows)
    }

    /// A fake window list for the call window tracker, recording which apps were asked for.
    final class FakeWindows {
        var windows: [AppWindow] = []
        var asked: [Set<String>] = []
        func read(_ keys: Set<String>) -> [AppWindow] {
            asked.append(keys)
            return windows.filter { w in w.bundleId.map { id in keys.contains { BundleIds.belongs(id, to: $0) } } == true }
        }
    }

    final class FakeMeetRunner: AppleScriptRunner {
        var raw = 0
        func permission(bundleId: String) -> AutomationPermission { .granted }
        func run(_ source: String, bundleId: String) -> ScriptOutcome { .count(raw) }
    }

    static let homeWindow = AppWindow(id: 1, bundleId: "us.zoom.xos", layer: 0, onScreen: true,
                                      bounds: CGRect(x: 0, y: 0, width: 1400, height: 880))
    static let meetingWindow = AppWindow(id: 2, bundleId: "us.zoom.xos", layer: 0, onScreen: true,
                                         bounds: CGRect(x: 1600, y: 100, width: 1000, height: 700))
    static let cardScreen = NSRect(x: 0, y: 0, width: 1440, height: 900)
    static let callScreen = NSRect(x: 1440, y: 0, width: 1920, height: 1080)

    /// A Zoom session on a service whose window list is `fake`, two displays, the card on the first.
    func activeZoomService(_ fake: FakeWindows) -> CoachService {
        let s = service(enabled: true, callWindows: CallWindowTracker(lookbackS: 60, windowSource: fake.read))
        s.screenFrames = { [Self.cardScreen, Self.callScreen] }
        s.fallbackScreen = { Self.cardScreen }
        s.hostWindowNumber = { 0 }
        provider.snap = zoom
        RunLoop.main.run(until: Date().addingTimeInterval(4.2))
        XCTAssertEqual(s.state, .active(paused: false))
        return s
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

    func testCallStartAndEndReachTheHostOncePerSession() {
        let s = service(enabled: true)
        var events: [String] = []
        s.onCallStart = { events.append("start") }
        s.onCallEnd = { events.append("end") }
        s.start()
        s.pause()
        s.resume()
        XCTAssertEqual(events, ["start"], "pause and resume stay in the same call")
        s.stop()
        XCTAssertEqual(events, ["start", "end"])
        s.start()
        s.setEnabled(false)
        XCTAssertEqual(events, ["start", "end", "start", "end"])
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
        var cues: [CueType] = []
        s.onCue = { cues.append($0.type) }
        XCTAssertNil(s.glowScreen, "no cue yet: the call's display isn't known")
        s.session.deliverForTesting(CueSuggestion(type: .interrupt, t: 10, onset: 9.7, source: .local))
        XCTAssertEqual(asked?.0, "us.zoom.xos")
        XCTAssertEqual(asked?.1, cardScreen)
        XCTAssertEqual(s.cuesShown, 1)
        XCTAssertEqual(cues, [.interrupt], "the host hears about each cue shown")
        XCTAssertEqual(s.glowScreen, callScreen, "the coach card can follow the glow's display without reading windows")
        s.glow.hideAll()
        s.stopForThisCall()
        XCTAssertNil(s.glowScreen, "forgotten with the session")
        XCTAssertEqual(s.indicator, .hidden)
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

    // MARK: the call's window, from the tracker to the glow's display

    func testGlowScreenFollowsTheMeetingWindowNotTheHomeWindow() {
        let fake = FakeWindows()
        fake.windows = [Self.homeWindow]                      // open before the coach watched: unknown age
        let s = activeZoomService(fake)
        fake.windows = [Self.homeWindow, Self.meetingWindow]  // the meeting window opens during the call
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        XCTAssertEqual(s.callWindows?.target(appKey: "us.zoom.xos"), Self.meetingWindow.bounds)
        s.session.deliverForTesting(CueSuggestion(type: .interrupt, t: 10, onset: 9.7, source: .local))
        XCTAssertEqual(s.glowScreen, Self.callScreen, "the meeting window's display, from the tracker through locateScreen")
        s.glow.hideAll()
        s.stopForThisCall()
    }

    func testGlowScreenIsTheCardsDisplayWhenOnlyTheHomeWindowIsOpen() {
        let fake = FakeWindows()
        fake.windows = [Self.homeWindow]
        let s = activeZoomService(fake)
        XCTAssertNil(s.callWindows?.target(appKey: "us.zoom.xos"))
        s.session.deliverForTesting(CueSuggestion(type: .interrupt, t: 10, onset: 9.7, source: .local))
        XCTAssertEqual(s.glowScreen, Self.cardScreen, "never the home window's display")
        s.glow.hideAll()
        s.stopForThisCall()
    }

    /// `CoachService.init` feeds the tracker on every poll: the watched apps (the allowlist plus the
    /// session's), the browser keys, and the call controls' window hints.
    func testEachPollFeedsTheTrackerTheWatchedAppsBrowserKeysAndHints() throws {
        let fake = FakeWindows()
        let runner = FakeMeetRunner()
        let controls = CallControlsProvider(readers: [MeetTabReader.chrome(runner: runner, windowHints: true)], endedHoldS: 30)
        controls.isEnabled = true
        let s = service(enabled: true, callWindows: CallWindowTracker(lookbackS: 60, windowSource: fake.read), callState: controls)

        s.session.tick()
        let first = try XCTUnwrap(fake.asked.last)
        XCTAssertTrue(first.contains("us.zoom.xos"), "Zoom is watched on every poll")
        XCTAssertFalse(first.contains("com.google.chrome") || first.contains("company.thebrowser.dia"),
                       "browsers with no Meet hint cost no window-list read")
        XCTAssertEqual(first, Set(["us.zoom.xos"]), "with no session only Zoom is read: Slack, Teams, FaceTime and Webex are not")

        let chromeWindow = AppWindow(id: 7, bundleId: "com.google.Chrome", layer: 0, onScreen: true,
                                     bounds: CGRect(x: 100, y: 100, width: 800, height: 600))
        fake.windows = [chromeWindow]
        runner.raw = 1 + 1000 * 1 + 1_000_000 * 1               // one meeting tab, in the front of one visible window
        s.session.tick()
        XCTAssertTrue(try XCTUnwrap(fake.asked.last).contains("com.google.chrome"), "the hint puts Chrome in the read")
        XCTAssertFalse(try XCTUnwrap(fake.asked.last).contains("company.thebrowser.dia"))
        XCTAssertEqual(s.callWindows?.target(appKey: "com.google.chrome"), chromeWindow.bounds, "bound from the hint")

        runner.raw = 0
        s.session.tick()
        XCTAssertFalse(try XCTUnwrap(fake.asked.last).contains("com.google.chrome"), "no hint: Chrome is dropped again")
        XCTAssertNil(s.callWindows?.target(appKey: "com.google.chrome"))
        s.setEnabled(false)
    }

    func testANonZoomNativeAppIsReadOnlyWhileItsSessionIsActive() {
        let slack = "com.tinyspeck.slackmacgap"
        let fake = FakeWindows()
        let s = service(enabled: true, callWindows: CallWindowTracker(lookbackS: 60, windowSource: fake.read))
        RunLoop.main.run(until: Date().addingTimeInterval(1.2))
        XCTAssertFalse(fake.asked.isEmpty)
        XCTAssertFalse(fake.asked.contains { $0.contains(slack) }, "Slack with no session: no window read")
        provider.snap = AudioStateSnapshot(defaultInputRunning: true, processes: [
            AudioProcessState(pid: 78, bundleId: slack, isRunningInput: true, isRunningOutput: true)])
        RunLoop.main.run(until: Date().addingTimeInterval(4.2))
        XCTAssertEqual(s.state, .active(paused: false))
        XCTAssertEqual(s.session.session?.appKey, slack)
        fake.asked.removeAll()
        s.session.tick()
        XCTAssertEqual(fake.asked.last, Set(["us.zoom.xos", slack]), "Slack with an active session is read")
        s.setEnabled(false)
    }

    // MARK: flag off: no tracker, main's behavior

    /// Without a tracker (the `callWindowBinding` flag off) the service tracks nothing and reads no
    /// window list per poll: no tick hook, and the glow's display is still the largest-window rule.
    func testWithoutATrackerTheServiceTracksNothing() {
        let off = service(enabled: false)
        XCTAssertNil(off.callWindows)
        XCTAssertNil(off.session.onTick, "no per-poll window read")
        let on = service(enabled: false, callWindows: CallWindowTracker(lookbackS: 60, windowSource: { _ in [] }))
        XCTAssertNotNil(on.callWindows)
        XCTAssertNotNil(on.session.onTick)
    }

    /// Flag off: with no session app and nothing on screen, the glow's display is the card's, as on main.
    func testWithoutATrackerTheGlowUsesTheLargestWindowRule() {
        let s = service(enabled: false)
        let fallback = Self.cardScreen
        XCTAssertEqual(s.locateScreen(nil, fallback), fallback)
        XCTAssertEqual(s.locateScreen("com.example.notrunning", fallback), fallback)
    }
}
