import XCTest
@testable import ListenMoreCore

final class CapturePlanTests: XCTestCase {
    var config: ListenMoreConfig!

    override func setUpWithError() throws {
        config = try TestConfig.load()
    }

    let ownPid: Int32 = 999
    let apps = [
        CapturableApp(pid: 10, bundleId: "us.zoom.xos"),
        CapturableApp(pid: 20, bundleId: "com.google.Chrome"),
        CapturableApp(pid: 21, bundleId: "com.google.Chrome.helper"),
        CapturableApp(pid: 30, bundleId: "company.thebrowser.dia"),
        CapturableApp(pid: 40, bundleId: "com.apple.Music"),
        CapturableApp(pid: 999, bundleId: "com.listenmore.mac"),
    ]
    let table = [
        ProcessEntry(pid: 20, parentPid: 1, bundleId: "com.google.Chrome"),
        ProcessEntry(pid: 30, parentPid: 1, bundleId: "company.thebrowser.dia"),
        ProcessEntry(pid: 31, parentPid: 30, bundleId: nil),
    ]

    func select(_ ids: [String], _ stage: CaptureStage, apps: [CapturableApp]? = nil) -> [Int32] {
        CapturePlan.selectApps(from: apps ?? self.apps, bundleIds: ids, targets: config.captureTargets,
                               stage: stage, processTable: table, ownPid: ownPid).map(\.pid)
    }

    func testParentOnly() {
        XCTAssertEqual(select(["com.google.Chrome"], .parentApps), [20])
        XCTAssertEqual(select(["us.zoom.xos"], .parentApps), [10])
    }

    func testHelpersByPrefix() {
        XCTAssertEqual(select(["com.google.Chrome"], .helperApps), [20, 21])
    }

    func testHelpersByParentPid() {
        let withDiaHelper = apps + [CapturableApp(pid: 31, bundleId: "")]
        XCTAssertEqual(select(["company.thebrowser.dia"], .helperApps, apps: withDiaHelper), [30, 31])
    }

    func testManualCapturesAllTargetsButNeverOtherAppsOrSelf() {
        let all = config.captureTargets.map(\.bundleId)
        XCTAssertEqual(select(all, .helperApps), [10, 20, 21, 30])
    }

    func testOwnProcessExcludedEvenIfItMatches() {
        let sneaky = [CapturableApp(pid: 999, bundleId: "com.google.Chrome")]
        XCTAssertEqual(select(["com.google.Chrome"], .parentApps, apps: sneaky), [])
    }

    func testFallbackEscalatesOnlyWhenHelpersAudibleAndCallSilent() {
        var p = CaptureFallbackPolicy(silenceS: 4)
        XCTAssertNil(p.observe(callDbfs: -90, helpersAudible: false, now: 0))
        XCTAssertNil(p.observe(callDbfs: -90, helpersAudible: false, now: 10))
        XCTAssertNil(p.observe(callDbfs: -20, helpersAudible: true, now: 11))
        XCTAssertNil(p.observe(callDbfs: -90, helpersAudible: true, now: 12))
        XCTAssertNil(p.observe(callDbfs: -90, helpersAudible: true, now: 15))
        XCTAssertEqual(p.observe(callDbfs: -90, helpersAudible: true, now: 16), .helperApps)
        XCTAssertNil(p.observe(callDbfs: -90, helpersAudible: true, now: 17))
        XCTAssertNil(p.observe(callDbfs: -90, helpersAudible: true, now: 20))
        XCTAssertEqual(p.observe(callDbfs: -90, helpersAudible: true, now: 21), .processTap)
        XCTAssertNil(p.observe(callDbfs: -90, helpersAudible: true, now: 30))
        XCTAssertEqual(p.stage, .processTap)
        p.reset()
        XCTAssertEqual(p.stage, .parentApps)
    }

    func testRms() {
        XCTAssertEqual(CaptureFallbackPolicy.rmsDbfs([]), -.infinity)
        XCTAssertEqual(CaptureFallbackPolicy.rmsDbfs([0, 0]), -.infinity)
        XCTAssertEqual(CaptureFallbackPolicy.rmsDbfs([1, -1]), 0, accuracy: 1e-5)
        XCTAssertEqual(CaptureFallbackPolicy.rmsDbfs([0.1, -0.1]), -20, accuracy: 1e-4)
    }

    func testDecideByStage() {
        XCTAssertEqual(CapturePlan.decide(apps: apps, bundleIds: ["com.google.Chrome"], targets: config.captureTargets,
                                          stage: .parentApps, processTable: table, ownPid: ownPid), .screenCapture(pids: [20]))
        XCTAssertEqual(CapturePlan.decide(apps: apps, bundleIds: ["com.google.Chrome"], targets: config.captureTargets,
                                          stage: .helperApps, processTable: table, ownPid: ownPid), .screenCapture(pids: [20, 21]))
        XCTAssertEqual(CapturePlan.decide(apps: apps, bundleIds: ["com.google.Chrome"], targets: config.captureTargets,
                                          stage: .processTap, processTable: table, ownPid: ownPid), .processTap(pids: [21]))
        XCTAssertEqual(CapturePlan.decide(apps: apps, bundleIds: ["company.thebrowser.dia"], targets: config.captureTargets,
                                          stage: .processTap, processTable: table, ownPid: ownPid), .processTap(pids: [31]))
        XCTAssertEqual(CapturePlan.decide(apps: apps, bundleIds: ["us.zoom.xos"], targets: config.captureTargets,
                                          stage: .processTap, processTable: table, ownPid: ownPid), .nothingToCapture)
        XCTAssertEqual(CapturePlan.decide(apps: [], bundleIds: ["us.zoom.xos"], targets: config.captureTargets,
                                          stage: .parentApps, processTable: [], ownPid: ownPid), .nothingToCapture)
    }

    func testFaceTimeIncludesAvconferenced() {
        let ft = [CapturableApp(pid: 50, bundleId: "com.apple.FaceTime"), CapturableApp(pid: 51, bundleId: "com.apple.avconferenced")]
        XCTAssertEqual(CapturePlan.decide(apps: ft, bundleIds: ["com.apple.FaceTime"], targets: config.captureTargets,
                                          stage: .parentApps, processTable: [], ownPid: ownPid), .screenCapture(pids: [50, 51]))
    }
}
