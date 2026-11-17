import Foundation
import XCTest
@testable import ListenMoreCore

final class FakeRoutes: AudioRouteSource {
    var routes: AudioRoutes
    var onChange: (() -> Void)?
    var observing = false

    init(_ routes: AudioRoutes) { self.routes = routes }

    func snapshot() -> AudioRoutes { routes }
    func observe(_ onChange: @escaping () -> Void) { self.onChange = onChange; observing = true }
    func stopObserving() { onChange = nil; observing = false }

    func set(_ r: AudioRoutes) {
        routes = r
        onChange?()
    }
}

final class FakeInput: MicInput {
    let plan: MicPlan
    var isRunning = true
    var stopped = false
    let handler: @Sendable ([Float]) -> Void
    let onStopped: @Sendable () -> Void
    var applied: MicProcessing { plan.processing }
    var deviceID: UInt32? { plan.device }

    init(plan: MicPlan, handler: @escaping @Sendable ([Float]) -> Void, onStopped: @escaping @Sendable () -> Void) {
        self.plan = plan
        self.handler = handler
        self.onStopped = onStopped
    }

    func deliver(_ samples: [Float]) {
        guard !stopped else { return }
        handler(samples)
    }

    func stop() {
        stopped = true
        isRunning = false
    }

    /// The device went away under the input.
    func die() {
        isRunning = false
        onStopped()
    }
}

final class FakeOpener: MicInputOpening {
    var opened: [FakeInput] = []
    var failNext = false

    var open: FakeInput? { opened.last.flatMap { $0.stopped ? nil : $0 } }

    func open(_ plan: MicPlan, sampleRate: Int, handler: @escaping @Sendable ([Float]) -> Void,
              onStopped: @escaping @Sendable () -> Void) throws -> MicInput {
        if failNext {
            failNext = false
            throw NSError(domain: "FakeOpener", code: 1)
        }
        let i = FakeInput(plan: plan, handler: handler, onStopped: onStopped)
        opened.append(i)
        return i
    }
}

final class ManualScheduler: MicScheduler {
    var now: TimeInterval = 100
    private var pending: [(TimeInterval, () -> Void)] = []

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
        pending.append((now + delay, work))
    }

    /// Advances the clock, running due work in time order.
    func advance(_ dt: TimeInterval) {
        let end = now + dt
        while let i = pending.indices.filter({ pending[$0].0 <= end + 1e-9 }).min(by: { pending[$0].0 < pending[$1].0 }) {
            let (t, work) = pending.remove(at: i)
            now = max(now, t)
            work()
        }
        now = end
    }
}

final class RoutedMicTests: XCTestCase {
    let mac15 = OperatingSystemVersion(majorVersion: 15, minorVersion: 0, patchVersion: 0)
    let speakersOut = AudioDeviceInfo(id: 1, transport: .builtIn)
    let airPods = AudioDeviceInfo(id: 2, transport: .bluetooth)
    let builtInMic = AudioDeviceInfo(id: 3, transport: .builtIn)
    let usbMic = AudioDeviceInfo(id: 4, transport: .usb)

    var speakers: AudioRoutes { AudioRoutes(output: speakersOut, outputSource: .speakers, defaultInput: builtInMic, builtInInput: builtInMic) }
    var bluetooth: AudioRoutes { AudioRoutes(output: airPods, defaultInput: airPods, builtInInput: builtInMic) }
    var desktopBluetooth: AudioRoutes { AudioRoutes(output: airPods, defaultInput: airPods, builtInInput: nil) }

    var routes: FakeRoutes!
    var opener: FakeOpener!
    var clock: ManualScheduler!
    var events: [RoutedMic.Event] = []

    func make(_ r: AudioRoutes) -> RoutedMic {
        routes = FakeRoutes(r)
        opener = FakeOpener()
        clock = ManualScheduler()
        let mic = RoutedMic(routes: routes, opener: opener, scheduler: clock, macOS: mac15)
        mic.events = { [weak self] in self?.events.append($0) }
        // Fakes deliver audio only when a test says so; the silence tests set a real timeout.
        mic.silenceTimeout = 1e9
        return mic
    }

    func testStartOpensThePlanAndStopReleasesIt() throws {
        let mic = make(speakers)
        try mic.start(sampleRate: 24000) { _ in }
        XCTAssertTrue(routes.observing)
        XCTAssertEqual(opener.opened.count, 1)
        XCTAssertEqual(mic.plan?.processing.voiceProcessing, true)
        XCTAssertEqual(mic.plan?.processing.ducking, MicProcessing.minimumDucking)
        XCTAssertTrue(mic.isRunning)
        mic.stop()
        XCTAssertTrue(opener.opened[0].stopped, "input stopped and released")
        XCTAssertNil(mic.plan)
        XCTAssertFalse(mic.isRunning)
        XCTAssertFalse(routes.observing)
        XCTAssertEqual(events.last, .closed)
    }

    func testBluetoothOpensTheBuiltInMicWithoutVoiceProcessing() throws {
        let mic = make(bluetooth)
        try mic.start(sampleRate: 24000) { _ in }
        XCTAssertEqual(opener.opened.single?.plan, MicPlan(route: .bluetooth, micSource: .builtIn, device: builtInMic.id,
                                                            processing: MicProcessing(voiceProcessing: false, ducking: nil)))
    }

    func testNoBuiltInMicWithBluetoothOpensNothing() throws {
        let mic = make(desktopBluetooth)
        try mic.start(sampleRate: 24000) { _ in }
        XCTAssertTrue(opener.opened.isEmpty, "the headset mic is never opened")
        XCTAssertEqual(mic.plan?.micSource, MicSourceKind.none)
        XCTAssertFalse(mic.isRunning)
        XCTAssertEqual(events, [.opened(mic.plan!, applied: nil, deviceID: nil)])
    }

    // MARK: Mute API

    func testMuteClosesTheInputAndUnmuteReopensWithTheSameHandler() throws {
        let mic = make(speakers)
        let got = Box()
        try mic.start(sampleRate: 24000) { got.count += $0.count }
        mic.setMuted(true)
        XCTAssertTrue(mic.isMuted)
        XCTAssertTrue(opener.opened[0].stopped)
        XCTAssertNil(mic.plan)
        XCTAssertTrue(mic.isStarted, "the session still owns the mic")
        mic.setMuted(true)
        XCTAssertEqual(opener.opened.count, 1, "idempotent")
        mic.setMuted(false)
        XCTAssertEqual(opener.opened.count, 2)
        XCTAssertTrue(mic.isRunning)
        XCTAssertFalse(mic.isMuted)
    }

    func testMutedRouteChangesDontReopenAndStopClearsMute() throws {
        let mic = make(speakers)
        try mic.start(sampleRate: 24000) { _ in }
        mic.setMuted(true)
        routes.set(bluetooth)
        clock.advance(5)
        XCTAssertEqual(opener.opened.count, 1, "nothing opens while muted")
        mic.setMuted(false)
        XCTAssertEqual(opener.open?.plan.route, .bluetooth, "unmute opens on the current routes")
        mic.stop()
        XCTAssertFalse(mic.isMuted)
    }

    func testMutedBeforeStartOpensNothingUntilUnmuted() throws {
        let mic = make(speakers)
        mic.setMuted(true)
        try mic.start(sampleRate: 24000) { _ in }
        XCTAssertTrue(opener.opened.isEmpty)
        mic.setMuted(false)
        XCTAssertEqual(opener.opened.count, 1)
    }

    // MARK: route changes

    func testRouteChangeRestartsOnTheNewPlanAfterTheDebounce() throws {
        let mic = make(speakers)
        try mic.start(sampleRate: 24000) { _ in }
        routes.set(bluetooth)
        clock.advance(0.4)
        XCTAssertEqual(opener.opened.count, 1, "debounced")
        clock.advance(0.2)
        XCTAssertEqual(opener.opened.count, 2)
        XCTAssertTrue(opener.opened[0].stopped)
        XCTAssertEqual(opener.open?.plan.micSource, .builtIn)
        XCTAssertEqual(opener.open?.plan.processing.voiceProcessing, false)
        XCTAssertEqual(mic.restartCount, 1)
    }

    func testItsOwnDeviceChangesNeverRestartIt() throws {
        let mic = make(speakers)
        try mic.start(sampleRate: 24000) { _ in }
        for _ in 0..<20 {
            routes.set(speakers)
            clock.advance(1)
        }
        XCTAssertEqual(opener.opened.count, 1)
        XCTAssertEqual(mic.restartCount, 0)
    }

    func testAnInputThatDiesIsReopened() throws {
        let mic = make(speakers)
        try mic.start(sampleRate: 24000) { _ in }
        opener.opened[0].die()
        clock.advance(1)
        XCTAssertEqual(opener.opened.count, 2)
        XCTAssertTrue(mic.isRunning)
    }

    func testFlappingRoutesCannotLoop() throws {
        let mic = make(speakers)
        try mic.start(sampleRate: 24000) { _ in }
        for i in 0..<200 {
            routes.set(i.isMultiple(of: 2) ? bluetooth : speakers)
            clock.advance(0.6)
        }
        clock.advance(60)
        XCTAssertLessThanOrEqual(mic.restartCount, 3 * (180 / 30) + 3)
        XCTAssertEqual(opener.opened.filter { !$0.stopped }.count, 1, "one input open at a time")
        XCTAssertEqual(mic.plan, mic.currentPlan(), "settles on the final routes")
    }

    func testAFailedReopenIsRetriedOnTheNextChange() throws {
        let mic = make(speakers)
        try mic.start(sampleRate: 24000) { _ in }
        opener.failNext = true
        routes.set(bluetooth)
        clock.advance(1)
        XCTAssertNil(mic.plan)
        XCTAssertEqual(events.last.map { if case .openFailed = $0 { true } else { false } }, true)
        routes.set(bluetooth)
        clock.advance(1)
        XCTAssertEqual(mic.plan?.route, .bluetooth)
        XCTAssertTrue(mic.isRunning)
    }

    func testStartFailureLeavesItStopped() {
        let mic = make(speakers)
        routes = mic.routes as? FakeRoutes
        opener.failNext = true
        XCTAssertThrowsError(try mic.start(sampleRate: 24000) { _ in })
        XCTAssertFalse(mic.isStarted)
        XCTAssertFalse(routes.observing)
    }

    func testRouteEventsAfterStopAreIgnored() throws {
        let mic = make(speakers)
        try mic.start(sampleRate: 24000) { _ in }
        let pendingChange = routes.onChange
        routes.set(bluetooth)
        mic.stop()
        pendingChange?()
        clock.advance(5)
        XCTAssertEqual(opener.opened.count, 1)
    }

    // MARK: a built-in mic that delivers nothing (closed lid)

    let speech = [Float](repeating: 0.1, count: 480)
    let zeros = [Float](repeating: 0, count: 480)

    func testABuiltInMicDeliveringOnlyZerosFallsBackToCallAudioOnly() throws {
        let mic = make(bluetooth)
        mic.silenceTimeout = 3
        try mic.start(sampleRate: 24000) { _ in }
        for _ in 0..<5 {
            opener.open?.deliver(zeros)
            clock.advance(1)
        }
        XCTAssertEqual(mic.plan?.micSource, MicSourceKind.none, "call audio only, not silence")
        XCTAssertEqual(mic.unavailableInputs, [builtInMic.id])
        XCTAssertTrue(opener.opened[0].stopped)
        XCTAssertEqual(opener.opened.count, 1, "nothing else is opened (never the headset)")
        XCTAssertTrue(events.contains(.inputSilent(device: builtInMic.id)))
    }

    func testABuiltInMicThatDropsMidCallFallsBack() throws {
        let mic = make(speakers)
        mic.silenceTimeout = 3
        try mic.start(sampleRate: 24000) { _ in }
        for _ in 0..<10 {
            opener.open?.deliver(speech)
            clock.advance(1)
        }
        XCTAssertEqual(mic.plan?.device, builtInMic.id, "a working mic stays")
        clock.advance(7)
        XCTAssertEqual(mic.plan?.micSource, MicSourceKind.none, "the device stopped delivering")
        XCTAssertFalse(mic.isRunning)
    }

    func testAQuietButLiveMicStays() throws {
        let mic = make(speakers)
        mic.silenceTimeout = 3
        try mic.start(sampleRate: 24000) { _ in }
        let quiet = [Float](repeating: 0.000_01, count: 480)
        for _ in 0..<30 {
            opener.open?.deliver(quiet)
            clock.advance(1)
        }
        XCTAssertEqual(mic.plan?.device, builtInMic.id)
        XCTAssertTrue(mic.unavailableInputs.isEmpty)
    }

    func testASetAsideMicIsTriedAgainWhenTheRoutesChange() throws {
        let mic = make(speakers)
        mic.silenceTimeout = 3
        try mic.start(sampleRate: 24000) { _ in }
        clock.advance(4)
        XCTAssertEqual(mic.plan?.micSource, MicSourceKind.none)
        routes.set(speakers)
        clock.advance(1)
        XCTAssertEqual(mic.plan?.micSource, MicSourceKind.none, "its own device changes don't bring it back")
        routes.set(AudioRoutes(output: speakersOut, outputSource: .headphones, defaultInput: builtInMic, builtInInput: builtInMic))
        clock.advance(1)
        XCTAssertEqual(mic.plan?.device, builtInMic.id, "a real route change tries it again")
        XCTAssertTrue(mic.unavailableInputs.isEmpty)
    }

    func testOnlyTheBuiltInMicIsWatched() throws {
        let mic = make(AudioRoutes(output: speakersOut, outputSource: .speakers, defaultInput: usbMic, builtInInput: builtInMic))
        mic.silenceTimeout = 3
        try mic.start(sampleRate: 24000) { _ in }
        clock.advance(10)
        XCTAssertEqual(mic.plan?.device, usbMic.id)
    }

    func testStopForgetsASetAsideMic() throws {
        let mic = make(speakers)
        mic.silenceTimeout = 3
        try mic.start(sampleRate: 24000) { _ in }
        clock.advance(4)
        mic.stop()
        XCTAssertTrue(mic.unavailableInputs.isEmpty)
        try mic.start(sampleRate: 24000) { _ in }
        XCTAssertEqual(mic.plan?.device, builtInMic.id, "the next call tries it again")
    }

    // MARK: diagnostics

    func testDiagnosticsApplyAtOnceOnSpeakersOnly() throws {
        let mic = make(speakers)
        try mic.start(sampleRate: 24000) { _ in }
        mic.setDiagnostics(MicDiagnostics(speakerVoiceProcessing: false))
        XCTAssertEqual(opener.opened.count, 2)
        XCTAssertEqual(opener.open?.plan.processing.voiceProcessing, false)
        mic.setDiagnostics(MicDiagnostics(speakerVoiceProcessing: false))
        XCTAssertEqual(opener.opened.count, 2, "same diagnostics: no restart")
        routes.set(bluetooth)
        clock.advance(1)
        mic.setDiagnostics(MicDiagnostics(speakerVoiceProcessing: true))
        XCTAssertEqual(opener.open?.plan.processing.voiceProcessing, false, "headphones ignore it")
    }
}

final class Box: @unchecked Sendable { var count = 0 }

extension Array {
    var single: Element? { count == 1 ? first : nil }
}
