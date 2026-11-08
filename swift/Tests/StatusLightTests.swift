import XCTest
@testable import MeetingCardCore

/// Fake sidepulse: records argv, can simulate the settings file following `configure`.
final class FakeSidepulse: CommandRunner, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var calls: [[String]] = []
    var display = "agent"
    var result: RunResult = .exited(status: 0, stdout: Data(), stderr: Data())
    var onCall: (([String]) -> Void)?
    var block: DispatchSemaphore?
    func run(executable: String, args: [String], env: [String: String], timeout: TimeInterval) -> RunResult {
        lock.lock(); calls.append(args); lock.unlock()
        onCall?(args)
        if let b = block { _ = b.wait(timeout: .now() + timeout) }
        if args.count == 4, args[0] == "battery", case .exited(0, _, _) = result { display = args[3] }
        return result
    }
}

/// Manual serial queue: jobs run only when drained.
final class ManualQueue {
    var jobs: [() -> Void] = []
    var delayed: [() -> Void] = []
    func enqueue(_ j: @escaping () -> Void) { jobs.append(j) }
    func drain() { while !jobs.isEmpty { jobs.removeFirst()() } }
    func fireDelayed() { let d = delayed; delayed = []; d.forEach { $0() } }
}

final class StatusLightRig {
    let q = ManualQueue()
    let sp = FakeSidepulse()
    let logs = LogBox()
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sl-\(UUID().uuidString)")
    var marker: URL { dir.appendingPathComponent("status-light.json") }
    var settings: Data? = nil
    var followRunner = false
    var led: String? = nil
    var cli: String? = "/fake/sidepulse"
    var device: String? = "/Volumes/PULSE"
    lazy var light = make()

    func make(enabled: Bool = true, program: String = StatusLight.defaultProgram) -> StatusLight {
        StatusLight(enabled: enabled, cli: { [unowned self] in cli }, device: { [unowned self] in device },
                    readSettings: { [unowned self] in
                        followRunner ? Data("{\"led_display\":\"\(sp.display)\"}".utf8) : settings },
                    readLED: { [unowned self] _ in led.map { Data($0.utf8) } },
                    markerURL: marker, program: program, runner: sp, env: [:],
                    enqueue: { [unowned self] in q.enqueue($0) },
                    after: { [unowned self] _, j in q.delayed.append(j) },
                    log: { [logs] in logs.add($0) })
    }
    func counts(_ ns: Int...) { ns.forEach { light.cardCount($0) }; q.drain() }
    var markerText: String? { try? String(contentsOf: marker, encoding: .utf8) }
}

final class StatusLightTests: XCTestCase {
    let on = [["battery", "configure", "--display", "custom"], ["write", "--device", "/Volumes/PULSE", "--", StatusLight.defaultProgram]]
    func off(_ d: String) -> [String] { ["battery", "configure", "--display", d] }

    // MARK: edges

    func testEdge0to1On_1to2Nothing_2to1Nothing_1to0Off() {
        let r = StatusLightRig()
        r.counts(1); XCTAssertEqual(r.sp.calls, on)
        r.counts(2, 1); XCTAssertEqual(r.sp.calls.count, 2)
        r.counts(0); XCTAssertEqual(r.sp.calls, on + [off("agent")])
    }

    func testStackedCardsOneOnOneOff() {
        let r = StatusLightRig()
        r.counts(0, 1, 2, 3, 2, 1, 0)
        XCTAssertEqual(r.sp.calls, on + [off("agent")])
    }

    /// C1: 1 -> 0 -> 1 queued before any job runs; the second On must read the prior after Off ran.
    func testFastCloseRefireReadsPriorAfterOff() {
        let r = StatusLightRig(); r.followRunner = true
        r.light.cardCount(1); r.light.cardCount(0); r.light.cardCount(1)
        r.q.drain()
        XCTAssertEqual(r.sp.calls, on + [off("agent")] + on, r.logs.lines.joined(separator: "\n"))
        r.counts(0)
        XCTAssertEqual(r.sp.calls.last, off("agent"))
        XCTAssertEqual(r.sp.display, "agent")
    }

    // MARK: prior

    func p(_ s: String?, dev: String = "/Volumes/PULSE") -> Result<StatusLight.Display, StatusLight.SkipReason> {
        StatusLight.prior(settingsData: s.map { Data($0.utf8) }, device: dev)
    }
    func testPriorDefaultsToAgent() {
        XCTAssertEqual(p(nil), .success(.agent))
        XCTAssertEqual(p("{nope"), .success(.agent))
        XCTAssertEqual(p("{}"), .success(.agent))
        XCTAssertEqual(p("{\"led_display\":\"rainbow\"}"), .success(.agent))
    }
    func testPriorBatteryRestoredAsBattery() {
        let r = StatusLightRig(); r.settings = Data("{\"led_display\":\"battery\"}".utf8)
        r.counts(1, 0)
        XCTAssertEqual(r.sp.calls.last, off("battery"))
        XCTAssertTrue(r.logs.lines.contains("status light on (prior=battery)"))
    }
    func testPriorCustomSkipsZeroCalls() {
        let r = StatusLightRig(); r.settings = Data("{\"led_display\":\"custom\"}".utf8)
        r.counts(1, 0)
        XCTAssertTrue(r.sp.calls.isEmpty); XCTAssertNil(r.markerText)
        XCTAssertTrue(r.logs.lines.contains { $0.hasPrefix("status light skipped:") })
    }
    func testPerDeviceEntrySkips() {
        XCTAssertEqual(p("{\"devices\":[{\"id\":\"/Volumes/PULSE\"}]}"), .failure(.perDevice))
        XCTAssertEqual(p("{\"devices\":[{\"path\":\"/Volumes/PULSE/\"}]}"), .failure(.perDevice))
        XCTAssertEqual(p("{\"devices\":[{\"id\":\"/Volumes/OTHER\"}]}"), .success(.agent))
        let r = StatusLightRig(); r.settings = Data("{\"devices\":[{\"path\":\"/Volumes/PULSE\"}]}".utf8)
        r.counts(1); XCTAssertTrue(r.sp.calls.isEmpty)
    }
    func testSettingsPath() {
        XCTAssertEqual(StatusLight.settingsPath(env: ["XDG_CONFIG_HOME": "/x"], home: "/h"), "/x/sidepulse/agent-monitor/settings.json")
        XCTAssertEqual(StatusLight.settingsPath(env: [:], home: "/h"), "/h/.config/sidepulse/agent-monitor/settings.json")
    }

    // MARK: argv

    func testOnArgvOrder() { let r = StatusLightRig(); r.counts(1); XCTAssertEqual(r.sp.calls, on) }
    func testOffArgvConfigureOnlyNoWrite() {
        let r = StatusLightRig(); r.counts(1, 0)
        XCTAssertEqual(Array(r.sp.calls.dropFirst(2)), [off("agent")])
    }
    func testWriteArgvHasDoubleDashForDashProgram() {
        let r = StatusLightRig(); r.light = r.make(program: "-x")
        r.counts(1)
        XCTAssertEqual(r.sp.calls.last, ["write", "--device", "/Volumes/PULSE", "--", "-x"])
    }
    func testArgvAllowlistRejectsOtherSubcommands() {
        for bad in [["setup"], ["link"], ["update"], ["battery", "status"], ["write"], ["agent-monitor", "x"],
                    ["service", "start"], ["battery", "configure", "--other", "x"]] {
            XCTAssertNil(StatusLight.checked(bad), "\(bad)")
        }
        XCTAssertNotNil(StatusLight.checked(["battery", "configure", "--display", "agent"]))
        XCTAssertNotNil(StatusLight.checked(["write", "--device", "/V", "--", "p"]))
    }

    // MARK: disabled paths

    func assertDark(_ r: StatusLightRig) {
        XCTAssertTrue(r.sp.calls.isEmpty); XCTAssertNil(r.markerText)
        XCTAssertLessThanOrEqual(r.logs.lines.count, 1, r.logs.lines.joined(separator: "\n"))
    }
    func testDisabledOptOut() { let r = StatusLightRig(); r.light = r.make(enabled: false); r.counts(1, 0, 1, 0); assertDark(r) }
    func testNoCLI() { let r = StatusLightRig(); r.cli = nil; r.counts(1, 0, 1, 0); assertDark(r) }
    func testNoDevice() { let r = StatusLightRig(); r.device = nil; r.counts(1, 0, 1, 0); assertDark(r) }

    func testCandidatePathsOrderAbsoluteOnly() {
        XCTAssertEqual(StatusLight.candidatePaths(env: ["MEETING_CARD_SIDEPULSE": "/a/sp"], home: "/h"),
                       ["/a/sp", "/h/.local/bin/sidepulse", "/opt/homebrew/bin/sidepulse", "/usr/local/bin/sidepulse"])
        XCTAssertEqual(StatusLight.candidatePaths(env: ["MEETING_CARD_SIDEPULSE": "rel/sp"], home: "/h").first, "/h/.local/bin/sidepulse")
    }
    func testFindDeviceSortedFirstWithLED() {
        XCTAssertEqual(StatusLight.findDevice(volumes: ["/Volumes/Z", "/Volumes/B", "/Volumes/A"]) { $0 != "/Volumes/A" }, "/Volumes/B")
        XCTAssertNil(StatusLight.findDevice(volumes: ["/Volumes/A"]) { _ in false })
    }
}
