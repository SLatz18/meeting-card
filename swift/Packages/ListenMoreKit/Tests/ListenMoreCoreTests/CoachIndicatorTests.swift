import XCTest
@testable import ListenMoreCore

/// Chip visibility: shown while pre-warmed or running, hidden ~30 s after call audio stops.
final class CoachIndicatorTests: XCTestCase {
    var trigger: CoachTrigger!
    let zoom = AudioStateSnapshot(defaultInputRunning: true, processes: [
        AudioProcessState(pid: 5, bundleId: "us.zoom.xos", isRunningInput: true, isRunningOutput: true)])
    let silent = AudioStateSnapshot(defaultInputRunning: false, processes: [])

    override func setUpWithError() throws {
        let c = try TestConfig.load()
        trigger = CoachTrigger(settings: TriggerSettings(config: c, anyApp: false, ownPid: 1, ownBundleId: nil), enabled: true)
    }

    func run(_ snap: AudioStateSnapshot, _ from: Double, _ to: Double) {
        var t = from
        while t <= to + 1e-9 { _ = trigger.tick(snap, now: t); t += 0.5 }
    }

    func testHiddenWhenIdleOrOff() {
        XCTAssertEqual(trigger.indicator, .hidden)
        run(silent, 0, 10)
        XCTAssertEqual(trigger.indicator, .hidden)
        var off = trigger!
        _ = off.setEnabled(false)
        off.joinHint(endsAt: 100, now: 0)
        XCTAssertEqual(off.indicator, .hidden, "off never shows the chip")
    }

    func testOnWhilePrewarmedByJoin() {
        trigger.joinHint(endsAt: 60, now: 0)
        XCTAssertEqual(trigger.indicator, .on)
        run(silent, 0, 59.5)
        XCTAssertEqual(trigger.indicator, .on)
        run(silent, 60, 61)
        XCTAssertEqual(trigger.indicator, .hidden, "pre-warm ends with the event")
    }

    func testOnDuringDebounceThenListening() {
        run(zoom, 0, 1)
        XCTAssertEqual(trigger.indicator, .on)
        run(zoom, 1.5, 3)
        XCTAssertEqual(trigger.indicator, .listening)
    }

    func testPausedThenHiddenThirtySecondsAfterAudioStops() {
        run(zoom, 0, 5)
        _ = trigger.setPaused(true)
        XCTAssertEqual(trigger.indicator, .paused)
        _ = trigger.setPaused(false)
        XCTAssertEqual(trigger.indicator, .listening)
        run(silent, 5.5, 35)
        XCTAssertEqual(trigger.indicator, .listening, "still within ~30 s of audio stopping")
        run(silent, 35.5, 36)
        XCTAssertEqual(trigger.indicator, .hidden)
    }

    func testSuppressedCallIsNotPrewarm() {
        run(zoom, 0, 5)
        _ = trigger.manualStop()
        run(zoom, 5.5, 10)
        XCTAssertEqual(trigger.indicator, .hidden)
    }

    func testPauseWhilePrewarmedSkipsThisCall() {
        trigger.joinHint(endsAt: 600, now: 0)
        run(zoom, 0, 1)
        XCTAssertEqual(trigger.indicator, .on)
        trigger.dismissPrewarm()
        XCTAssertEqual(trigger.indicator, .hidden)
        run(zoom, 1.5, 10)
        XCTAssertNil(trigger.session, "the dismissed call never auto-starts")
        run(silent, 10.5, 11)
        run(zoom, 11.5, 15)
        XCTAssertEqual(trigger.indicator, .listening, "a later call starts normally")
    }
}
