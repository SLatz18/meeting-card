import XCTest
@testable import ListenMoreCore

final class DetectionDiagnosticsTests: XCTestCase {
    var config: ListenMoreConfig!

    override func setUpWithError() throws { config = try TestConfig.load() }

    func settings(anyApp: Bool = false, excluded: [String] = []) -> TriggerSettings {
        var s = TriggerSettings(config: config, anyApp: anyApp, ownPid: 1, ownBundleId: "com.example.hostapp", excludedBundleIds: excluded)
        s.startAfterS = 3
        return s
    }

    func proc(_ pid: Int32, _ id: String?, input: Bool, output: Bool, owner: String? = nil) -> AudioProcessState {
        AudioProcessState(pid: pid, bundleId: id, owningBundleId: owner, isRunningInput: input, isRunningOutput: output)
    }

    func evaluate(_ processes: [AudioProcessState], inputRunning: Bool = true, anyApp: Bool = false, enabled: Bool = true,
                  inSession: Bool = false, suppressed: Set<String> = [], timers: [String: Double] = [:], started: Bool = false,
                  permission: PermissionSummary = .unknown) -> DetectionCheck {
        DetectionDiagnostics.evaluate(snapshot: AudioStateSnapshot(defaultInputRunning: inputRunning, processes: processes),
                                      settings: settings(anyApp: anyApp), enabled: enabled, inSession: inSession,
                                      suppressed: suppressed, startTimers: timers, started: started, permission: permission)
    }

    func line(_ c: DetectionCheck) -> String { CoachLogEvent.detectCheck(c).rendered }

    let zoom = "us.zoom.xos"

    func testCoachDisabled() {
        XCTAssertEqual(line(evaluate([proc(50, zoom, input: true, output: true)], enabled: false)),
                       "detect.check micApp=us.zoom.xos callAudio=true result=notMet reason=coachDisabled perm=unknown")
    }

    func testAlreadyInASession() {
        let c = evaluate([proc(50, zoom, input: true, output: true)], inSession: true)
        XCTAssertEqual(c.reason, .inSession)
        XCTAssertEqual(c.result, .notMet)
    }

    func testStartTimerRunsThenIsMet() {
        let p = [proc(50, zoom, input: true, output: true)]
        let early = evaluate(p, timers: [zoom: 0])
        XCTAssertEqual(line(early), "detect.check micApp=us.zoom.xos callAudio=true result=notMet reason=startTimer timerS=0 perm=unknown")
        XCTAssertEqual(evaluate(p, timers: [zoom: 2.9]).timerSeconds, 2)
        XCTAssertEqual(evaluate(p, timers: [zoom: 2.9]).result, .notMet)
        let met = evaluate(p, timers: [zoom: 3])
        XCTAssertEqual(line(met), "detect.check micApp=us.zoom.xos callAudio=true result=met reason=startTimer timerS=3 perm=unknown")
    }

    func testStartedOnThisCheck() {
        let c = evaluate([proc(50, zoom, input: true, output: true)], timers: [zoom: 3.2], started: true)
        XCTAssertEqual(line(c), "detect.check micApp=us.zoom.xos callAudio=true result=met reason=started timerS=3 perm=unknown")
    }

    func testInputDeviceIdle() {
        XCTAssertEqual(evaluate([], inputRunning: false).reason, .inputDeviceIdle)
        XCTAssertEqual(evaluate([proc(50, zoom, input: false, output: true)], inputRunning: false).reason, .inputDeviceIdle)
    }

    func testInputRunningButNoProcessesListed() {
        XCTAssertEqual(line(evaluate([])), "detect.check micApp=none callAudio=false result=notMet reason=noProcesses perm=unknown")
    }

    func testNoProcessHoldsTheMic() {
        let c = evaluate([proc(50, zoom, input: false, output: true)])
        XCTAssertEqual(c.reason, .noMicHolder)
        XCTAssertNil(c.micApp)
    }

    func testAllowedAppWithMicButNoAudio() {
        let c = evaluate([proc(50, zoom, input: true, output: false)])
        XCTAssertEqual(c.reason, .noCallAudio)
        XCTAssertFalse(c.callAudio)
        XCTAssertEqual(c.micApp?.value, zoom)
    }

    func testMicHeldByAnAppNotOnTheAllowList() {
        let p = [proc(60, "com.example.recorder", input: true, output: true)]
        let c = evaluate(p)
        XCTAssertEqual(line(c), "detect.check micApp=com.example.recorder callAudio=true result=notMet reason=appNotAllowed perm=unknown")
        let anyApp = evaluate(p, anyApp: true, timers: ["com.example.recorder": 1])
        XCTAssertEqual(anyApp.reason, .startTimer, "with any app on, the same app is a candidate")
    }

    func testExcludedApp() {
        let c = evaluate([proc(60, "com.example.hostapp", input: true, output: true)])
        XCTAssertEqual(c.reason, .appExcluded)
        XCTAssertEqual(c.micApp?.value, "com.example.hostapp")
    }

    func testOwnProcessIsNotAMicHolder() {
        XCTAssertEqual(evaluate([proc(1, zoom, input: true, output: true)]).reason, .noMicHolder)
    }

    func testProcessWithNoBundleIdIsUnidentified() {
        let c = evaluate([proc(70, nil, input: true, output: true)])
        XCTAssertEqual(line(c), "detect.check micApp=unidentified callAudio=true result=notMet reason=unidentifiedProcess perm=unknown")
    }

    func testSuppressedAppWaitsForItsAudioToStop() {
        let c = evaluate([proc(50, zoom, input: true, output: true)], suppressed: [zoom], timers: [zoom: 40])
        XCTAssertEqual(c.reason, .suppressed)
        XCTAssertEqual(c.result, .notMet)
    }

    /// A helper process holding the audio groups with its app.
    func testHelperProcessesGroupWithTheirApp() {
        let p = [proc(50, "com.google.Chrome", input: true, output: false),
                 proc(51, "com.google.Chrome.helper.renderer", input: false, output: true)]
        let c = evaluate(p, timers: ["com.google.chrome": 1])
        XCTAssertEqual(c.reason, .startTimer)
        XCTAssertEqual(c.micApp?.value, "com.google.chrome")
        XCTAssertTrue(c.callAudio)
    }

    func testPermissionRidesAlongWithoutChangingTheDecision() {
        let p = [proc(50, zoom, input: true, output: true)]
        let granted = evaluate(p, timers: [zoom: 1], permission: .granted)
        let denied = evaluate(p, timers: [zoom: 1], permission: .notGranted)
        XCTAssertEqual(granted.reason, denied.reason)
        XCTAssertEqual(granted.result, denied.result)
        XCTAssertTrue(line(denied).hasSuffix("perm=notGranted"))
    }

    func testEveryLineIsNamedTokensOnly() {
        let cases: [DetectionCheck] = [
            evaluate([proc(70, "Some App With Spaces, and \"quotes\"", input: true, output: true)]),
            evaluate([proc(70, nil, input: true, output: false)]),
            evaluate([]),
        ]
        for c in cases {
            XCTAssertNotNil(line(c).range(of: #"^detect\.check( [A-Za-z]+=[A-Za-z0-9._:/()+-]+)+$"#, options: .regularExpression), line(c))
        }
    }

    // MARK: throttle

    func check(_ reason: DetectionReason = .noMicHolder, timer: Int? = nil, app: String? = nil) -> DetectionCheck {
        DetectionCheck(micApp: app.map { LogToken($0) }, callAudio: false, result: .notMet, reason: reason, timerSeconds: timer)
    }

    func testFirstCheckIsLogged() {
        var t = DetectionLogThrottle()
        XCTAssertTrue(t.shouldLog(check(), now: 100))
    }

    func testRepeatsAreSilentUntilTheHeartbeat() {
        var t = DetectionLogThrottle()
        XCTAssertTrue(t.shouldLog(check(), now: 100))
        for s in 1..<10 { XCTAssertFalse(t.shouldLog(check(), now: 100 + Double(s)), "t+\(s)") }
        XCTAssertTrue(t.shouldLog(check(), now: 110), "one heartbeat line after ten seconds")
        XCTAssertFalse(t.shouldLog(check(), now: 111))
        XCTAssertFalse(t.shouldLog(check(), now: 119.9))
        XCTAssertTrue(t.shouldLog(check(), now: 120))
    }

    /// At most one line per ten seconds while nothing changes, however often it is polled.
    func testQuietStretchLogsAtMostOnceEveryTenSeconds() {
        var t = DetectionLogThrottle()
        var logged = 0
        for tick in 0..<(10 * 60 * 2) where t.shouldLog(check(), now: Double(tick) * 0.5) { logged += 1 }
        XCTAssertEqual(logged, 60, "ten minutes polled twice a second")
    }

    func testEveryChangeIsLoggedAtOnce() {
        var t = DetectionLogThrottle()
        XCTAssertTrue(t.shouldLog(check(.noMicHolder), now: 0))
        XCTAssertTrue(t.shouldLog(check(.noCallAudio, app: "us.zoom.xos"), now: 0.5), "a different reason")
        XCTAssertFalse(t.shouldLog(check(.noCallAudio, app: "us.zoom.xos"), now: 1))
        XCTAssertTrue(t.shouldLog(check(.noCallAudio, app: "us.zoom.xos").with(callAudio: true), now: 1.5), "audio started")
        XCTAssertTrue(t.shouldLog(check(.noCallAudio, app: "com.google.chrome").with(callAudio: true), now: 2), "another app holds the mic")
        XCTAssertTrue(t.shouldLog(DetectionCheck(micApp: nil, callAudio: false, result: .met, reason: .noMicHolder), now: 2.5), "result changed")
    }

    /// A running timer's seconds change every check but are not a state change.
    func testTimerSecondsAloneAreNotAChange() {
        var t = DetectionLogThrottle()
        XCTAssertTrue(t.shouldLog(check(.startTimer, timer: 0, app: "us.zoom.xos"), now: 0))
        XCTAssertFalse(t.shouldLog(check(.startTimer, timer: 1, app: "us.zoom.xos"), now: 1))
        XCTAssertFalse(t.shouldLog(check(.startTimer, timer: 2, app: "us.zoom.xos"), now: 2))
    }

    func testPermissionChangeIsLogged() {
        var t = DetectionLogThrottle()
        XCTAssertTrue(t.shouldLog(check(), now: 0))
        var denied = check()
        denied.permission = .notGranted
        XCTAssertTrue(t.shouldLog(denied, now: 1))
    }

    func testResetLogsTheNextCheck() {
        var t = DetectionLogThrottle()
        XCTAssertTrue(t.shouldLog(check(), now: 0))
        t.reset()
        XCTAssertTrue(t.shouldLog(check(), now: 1))
    }
}

private extension DetectionCheck {
    func with(callAudio: Bool) -> DetectionCheck {
        var c = self
        c.callAudio = callAudio
        return c
    }
}
