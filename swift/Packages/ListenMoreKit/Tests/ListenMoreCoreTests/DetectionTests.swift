import XCTest
@testable import ListenMoreCore

/// Ports of tests/test_detect.py, plus Swift-only cases.
final class DetectionTests: XCTestCase {
    var config: ListenMoreConfig!
    var targets: [CaptureTarget] { config.captureTargets }

    override func setUpWithError() throws {
        config = try TestConfig.load()
    }

    func detect(_ windows: [WindowInfo], _ audio: [String: Bool]) -> Detection {
        MeetingDetector.detect(windows: windows, audioActive: audio, targets: targets, meetTitleRegex: config.meetTitleRegex)
    }

    func testCaptureTargetsInConfig() {
        XCTAssertTrue(Set(["Zoom", "Google Chrome", "Dia"]).isSubset(of: Set(targets.map(\.name))))
        let dia = targets.first { $0.name == "Dia" }
        XCTAssertEqual(dia?.bundleId, "company.thebrowser.dia")
        XCTAssertTrue(dia?.bundleIdStatus?.contains("UNVERIFIED") ?? false)
        XCTAssertEqual(targets.first { $0.kind == .zoom }?.bundleId, "us.zoom.xos")
        XCTAssertEqual(targets.first { $0.kind == .zoom }?.processName, "zoom.us")
    }

    func testHelperResolvesToParent() {
        XCTAssertEqual(MeetingDetector.resolveParent("com.google.Chrome.helper.renderer", targets: targets)?.name, "Google Chrome")
        XCTAssertEqual(MeetingDetector.resolveParent("company.thebrowser.dia.helper", targets: targets)?.name, "Dia")
        XCTAssertNil(MeetingDetector.resolveParent("com.google.ChromeX", targets: targets))
    }

    func testResolveParentIsCaseInsensitive() {
        XCTAssertEqual(MeetingDetector.resolveParent("COM.GOOGLE.CHROME.HELPER", targets: targets)?.name, "Google Chrome")
    }

    func testMeetInChromeViaHelperAudio() {
        let d = detect([WindowInfo(bundleId: "com.google.Chrome", title: "Meet - abc-defg-hij")], ["com.google.Chrome.helper": true])
        XCTAssertTrue(d.active)
        XCTAssertEqual(d.kind, .meet)
        XCTAssertEqual(d.target, "Google Chrome")
        XCTAssertEqual(d.bundleId, "com.google.Chrome")
    }

    func testMeetInDia() {
        let d = detect([WindowInfo(bundleId: "company.thebrowser.dia", title: "Google Meet")],
                       ["company.thebrowser.dia.helper.renderer": true])
        XCTAssertTrue(d.active)
        XCTAssertEqual(d.target, "Dia")
    }

    func testMeetTitleWithoutAudioIsOff() {
        XCTAssertFalse(detect([WindowInfo(bundleId: "company.thebrowser.dia", title: "Meet - x")], [:]).active)
    }

    func testAudioFlagFalseIsOff() {
        XCTAssertFalse(detect([WindowInfo(bundleId: "com.google.Chrome", title: "Meet - x")], ["com.google.Chrome.helper": false]).active)
    }

    func testAudioWithoutMeetTitleIsOff() {
        XCTAssertFalse(detect([WindowInfo(bundleId: "com.google.Chrome", title: "YouTube")], ["com.google.Chrome.helper": true]).active)
    }

    func testMeetingNotesDocIsNotMeet() {
        let w = [WindowInfo(bundleId: "com.google.Chrome", title: "Meeting notes - Google Docs")]
        XCTAssertFalse(detect(w, ["com.google.Chrome.helper": true]).active)
    }

    func testAudioFromOtherBrowserDoesNotCount() {
        let w = [WindowInfo(bundleId: "company.thebrowser.dia", title: "Meet - x")]
        XCTAssertFalse(detect(w, ["com.google.Chrome.helper": true]).active)
    }

    func testZoomMeeting() {
        let d = detect([WindowInfo(bundleId: "us.zoom.xos", title: "Zoom Meeting")], ["us.zoom.xos": true])
        XCTAssertTrue(d.active)
        XCTAssertEqual(d.kind, .zoom)
        XCTAssertFalse(detect([WindowInfo(bundleId: "us.zoom.xos", title: "Zoom Workplace")], ["us.zoom.xos": true]).active)
    }

    func testZoomWithoutAudioIsOff() {
        XCTAssertFalse(detect([WindowInfo(bundleId: "us.zoom.xos", title: "Zoom Meeting")], [:]).active)
    }

    func testZoomWinsOverBrowser() {
        let d = detect([WindowInfo(bundleId: "com.google.Chrome", title: "Meet - x"),
                        WindowInfo(bundleId: "us.zoom.xos", title: "Zoom Webinar")],
                       ["com.google.Chrome.helper": true, "us.zoom.xos": true])
        XCTAssertEqual(d.kind, .zoom)
    }

    func testUnknownBrowserIsIgnored() {
        XCTAssertFalse(detect([WindowInfo(bundleId: "org.mozilla.firefox", title: "Meet - x")], ["org.mozilla.firefox": true]).active)
    }

    func testWindowTitleSignalReportsTheDetectedApp() {
        let probe = FakeProbe()
        let signal = WindowTitleSignal(probe: probe, targets: config.captureTargets, meetTitleRegex: config.meetTitleRegex)
        let settings = TriggerSettings(config: config, anyApp: false, ownPid: 1, ownBundleId: nil)
        XCTAssertEqual(signal.poll(settings).liveApps, [])
        probe.windowList = [WindowInfo(bundleId: "company.thebrowser.dia", title: "Meet - x")]
        probe.audio = ["company.thebrowser.dia.helper.renderer": true]
        let r = signal.poll(settings)
        XCTAssertEqual(r.liveApps, ["company.thebrowser.dia"])
        XCTAssertTrue(r.inputRunning)
        XCTAssertEqual(signal.lastDetection.kind, .meet)
        XCTAssertTrue(signal.helpersAudible(bundleIds: ["company.thebrowser.dia"]))
        probe.audio = ["company.thebrowser.dia": true]
        XCTAssertFalse(signal.helpersAudible(bundleIds: ["company.thebrowser.dia"]), "the app itself is not a helper")
    }

    func testWindowTitleSignalHonoursExclusions() {
        let probe = FakeProbe()
        probe.windowList = [WindowInfo(bundleId: "us.zoom.xos", title: "Zoom Meeting")]
        probe.audio = ["us.zoom.xos": true]
        let signal = WindowTitleSignal(probe: probe, targets: config.captureTargets, meetTitleRegex: config.meetTitleRegex)
        let settings = TriggerSettings(config: config, anyApp: false, ownPid: 1, ownBundleId: nil, excludedBundleIds: ["us.zoom.xos"])
        XCTAssertEqual(signal.poll(settings).liveApps, [])
    }
}
