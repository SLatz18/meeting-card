import XCTest
@testable import ListenMoreCore

/// State machine for the auto-on trigger, driven through `CoachMonitor` with a fake provider.
final class CoachTriggerTests: XCTestCase {
    final class FakeAudioState: AudioStateProvider {
        var inputRunning = true
        var processes: [AudioProcessState] = []
        func snapshot() -> AudioStateSnapshot { AudioStateSnapshot(defaultInputRunning: inputRunning, processes: processes) }

        func set(_ ps: AudioProcessState...) { processes = ps }
    }

    static let ownPid: Int32 = 4242

    static func proc(_ bundle: String?, pid: Int32 = 100, owner: String? = nil, input: Bool = true, output: Bool = true) -> AudioProcessState {
        AudioProcessState(pid: pid, bundleId: bundle, owningBundleId: owner, isRunningInput: input, isRunningOutput: output)
    }

    var config: ListenMoreConfig!
    var audio: FakeAudioState!
    var monitor: CoachMonitor!

    override func setUpWithError() throws {
        config = try TestConfig.load()
        audio = FakeAudioState()
        monitor = makeMonitor(anyApp: false)
    }

    func makeMonitor(anyApp: Bool, enabled: Bool = true) -> CoachMonitor {
        let s = TriggerSettings(config: config, anyApp: anyApp, ownPid: Self.ownPid, ownBundleId: "com.example.hostapp")
        return CoachMonitor(provider: audio, trigger: CoachTrigger(settings: s, enabled: enabled))
    }

    /// Polls every 0.5 s from `from` to `to` (inclusive); returns (time, action) pairs.
    @discardableResult
    func run(_ from: Double, _ to: Double) -> [(Double, TriggerAction)] {
        var out: [(Double, TriggerAction)] = []
        var t = from
        while t <= to + 1e-9 {
            out += monitor.poll(now: t).map { (t, $0) }
            t += 0.5
        }
        return out
    }

    func starts(_ a: [(Double, TriggerAction)]) -> [(Double, TriggerSession)] {
        a.compactMap { if case .start(let s) = $0.1 { return ($0.0, s) } else { return nil } }
    }

    func stops(_ a: [(Double, TriggerAction)]) -> [(Double, CoachStopReason)] {
        a.compactMap { if case .stop(let r) = $0.1 { return ($0.0, r) } else { return nil } }
    }

    // MARK: debounce

    func testStartsAfterThreeSecondsOfInputAndOutput() throws {
        audio.set(Self.proc("us.zoom.xos"))
        let a = run(0, 5)
        let s = try XCTUnwrap(starts(a).first)
        XCTAssertEqual(s.0, 3.0, accuracy: 1e-9)
        XCTAssertEqual(s.1.appKey, "us.zoom.xos")
        XCTAssertEqual(s.1.reason, .audio)
        XCTAssertEqual(starts(a).count, 1)
    }

    func testShortClipOrDictationDoesNotStart() {
        audio.set(Self.proc("us.zoom.xos"))
        run(0, 2.5)                                  // 2.5 s of in+out ...
        audio.set(Self.proc("us.zoom.xos", output: false))
        run(3, 3)                                     // ... interrupted ...
        audio.set(Self.proc("us.zoom.xos"))
        XCTAssertTrue(starts(run(3.5, 6)).isEmpty, "the 3 s window restarts after a gap")
        XCTAssertEqual(starts(run(6.5, 6.5)).first?.0, 6.5)
    }

    func testInputOnlyOrOutputOnlyNeverStarts() {
        audio.set(Self.proc("us.zoom.xos", output: false))
        XCTAssertTrue(starts(run(0, 10)).isEmpty)
        audio.set(Self.proc("us.zoom.xos", input: false))
        XCTAssertTrue(starts(run(10.5, 20)).isEmpty)
    }

    func testDefaultInputDeviceMustBeRunningToStart() {
        audio.inputRunning = false
        audio.set(Self.proc("us.zoom.xos"))
        XCTAssertTrue(starts(run(0, 10)).isEmpty)
        audio.inputRunning = true
        XCTAssertEqual(starts(run(10.5, 14)).first?.0, 13.5)
    }

    // MARK: allowlist and any-app option

    func testNonAllowlistedAppIgnoredByDefault() {
        audio.set(Self.proc("com.example.voicememo"))
        XCTAssertTrue(starts(run(0, 10)).isEmpty)
    }

    func testAnyAppOptionCoachesOtherApps() throws {
        monitor = makeMonitor(anyApp: true)
        audio.set(Self.proc("com.example.voicememo"))
        XCTAssertEqual(try XCTUnwrap(starts(run(0, 4)).first).1.appKey, "com.example.voicememo")
    }

    func testDefaultAllowlistCoversCallApps() {
        for bundle in ["us.zoom.xos", "com.google.Chrome", "company.thebrowser.dia", "com.microsoft.teams2",
                       "Cisco-Systems.Spark", "com.apple.FaceTime", "com.tinyspeck.slackmacgap"] {
            audio = FakeAudioState()
            monitor = makeMonitor(anyApp: false)
            audio.set(Self.proc(bundle))
            XCTAssertEqual(starts(run(0, 4)).first?.1.appKey, bundle.lowercased(), bundle)
        }
    }

    func testDisabledNeverStarts() {
        monitor = makeMonitor(anyApp: true, enabled: false)
        audio.set(Self.proc("us.zoom.xos"))
        XCTAssertTrue(run(0, 10).isEmpty)
        XCTAssertTrue(monitor.trigger.manualStart(now: 11).isEmpty, "manual start also needs the opt-in")
    }

    // MARK: self-exclusion

    func testNeverTriggersOnSelfOrListenMore() {
        monitor = makeMonitor(anyApp: true)
        audio.set(Self.proc("com.example.hostapp", pid: 1),
                  Self.proc("com.listenmore.mac", pid: 2),
                  Self.proc("com.listenmore.mac.helper", pid: 3),
                  Self.proc(nil, pid: Self.ownPid))
        XCTAssertTrue(starts(run(0, 10)).isEmpty)
    }

    func testOwnPidExcludedEvenWithAllowlistedBundle() {
        audio.set(Self.proc("us.zoom.xos", pid: Self.ownPid))
        XCTAssertTrue(starts(run(0, 10)).isEmpty)
    }

    func testOwnCaptureDoesNotKeepSessionAlive() {
        audio.set(Self.proc("us.zoom.xos"))
        run(0, 3)
        // The call ends, but our own mic capture keeps the input device running.
        audio.set(Self.proc("com.example.hostapp", pid: Self.ownPid))
        XCTAssertEqual(stops(run(3.5, 40)).first?.1, .audioEnded)
    }

    // MARK: helper-to-bundle grouping

    func testHelperProcessesGroupWithTheirApp() throws {
        // Chrome: mic in one helper, playback in another; neither alone has both.
        audio.set(Self.proc("com.google.Chrome.helper", pid: 10, input: true, output: false),
                  Self.proc("com.google.Chrome.helper.renderer", pid: 11, input: false, output: true))
        XCTAssertEqual(try XCTUnwrap(starts(run(0, 4)).first).1.appKey, "com.google.chrome")
    }

    func testHelperWithoutBundleGroupsByOwner() throws {
        audio.set(Self.proc(nil, pid: 10, owner: "company.thebrowser.dia", input: true, output: false),
                  Self.proc("company.thebrowser.dia", pid: 11, input: false, output: true))
        XCTAssertEqual(try XCTUnwrap(starts(run(0, 4)).first).1.appKey, "company.thebrowser.dia")
    }

    func testDifferentAppsDoNotCombine() {
        monitor = makeMonitor(anyApp: true)
        audio.set(Self.proc("us.zoom.xos", pid: 1, input: true, output: false),
                  Self.proc("com.apple.Music", pid: 2, input: false, output: true))
        XCTAssertTrue(starts(run(0, 10)).isEmpty)
    }

    func testAnyAppGroupsHelpersBySuffix() throws {
        monitor = makeMonitor(anyApp: true)
        audio.set(Self.proc("com.example.call.helper", pid: 1, input: true, output: false),
                  Self.proc("com.example.call.helper.Renderer", pid: 2, input: false, output: true))
        XCTAssertEqual(try XCTUnwrap(starts(run(0, 4)).first).1.appKey, "com.example.call")
    }

    // MARK: stop timing

    func testStopsThirtySecondsAfterOutputGoesOff() throws {
        audio.set(Self.proc("us.zoom.xos"))
        run(0, 10)
        audio.set(Self.proc("us.zoom.xos", output: false))
        let a = run(10.5, 50)
        let stop = try XCTUnwrap(stops(a).first)
        XCTAssertEqual(stop.0, 40.5, accuracy: 1e-9)
        XCTAssertEqual(stop.1, .audioEnded)
        XCTAssertFalse(monitor.trigger.isActive)
    }

    func testBriefSilenceDoesNotStop() {
        audio.set(Self.proc("us.zoom.xos"))
        run(0, 10)
        audio.set(Self.proc("us.zoom.xos", input: false))
        run(10.5, 35)                                   // 25 s with the mic off (muted)
        audio.set(Self.proc("us.zoom.xos"))
        XCTAssertTrue(stops(run(35.5, 100)).isEmpty)
        XCTAssertTrue(monitor.trigger.isActive)
    }

    func testRestartsForTheNextCall() {
        audio.set(Self.proc("us.zoom.xos"))
        run(0, 5)
        audio.set()
        XCTAssertEqual(stops(run(5.5, 40)).count, 1)
        audio.set(Self.proc("us.zoom.xos"))
        XCTAssertEqual(starts(run(40.5, 45)).first?.0, 43.5)
    }

    func testStopsAtJoinedEventEndAndDoesNotRestartForSameCall() throws {
        audio.set(Self.proc("us.zoom.xos"))
        run(0, 5)
        monitor.trigger.joinHint(endsAt: 60, now: 5)
        XCTAssertEqual(monitor.trigger.session?.endsAt, 60)
        let a = run(5.5, 120)
        XCTAssertEqual(stops(a).map(\.1), [.eventEnded])
        XCTAssertEqual(try XCTUnwrap(stops(a).first).0, 60, accuracy: 1e-9)
        XCTAssertTrue(starts(a).isEmpty, "the call that outlived the event does not restart the coach")
        audio.set()
        run(120.5, 121)
        audio.set(Self.proc("us.zoom.xos"))
        XCTAssertEqual(starts(run(121.5, 125)).count, 1, "a new call starts it again")
    }

    func testJoinHintBeforeCallAppliesToNextSession() throws {
        monitor.trigger.joinHint(endsAt: 1800, now: 0)
        audio.set(Self.proc("us.zoom.xos"))
        XCTAssertEqual(try XCTUnwrap(starts(run(0, 4)).first).1.endsAt, 1800)
    }

    func testJoinHintAloneNeverStarts() {
        monitor.trigger.joinHint(endsAt: 1800, now: 0)
        XCTAssertTrue(run(0, 60).isEmpty)
    }

    func testDisablingStopsSession() {
        audio.set(Self.proc("us.zoom.xos"))
        run(0, 5)
        XCTAssertEqual(monitor.trigger.setEnabled(false), [.stop(.disabled)])
        XCTAssertTrue(run(5.5, 20).isEmpty)
    }

    // MARK: manual start, stop and pause

    func testManualStartWithoutCallAdoptsTheCallLater() {
        XCTAssertEqual(monitor.trigger.manualStart(now: 0).count, 1)
        XCTAssertNil(monitor.trigger.session?.appKey)
        XCTAssertTrue(stops(run(0, 60)).isEmpty, "a manual session with no call keeps running")
        audio.set(Self.proc("us.zoom.xos"))
        run(60.5, 65)
        XCTAssertEqual(monitor.trigger.session?.appKey, "us.zoom.xos")
        XCTAssertEqual(monitor.trigger.session?.reason, .manual)
        audio.set()
        XCTAssertEqual(stops(run(65.5, 100)).first?.1, .audioEnded)
    }

    func testManualStopSuppressesUntilCallEnds() {
        audio.set(Self.proc("us.zoom.xos"))
        run(0, 5)
        XCTAssertEqual(monitor.trigger.manualStop(), [.stop(.manual)])
        XCTAssertTrue(starts(run(5.5, 60)).isEmpty)
        audio.set()
        run(60.5, 61)
        audio.set(Self.proc("us.zoom.xos"))
        XCTAssertEqual(starts(run(61.5, 65)).count, 1)
    }

    func testPauseResume() {
        audio.set(Self.proc("us.zoom.xos"))
        run(0, 5)
        XCTAssertEqual(monitor.trigger.setPaused(true), [.pause(true)])
        XCTAssertFalse(monitor.trigger.isCapturing)
        XCTAssertTrue(monitor.trigger.isActive)
        XCTAssertEqual(monitor.trigger.setPaused(true), [])
        XCTAssertEqual(monitor.trigger.manualStart(now: 6), [.pause(false)], "Start while paused resumes")
        XCTAssertTrue(monitor.trigger.isCapturing)
    }

    func testPausedSessionStillEndsWithTheCall() {
        audio.set(Self.proc("us.zoom.xos"))
        run(0, 5)
        _ = monitor.trigger.setPaused(true)
        audio.set()
        XCTAssertEqual(stops(run(5.5, 40)).first?.1, .audioEnded)
    }
}
