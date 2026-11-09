import XCTest
@testable import MeetingCardCore

final class StatusLightLifecycleTests: XCTestCase {
    func testMarkerWrittenBeforeConfigure() {
        let r = StatusLightRig()
        var seen: [String?] = []
        r.sp.onCall = { [unowned r] _ in seen.append(r.markerText) }
        r.counts(1)
        XCTAssertEqual(seen.first ?? nil, "{\"prior\":\"agent\"}")
    }
    func testMarkerRemovedAfterOff() {
        let r = StatusLightRig(); r.counts(1)
        XCTAssertNotNil(r.markerText)
        r.counts(0); XCTAssertNil(r.markerText)
    }
    func writeMarker(_ r: StatusLightRig, _ s: String) {
        try! FileManager.default.createDirectory(at: r.dir, withIntermediateDirectories: true)
        try! Data(s.utf8).write(to: r.marker)
    }
    func testLaunchMarkerRunsOffWithItsPrior() {
        let r = StatusLightRig(); r.sp.display = "custom"; writeMarker(r, "{\"prior\":\"battery\"}")
        r.light.recoverFromMarker(); r.q.drain()
        XCTAssertEqual(r.sp.calls, [["battery", "configure", "--display", "battery"]])
        XCTAssertNil(r.markerText)
    }
    func testGarbledOrUnknownMarkerRestoresAgent() {
        for s in ["{garbage", "{\"prior\":\"rainbow\"}", "{}"] {
            let r = StatusLightRig(); r.sp.display = "custom"; writeMarker(r, s)
            r.light.recoverFromMarker(); r.q.drain()
            XCTAssertEqual(r.sp.calls, [["battery", "configure", "--display", "agent"]], s)
        }
    }
    func testFailedRestoreKeepsMarker() {
        let r = StatusLightRig(); r.counts(1)
        r.sp.result = .timedOut
        r.counts(0)
        XCTAssertNotNil(r.markerText, "Off failed: marker must survive for the next launch")
        XCTAssertTrue(r.logs.lines.contains("status light: restore failed; marker kept for next launch"))
    }
    func testFailedRecoveryKeepsMarker() {
        let r = StatusLightRig(); r.sp.display = "custom"; writeMarker(r, "{\"prior\":\"battery\"}")
        r.sp.result = .exited(status: 1, stdout: Data(), stderr: Data())
        r.light.recoverFromMarker(); r.q.drain()
        XCTAssertNotNil(r.markerText)
    }
    func testNoMarkerNoCallsNoLog() {
        let r = StatusLightRig(); r.light.recoverFromMarker(); r.q.drain()
        XCTAssertTrue(r.sp.calls.isEmpty); XCTAssertTrue(r.logs.lines.isEmpty)
    }

    // MARK: re-check

    func testRecheckRewritesOnlyOnMismatch() {
        let r = StatusLightRig(); r.counts(1)
        r.led = StatusLightTests.zoomProg + "\n"   // C2: trailing newline only = match
        r.q.fireDelayed(); r.q.drain()
        XCTAssertEqual(r.sp.calls.count, 2)
        let r2 = StatusLightRig(); r2.counts(1)
        r2.led = "agent stuff"
        r2.q.fireDelayed(); r2.q.drain()
        XCTAssertEqual(r2.sp.calls.count, 3)
        XCTAssertEqual(r2.sp.calls[2][0], "write")
        r2.led = StatusLightTests.zoomProg      // now matches: the next keepalive tick must not rewrite
        r2.q.fireDelayed(); r2.q.drain()
        XCTAssertEqual(r2.sp.calls.count, 3, "rewrite only on mismatch")
    }
    func testKeepaliveTicksWhileOnAndRewritesAfterReboot() {
        let r = StatusLightRig(); r.counts(1); r.led = StatusLightTests.zoomProg
        for _ in 0..<3 { r.q.fireDelayed(); r.q.drain() }     // 2s check + two 60s ticks
        XCTAssertEqual(r.touched, ["/Volumes/PULSE", "/Volumes/PULSE", "/Volumes/PULSE"])
        XCTAssertEqual(r.sp.calls.count, 2, "no rewrite while the program is intact")
        r.led = "off\n0:#ff00ff 0.15s ease-in"                // device rebooted into INIT.LED
        r.q.fireDelayed(); r.q.drain()
        XCTAssertEqual(r.sp.calls.last?.first, "write")
        XCTAssertEqual(r.sp.calls.count, 3)
        XCTAssertEqual(r.q.delayed.count, 1, "still ticking while on")
    }
    func testKeepaliveStopsAfterOff() {
        let r = StatusLightRig(); r.counts(1); r.led = StatusLightTests.zoomProg
        r.q.fireDelayed(); r.q.drain()
        r.counts(0); let n = r.touched.count
        r.q.fireDelayed(); r.q.drain()
        XCTAssertEqual(r.touched.count, n, "no touch after Off")
        XCTAssertTrue(r.q.delayed.isEmpty)
    }
    func testRecheckSkippedIfOffAlready() {
        let r = StatusLightRig(); r.counts(1, 0); r.led = "different"
        r.q.fireDelayed(); r.q.drain()
        XCTAssertEqual(r.sp.calls.count, 3)
    }

    // MARK: program

    func testProgramLimit() {
        let logs = LogBox()
        let at = String(repeating: "a", count: 512)
        XCTAssertEqual(StatusLight.validOverride(at, log: logs.add), at)
        XCTAssertNil(StatusLight.validOverride(at + "a", log: logs.add))
        XCTAssertNil(StatusLight.validOverride("", log: logs.add))
        XCTAssertNil(StatusLight.validOverride(nil, log: logs.add))
        XCTAssertEqual(logs.lines.count, 2)
    }

    // MARK: failures

    func testNonZeroExitLoggedNotRetried() {
        let r = StatusLightRig(); r.sp.result = .exited(status: 3, stdout: Data(), stderr: Data())
        r.counts(1)
        XCTAssertEqual(r.sp.calls.count, 1, "configure failed: no write, no retry")
        XCTAssertTrue(r.logs.lines.contains("status light: sidepulse configure rc=3"))
        r.counts(0)
        XCTAssertEqual(r.sp.calls.count, 1, "F5: configure custom never landed, so Off retires the marker without a call")
        XCTAssertNil(r.markerText)
        XCTAssertTrue(r.logs.lines.contains("status light: stale marker retired"))
    }
    func testTimeoutLogged() {
        let r = StatusLightRig(); r.sp.result = .timedOut
        r.counts(1)
        XCTAssertTrue(r.logs.lines.contains("status light: sidepulse configure rc=timeout"))
    }
    func testOffWorksWithDeviceGone() {
        let r = StatusLightRig(); r.counts(1); r.device = nil
        r.counts(0)
        XCTAssertEqual(r.sp.calls.last, ["battery", "configure", "--display", "agent"])
    }
    func testLogLinesHaveNoEventData() {
        let r = StatusLightRig(); r.counts(1, 0)
        for l in r.logs.lines { XCTAssertTrue(l.hasPrefix("status light"), l) }
    }

    // MARK: shutdown

    func testShutdownBoundedAndRunsOff() {
        let sp = FakeSidepulse()
        let q = DispatchQueue(label: "t.sl")
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("sl-\(UUID().uuidString)")
        let logs = LogBox()
        let l = StatusLight(enabled: true, cli: { "/fake" }, device: { "/Volumes/P" },
                            readSettings: { Data("{\"led_display\":\"\(sp.display)\"}".utf8) },
                            readLED: { _ in nil }, markerURL: dir.appendingPathComponent("m.json"),
                            override: "p", runner: sp, env: [:], enqueue: { q.async(execute: $0) },
                            after: { _, _ in }, log: logs.add)
        l.cards(1, provider: nil); q.sync {}
        sp.block = DispatchSemaphore(value: 0)   // Off hangs
        sp.blockSeconds = 3                      // well past the 0.5s budget (no race with the budget)
        let t0 = Date()
        l.shutdown(timeout: 0.5)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1.5)
        XCTAssertEqual(sp.calls.last, ["battery", "configure", "--display", "agent"])
        XCTAssertTrue(logs.lines.contains("status light off: timed out"))
        sp.block?.signal()
    }
    func testShutdownWhenOffIsSilent() {
        let r = StatusLightRig()
        let q = DispatchQueue(label: "t.sl2")
        let l = StatusLight(enabled: false, cli: { nil }, device: { nil }, readSettings: { nil }, readLED: { _ in nil },
                            markerURL: r.marker, override: "p", runner: r.sp, env: [:], enqueue: { q.async(execute: $0) },
                            after: { _, _ in }, log: r.logs.add)
        l.shutdown(timeout: 1)
        XCTAssertTrue(r.logs.lines.isEmpty); XCTAssertTrue(r.sp.calls.isEmpty)
    }
}
