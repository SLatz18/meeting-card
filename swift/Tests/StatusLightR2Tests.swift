import XCTest
@testable import MeetingCardCore

/// Round 2: provider colors, lead-card retarget, marker-driven restore (F1/F3/F5).
final class StatusLightR2Tests: XCTestCase {
    func hex(_ v: UInt32) -> String { String(format: "#%06X", v) }
    func breathing(_ c: String) -> String {
        "off\n\(c) 3.2s pulse\noff 800ms none\nrepeat"
    }
    func configure(_ d: String) -> [String] { ["battery", "configure", "--display", d] }
    func write(_ p: String) -> [String] { ["write", "--device", "/Volumes/PULSE", "--", p] }
    func writeMarker(_ r: StatusLightRig, _ s: String) {
        try! FileManager.default.createDirectory(at: r.dir, withIntermediateDirectories: true)
        try! Data(s.utf8).write(to: r.marker)
    }

    // MARK: provider mapping

    func testProviderPrograms() {
        let meet = [Brand.meetGreen, Brand.meetGreen, Brand.meetYellow, Brand.meetYellow,
                    Brand.meetBlue, Brand.meetBlue, Brand.meetRed, Brand.meetRed].map(hex).joined(separator: " ")
        let webex = [Brand.webexCyan, Brand.webexCyan, Brand.webexGreen, Brand.webexGreen,
                     Brand.webexCyan, Brand.webexCyan, Brand.webexGreen, Brand.webexGreen].map(hex).joined(separator: " ")
        XCTAssertEqual(StatusLight.program(provider: "meet"), breathing(meet))
        XCTAssertEqual(StatusLight.program(provider: "webex"), breathing(webex))
        XCTAssertEqual(StatusLight.program(provider: "zoom"), breathing(hex(Brand.zoom)))
        XCTAssertEqual(StatusLight.program(provider: "teams"), breathing(hex(Brand.teams)))
        for p in [nil, "calendar", "skype"] {
            XCTAssertEqual(StatusLight.program(provider: p), breathing("#FFFFFF"), "\(String(describing: p))")
        }
        // exact literal line (uppercase #RRGGBB, 8 positional colors)
        XCTAssertTrue(StatusLight.program(provider: "meet").contains(
            "\n#34A853 #34A853 #FBBC04 #FBBC04 #4285F4 #4285F4 #EA4335 #EA4335 3.2s pulse\n"))
        XCTAssertTrue(StatusLight.program(provider: "webex").contains(
            "\n#07C1E4 #07C1E4 #6CC04A #6CC04A #07C1E4 #07C1E4 #6CC04A #6CC04A 3.2s pulse\n"))
    }

    func testOverrideReplacesEveryProvider() {
        let r = StatusLightRig(); r.light = r.make(override: "off\n#123456 1s pulse\nrepeat")
        r.light.cards(1, provider: "meet"); r.light.cards(2, provider: "zoom"); r.light.cards(1, provider: nil); r.q.drain()
        XCTAssertEqual(r.sp.calls, [configure("custom"), write("off\n#123456 1s pulse\nrepeat")], "no retarget: same program")
    }

    // MARK: retarget

    func testRetargetIsOneWriteNoConfigure() {
        let r = StatusLightRig()
        r.light.cards(1, provider: "zoom"); r.q.drain()
        r.light.cards(2, provider: "meet"); r.q.drain()
        XCTAssertEqual(r.sp.calls, [configure("custom"), write(StatusLight.program(provider: "zoom")),
                                    write(StatusLight.program(provider: "meet"))])
    }

    func testNoRetargetWhenProviderUnchanged() {
        let r = StatusLightRig()
        r.light.cards(1, provider: "zoom"); r.light.cards(2, provider: "zoom"); r.light.cards(1, provider: "zoom"); r.q.drain()
        XCTAssertEqual(r.sp.calls.count, 2)
    }

    func testRetargetedProgramIsWhatRecheckCompares() {
        let r = StatusLightRig()
        r.light.cards(1, provider: "zoom"); r.light.cards(1, provider: "meet"); r.q.drain()
        r.led = StatusLight.program(provider: "meet")
        r.q.fireDelayed(); r.q.drain()
        XCTAssertEqual(r.sp.calls.count, 3, "LED already shows the retargeted program: no re-check write")
    }

    // MARK: F1

    func testOffRestoreFailsThenShutdownRetries() {
        let sp = FakeSidepulse()
        let q = DispatchQueue(label: "t.f1")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sl-\(UUID().uuidString)")
        let marker = dir.appendingPathComponent("m.json")
        let l = StatusLight(enabled: true, cli: { "/fake" }, device: { "/Volumes/PULSE" },
                            readSettings: { Data("{\"led_display\":\"\(sp.display)\"}".utf8) },
                            readLED: { _ in nil }, markerURL: marker, runner: sp, env: [:],
                            enqueue: { q.async(execute: $0) }, after: { _, _ in }, log: { _ in })
        l.cards(1, provider: "zoom"); q.sync {}
        sp.result = .timedOut
        l.cards(0, provider: nil); q.sync {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: marker.path))
        sp.result = .exited(status: 0, stdout: Data(), stderr: Data())
        l.shutdown(timeout: 1)
        XCTAssertEqual(sp.calls.last, configure("agent"))
        XCTAssertEqual(sp.calls.filter { $0 == configure("agent") }.count, 2, "Off tried, shutdown retried")
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
    }

    func testFailedRecoveryRetriedByNextCardThenLights() {
        let r = StatusLightRig(); r.sp.display = "custom"; writeMarker(r, "{\"prior\":\"battery\"}")
        r.sp.result = .timedOut
        r.light.recoverFromMarker(); r.q.drain()
        XCTAssertNotNil(r.markerText)
        r.sp.result = .exited(status: 0, stdout: Data(), stderr: Data())
        r.counts(1)
        XCTAssertEqual(Array(r.sp.calls.dropFirst()), [configure("battery"), configure("custom"),
                                                       write(StatusLight.program(provider: "zoom"))])
        XCTAssertTrue(r.logs.lines.contains("status light on (prior=battery)"))
    }

    func testOnSkipsWhileRestoreStillFails() {
        let r = StatusLightRig(); r.sp.display = "custom"; writeMarker(r, "{\"prior\":\"agent\"}")
        r.sp.result = .timedOut
        r.counts(1)
        XCTAssertEqual(r.sp.calls, [configure("agent")])
        XCTAssertTrue(r.logs.lines.contains("status light skipped: restore pending"))
    }

    // MARK: F3

    func testGarbledSettingsZeroCalls() {
        let r = StatusLightRig(); r.settings = Data("{\"led_disp".utf8)
        r.counts(1, 0)
        XCTAssertTrue(r.sp.calls.isEmpty); XCTAssertNil(r.markerText)
        XCTAssertTrue(r.logs.lines.contains("status light skipped: settings unreadable"))
    }

    func testAbsentSettingsMeansAgent() {
        let r = StatusLightRig(); r.settingsAbsent = true
        r.counts(1)
        XCTAssertEqual(r.sp.calls.count, 2)
        XCTAssertTrue(r.logs.lines.contains("status light on (prior=agent)"))
    }

    // MARK: F5

    func testStaleMarkerRetiredWithoutConfigure() {
        let r = StatusLightRig(); r.sp.display = "agent"; writeMarker(r, "{\"prior\":\"battery\"}")
        r.light.recoverFromMarker(); r.q.drain()
        XCTAssertTrue(r.sp.calls.isEmpty); XCTAssertNil(r.markerText)
        XCTAssertTrue(r.logs.lines.contains("status light: stale marker retired"))
    }

    func testMarkerWithCustomSettingsRestoresPrior() {
        let r = StatusLightRig(); r.sp.display = "custom"; writeMarker(r, "{\"prior\":\"battery\"}")
        r.light.recoverFromMarker(); r.q.drain()
        XCTAssertEqual(r.sp.calls, [configure("battery")]); XCTAssertNil(r.markerText)
    }

    func testMarkerKeptWhenSettingsUnreadable() {
        let r = StatusLightRig(); r.settings = Data("{tor".utf8); writeMarker(r, "{\"prior\":\"battery\"}")
        r.light.recoverFromMarker(); r.q.drain()
        XCTAssertTrue(r.sp.calls.isEmpty); XCTAssertNotNil(r.markerText)
        r.counts(1)   // still torn when the next card fires: restore stays pending, card skipped
        XCTAssertTrue(r.sp.calls.isEmpty); XCTAssertNotNil(r.markerText)
        XCTAssertTrue(r.logs.lines.contains("status light skipped: restore pending"))
    }
}

extension CoordinatorTests {
    func relinked(_ base: Event, _ name: String, at minutes: Double = 0, id: String? = nil) -> Event {
        var e = fx(name); e.id = id ?? base.id; e.start = base.start; e.end = base.end; e.summary = base.summary
        return minutes == 0 ? e : moved(e, minutes)
    }

    /// The lead card is the SOONEST, whatever the show order; closing it retargets to the next one.
    func testLeadProviderIsSoonestAndFollowsClose() {
        let a = fx("meet"), r = Rig(now: start(a) - 2 * M)
        var seen: [String?] = []
        r.ctl.onCards = { _, p in seen.append(p) }
        let later = relinked(a, "zoom", at: 10, id: "later")
        let cLater = r.ctl.showCard(later)
        let cSoon = r.ctl.showCard(a)
        XCTAssertEqual(seen, ["zoom", "meet"])
        r.ctl.closeCard(cSoon)
        XCTAssertEqual(seen.last, "zoom")
        r.ctl.closeCard(cLater)
        XCTAssertEqual(seen.last, .some(nil))
    }

    /// A link edit while the card is up (`.update`) re-reports the lead provider.
    func testLinkEditRetargets() {
        let a = fx("meet"), r = Rig(now: start(a) - 2 * M)
        var seen: [String?] = []
        r.ctl.onCards = { _, p in seen.append(p) }
        let c = r.ctl.showCard(a)
        r.ctl.liveDone(c, c.rk.shouldStart(r.mono + 100) ?? 0, .event(relinked(a, "zoom")))
        XCTAssertEqual(seen, ["meet", "zoom"])
    }
}
