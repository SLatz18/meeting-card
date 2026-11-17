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
        CapturableApp(pid: 999, bundleId: "com.slatz.meetingcard.swift"),
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

    func testLowercasedSessionKeyStillMatches() {
        XCTAssertEqual(select(["com.google.chrome"], .parentApps), [20])
    }

    func testHelpersByPrefix() {
        XCTAssertEqual(select(["com.google.Chrome"], .helperApps), [20, 21])
    }

    func testHelpersByParentPid() {
        let withDiaHelper = apps + [CapturableApp(pid: 31, bundleId: "")]
        XCTAssertEqual(select(["company.thebrowser.dia"], .helperApps, apps: withDiaHelper), [30, 31])
    }

    func testManualCapturesAllTargetsButNeverOtherAppsOrSelf() {
        XCTAssertEqual(select(config.captureTargets.map(\.bundleId), .helperApps), [10, 20, 21, 30])
    }

    func testOwnProcessExcludedEvenIfItMatches() {
        XCTAssertEqual(select(["com.google.Chrome"], .parentApps, apps: [CapturableApp(pid: 999, bundleId: "com.google.Chrome")]), [])
    }

    func testAnyAppTargetGetsHelperMatching() {
        let targets = CapturePlan.targets(for: ["com.example.voice"], configured: config.captureTargets)
        XCTAssertEqual(targets.last?.bundleId, "com.example.voice")
        let extra = [CapturableApp(pid: 50, bundleId: "com.example.voice"), CapturableApp(pid: 51, bundleId: "com.example.voice.helper")]
        let pids = CapturePlan.selectApps(from: apps + extra, bundleIds: ["com.example.voice"], targets: targets,
                                          stage: .helperApps, processTable: [], ownPid: ownPid).map(\.pid)
        XCTAssertEqual(pids, [50, 51])
        XCTAssertEqual(CapturePlan.targets(for: ["us.zoom.xos"], configured: config.captureTargets).count, config.captureTargets.count)
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

    // MARK: helper processes (ports of test_detect.py's bundle resolution + the Swift shell's matcher tests)

    func testHelperResolvesToParent() {
        let t = config.captureTargets
        XCTAssertEqual(BundleIds.resolveParent("com.google.Chrome.helper.renderer", targets: t)?.name, "Google Chrome")
        XCTAssertEqual(BundleIds.resolveParent("company.thebrowser.dia.helper", targets: t)?.name, "Dia")
        XCTAssertEqual(BundleIds.resolveParent("COM.GOOGLE.CHROME.HELPER", targets: t)?.name, "Google Chrome")
        XCTAssertNil(BundleIds.resolveParent("com.google.ChromeX", targets: t))
    }

    func testStripHelperSuffix() {
        XCTAssertEqual(BundleIds.stripHelperSuffix("com.Example.App.helper.Renderer"), "com.example.app")
        XCTAssertEqual(BundleIds.stripHelperSuffix("com.example.app"), "com.example.app")
    }

    func testHelperMatcherByPrefixAndParentPid() {
        let chrome = config.captureTargets.first { $0.name == "Google Chrome" }!
        let table = [
            ProcessEntry(pid: 1, parentPid: 0, bundleId: nil),
            ProcessEntry(pid: 100, parentPid: 1, bundleId: "com.google.Chrome"),
            ProcessEntry(pid: 101, parentPid: 100, bundleId: "com.google.Chrome.helper"),
            ProcessEntry(pid: 102, parentPid: 100, bundleId: nil),
            ProcessEntry(pid: 103, parentPid: 102, bundleId: nil),
            ProcessEntry(pid: 104, parentPid: 1, bundleId: "com.google.Chrome.helper.renderer"),
            ProcessEntry(pid: 200, parentPid: 1, bundleId: "com.google.ChromeX"),
            ProcessEntry(pid: 300, parentPid: 1, bundleId: "company.thebrowser.dia"),
            ProcessEntry(pid: 301, parentPid: 300, bundleId: "company.thebrowser.dia.helper"),
        ]
        XCTAssertEqual(HelperProcessMatcher.helpers(of: chrome, in: table).map(\.pid), [101, 102, 103, 104])
        let dia = config.captureTargets.first { $0.name == "Dia" }!
        XCTAssertEqual(HelperProcessMatcher.helpers(of: dia, in: table).map(\.pid), [301])
        XCTAssertEqual(HelperProcessMatcher.owningBundleId(pid: 103, in: table), "com.google.Chrome")
        XCTAssertNil(HelperProcessMatcher.owningBundleId(pid: 1, in: table))
    }

    func testHelperMatcherSurvivesParentCycle() {
        let dia = config.captureTargets.first { $0.name == "Dia" }!
        let table = [ProcessEntry(pid: 5, parentPid: 6, bundleId: nil), ProcessEntry(pid: 6, parentPid: 5, bundleId: nil)]
        XCTAssertEqual(HelperProcessMatcher.helpers(of: dia, in: table), [])
        XCTAssertNil(HelperProcessMatcher.owningBundleId(pid: 5, in: table))
    }
}
