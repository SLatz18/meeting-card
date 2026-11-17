import XCTest
@testable import ListenMoreCore

final class SessionAndEngineTests: XCTestCase {
    var config: ListenMoreConfig!

    override func setUpWithError() throws {
        config = try TestConfig.load()
    }

    func testBundleIdsBelongAndStripHelperSuffix() {
        XCTAssertTrue(BundleIds.belongs("com.google.Chrome.helper.renderer", to: "com.google.chrome"))
        XCTAssertTrue(BundleIds.belongs("us.zoom.xos", to: "us.zoom.xos"))
        XCTAssertFalse(BundleIds.belongs("com.google.ChromeX", to: "com.google.Chrome"))
        XCTAssertEqual(BundleIds.stripHelperSuffix("com.example.App.helper.GPU"), "com.example.app")
        XCTAssertEqual(BundleIds.stripHelperSuffix("com.example.App"), "com.example.app")
    }

    func testOwningBundleIdWalksParents() {
        let table = [
            ProcessEntry(pid: 1, parentPid: 0, bundleId: nil),
            ProcessEntry(pid: 100, parentPid: 1, bundleId: "com.google.Chrome"),
            ProcessEntry(pid: 102, parentPid: 100, bundleId: nil),
            ProcessEntry(pid: 103, parentPid: 102, bundleId: nil),
            ProcessEntry(pid: 500, parentPid: 1, bundleId: nil),
        ]
        XCTAssertEqual(HelperProcessMatcher.owningBundleId(pid: 103, in: table), "com.google.Chrome")
        XCTAssertNil(HelperProcessMatcher.owningBundleId(pid: 500, in: table))
        XCTAssertNil(HelperProcessMatcher.owningBundleId(pid: 999, in: table))
    }

    func testCaptureTargetsAddAnAppOutsideTheConfig() {
        let targets = CapturePlan.targets(for: ["com.example.voicememo", "US.ZOOM.XOS"], configured: config.captureTargets)
        XCTAssertEqual(targets.count, config.captureTargets.count + 1)
        XCTAssertEqual(targets.last?.bundleId, "com.example.voicememo")
        XCTAssertEqual(targets.last?.kind, .native)
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
    }

    func testHelperMatcherSurvivesParentCycle() {
        let dia = config.captureTargets.first { $0.name == "Dia" }!
        let table = [ProcessEntry(pid: 5, parentPid: 6, bundleId: nil), ProcessEntry(pid: 6, parentPid: 5, bundleId: nil)]
        XCTAssertEqual(HelperProcessMatcher.helpers(of: dia, in: table), [])
    }

    func testAPIKeyIsRedacted() {
        let secret = "sk-test-0123456789abcdef"
        let key = APIKey(secret)!
        XCTAssertFalse(String(describing: key).contains(secret))
        XCTAssertFalse(String(reflecting: key).contains(secret))
        XCTAssertFalse("\(key)".contains(secret))
        var dumped = ""
        dump(key, to: &dumped)
        XCTAssertFalse(dumped.contains(secret))
        XCTAssertEqual(key.value, secret)
        XCTAssertNil(APIKey("  \n"))
    }

    func testStubEngine() {
        let e = StubCoachEngine()
        e.ingest(.mic, samples: [0, 0], time: 0)
        XCTAssertEqual(e.samplesIngested[.mic], nil)
        e.start(config: config, apiKey: APIKey("x"))
        XCTAssertTrue(e.isRunning && e.hasKey)
        e.ingest(.mic, samples: [Float](repeating: 0, count: 480), time: 0)
        e.ingest(.call, samples: [Float](repeating: 0, count: 480), time: 0)
        XCTAssertEqual(e.samplesIngested, [.mic: 480, .call: 480])
        e.stop()
        XCTAssertFalse(e.isRunning)
    }
}
