import AVFoundation
import CoreAudio
import ListenMoreCore
@testable import ListenMoreMac
import XCTest

/// CI has no microphone: the engine path is pinned from the source, the routing through MicCapture
/// with routes that open no device, and the Core Audio mapping directly.
final class MicCaptureTests: XCTestCase {
    static let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/ListenMoreMac/MicCapture.swift")

    final class StaticRoutes: AudioRouteSource {
        var routes: AudioRoutes
        var observing = false
        init(_ routes: AudioRoutes) { self.routes = routes }
        func snapshot() -> AudioRoutes { routes }
        func observe(_ onChange: @escaping () -> Void) { observing = true }
        func stopObserving() { observing = false }
    }

    /// Bluetooth output on a Mac with no built-in mic: no mic is opened at all.
    static let desktopBluetooth = AudioRoutes(output: AudioDeviceInfo(id: 2, transport: .bluetooth),
                                              defaultInput: AudioDeviceInfo(id: 2, transport: .bluetooth), builtInInput: nil)

    func text() throws -> String { try String(contentsOf: Self.source, encoding: .utf8) }

    func block(after marker: String, in text: String) throws -> String {
        try XCTUnwrap(text.components(separatedBy: marker).dropFirst().first?.components(separatedBy: "\n    }\n").first, marker)
    }

    func testMinimumDuckingConfiguration() {
        let c = MicCapture.duckingConfiguration(MicProcessing.minimumDucking)
        XCTAssertFalse(c.enableAdvancedDucking.boolValue)
        XCTAssertEqual(c.duckingLevel, .min)
        XCTAssertEqual(c.duckingLevel.rawValue, 10)
    }

    func testEveryLevelMapsToApplesLevel() {
        let pairs: [(MicProcessing.DuckingLevel, AVAudioVoiceProcessingOtherAudioDuckingConfiguration.Level)] =
            [(.default, .default), (.min, .min), (.mid, .mid), (.max, .max)]
        for (ours, apple) in pairs {
            XCTAssertEqual(MicCapture.duckingConfiguration(.init(advanced: true, level: ours)).duckingLevel, apple)
        }
    }

    func testStandardDiagnosticsAndNothingOpenUntilStarted() {
        let mic = MicCapture(routes: StaticRoutes(Self.desktopBluetooth))
        XCTAssertEqual(mic.diagnostics, .standard)
        XCTAssertFalse(mic.isRunning)
        XCTAssertNil(mic.plan)
    }

    func testBluetoothWithoutABuiltInMicOpensNoDevice() throws {
        let routes = StaticRoutes(Self.desktopBluetooth)
        let mic = MicCapture(routes: routes)
        try mic.start(sampleRate: 24000) { _ in }
        XCTAssertEqual(mic.plan?.micSource, MicSourceKind.none)
        XCTAssertFalse(mic.isRunning, "no engine")
        XCTAssertTrue(routes.observing)
        mic.setMuted(true)
        XCTAssertTrue(mic.isMuted)
        XCTAssertNil(mic.plan)
        mic.setMuted(false)
        XCTAssertEqual(mic.plan?.route, .bluetooth)
        mic.stop()
        XCTAssertFalse(routes.observing)
        XCTAssertFalse(mic.isMuted)
    }

    func testEachOpenIsAFreshEngineSetUpInOrder() throws {
        let t = try text()
        let open = try block(after: "init(plan: MicPlan, sampleRate: Int", in: t)
        XCTAssertTrue(t.contains("final class EngineMicInput: MicInput {\n"))
        XCTAssertTrue(t.contains("    private let engine = AVAudioEngine()\n"), "one engine per input, discarded on close")
        let steps = ["try input.setVoiceProcessingEnabled(true)",
                     "input.voiceProcessingOtherAudioDuckingConfiguration = MicCapture.duckingConfiguration(ducking)",
                     "try Self.setDevice(device, on: input)", "input.installTap(onBus: 0", "try engine.start()"]
        let positions = try steps.map { try XCTUnwrap(open.range(of: $0), $0).lowerBound }
        XCTAssertEqual(positions, positions.sorted(), "voice processing, ducking, device, tap, start")
        XCTAssertTrue(open.contains("if plan.processing.voiceProcessing {"))
        XCTAssertTrue(open.contains(".AVAudioEngineConfigurationChange"), "a device change reopens it")
    }

    func testCloseReleasesTheEngineAndVoiceProcessing() throws {
        let release = try block(after: "private func release() {", in: try text())
        for step in ["engine.inputNode.removeTap(onBus: 0)", "engine.stop()", "try? engine.inputNode.setVoiceProcessingEnabled(false)",
                     "NotificationCenter.default.removeObserver(observer)"] {
            XCTAssertTrue(release.contains(step), step)
        }
        let tap = try XCTUnwrap(release.range(of: "removeTap"))
        let stop = try XCTUnwrap(release.range(of: "engine.stop()"))
        XCTAssertLessThan(tap.lowerBound, stop.lowerBound, "no buffer after close returns")
    }

    func testRouteMicSourceAndVoiceProcessingAreLogged() throws {
        let t = try text()
        let opened = try XCTUnwrap(t.components(separatedBy: "\n").first { $0.contains("Log.capture.info(\"mic open:") })
        for field in ["route \\(plan.route.rawValue, privacy: .public)", "micSource \\(plan.micSource.rawValue, privacy: .public)",
                      "voiceProcessing \\(voiceProcessing, privacy: .public)", "advanced ducking", "ducking level"] {
            XCTAssertTrue(opened.contains(field), field)
        }
    }

    func testCoreAudioTransports() {
        XCTAssertEqual(CoreAudioRoutes.transport(kAudioDeviceTransportTypeBuiltIn), .builtIn)
        XCTAssertEqual(CoreAudioRoutes.transport(kAudioDeviceTransportTypeBluetooth), .bluetooth)
        XCTAssertEqual(CoreAudioRoutes.transport(kAudioDeviceTransportTypeBluetoothLE), .bluetooth)
        XCTAssertEqual(CoreAudioRoutes.transport(kAudioDeviceTransportTypeUSB), .usb)
        XCTAssertEqual(CoreAudioRoutes.transport(kAudioDeviceTransportTypeHDMI), .other)
        XCTAssertEqual(CoreAudioRoutes.transport(kAudioDeviceTransportTypeAirPlay), .other)
        XCTAssertEqual(CoreAudioRoutes.fourCC("hdpn"), 0x6864_706E)
        XCTAssertEqual(CoreAudioRoutes.fourCC("ispk"), 0x6973_706B)
    }

    func testCallModeReadsCoreAudioStateAndOurOwnMicOnly() throws {
        let state = CoreAudioRoutes.outputCallState()
        if state.device == nil { XCTAssertNil(state.inputStreamActive, "nothing to read: undecided") }
        XCTAssertFalse(MicCapture(routes: StaticRoutes(Self.desktopBluetooth)).headphonesInCallMode() && state.transport != .bluetooth)
        let body = try block(after: "public func headphonesInCallMode() -> Bool {", in: try text())
        XCTAssertTrue(body.contains("CoreAudioRoutes.outputCallState()"))
        XCTAssertTrue(body.contains("ourMicDevice: mic.deviceID ?? mic.plan?.device"))
    }

    /// The device in use is read back from Core Audio (this process's input devices), not the request.
    func testInputInUseIsReadBackFromCoreAudio() throws {
        let t = try text()
        let routes = try String(contentsOf: Self.source.deletingLastPathComponent().appendingPathComponent("AudioRoutes.swift"), encoding: .utf8)
        let readBack = try block(after: "public static func inputDevicesInUse(pid: pid_t = getpid()) -> [UInt32]? {", in: routes)
        XCTAssertTrue(readBack.contains("kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeInput"))
        XCTAssertTrue(readBack.contains("kAudioAggregateDevicePropertyActiveSubDeviceList"), "voice processing's aggregate is expanded")
        XCTAssertTrue(t.contains("public func inputDevicesInUse() -> [UInt32]? { CoreAudioRoutes.inputDevicesInUse() }"))
        _ = CoreAudioRoutes.inputDevicesInUse()
    }

    /// A built-in mic must be alive and allowed as an input (a closed lid can leave it listed).
    func testBuiltInMicMustBeAliveAndSelectable() throws {
        let routes = try String(contentsOf: Self.source.deletingLastPathComponent().appendingPathComponent("AudioRoutes.swift"), encoding: .utf8)
        let pick = try block(after: "static func builtInInput() -> AudioObjectID? {", in: routes)
        XCTAssertTrue(pick.contains("kAudioDevicePropertyDeviceIsAlive"))
        XCTAssertTrue(pick.contains("kAudioDevicePropertyDeviceCanBeDefaultDevice"))
    }

    func testRoutesSnapshotAndObservationRunOnThisMac() {
        let routes = CoreAudioRoutes()
        let snap = routes.snapshot()
        if let input = snap.builtInInput { XCTAssertEqual(input.transport, .builtIn) }
        routes.observe {}
        routes.stopObserving()
    }
}
