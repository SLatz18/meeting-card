import XCTest
@testable import MeetingCardCore

/// Where the coach log events are raised in the App and the Mac layer (hostless tests read the sources).
final class CoachLogWiringTests: XCTestCase {
    static let swiftDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    func read(_ path: String) throws -> String {
        try String(contentsOf: Self.swiftDir.appendingPathComponent(path), encoding: .utf8)
    }

    func testAppStartedLogsVersionBuildAndOS() throws {
        let src = try read("App/CoachController.swift")
        XCTAssertTrue(src.contains("CoachLog.record(.appStarted(version: LogToken.version(info?[\"CFBundleShortVersionString\"] as? String)"))
        XCTAssertTrue(src.contains("build: LogToken.version(info?[\"CFBundleVersion\"] as? String)"))
        XCTAssertTrue(src.contains("operatingSystemVersion"))
    }

    /// Quit ends the session with reason quit: the app delegate hands over before it exits.
    func testQuitEndsTheSessionWithReasonQuit() throws {
        let delegate = try read("App/Controller.swift")
        let terminate = try XCTUnwrap(delegate.components(separatedBy: "func applicationWillTerminate(_ n: Notification) {").dropFirst().first?.components(separatedBy: "\n    }").first)
        XCTAssertTrue(terminate.contains("coach?.willQuit()"))
        let controller = try read("App/CoachController.swift")
        XCTAssertTrue(controller.contains("service?.quit()"))
        let service = try read("Packages/ListenMoreKit/Sources/ListenMoreMac/CoachService.swift")
        XCTAssertTrue(service.contains("public func quit() { session.quit() }"))
    }

    /// Screen recording has no "denied" answer from the preflight, only "not granted".
    func testScreenRecordingPreflightFalseIsNotGranted() throws {
        let service = try read("Packages/ListenMoreKit/Sources/ListenMoreMac/CoachService.swift")
        XCTAssertTrue(service.contains("CGPreflightScreenCaptureAccess() ? .granted : .notGranted"))
        XCTAssertFalse(service.contains("CGPreflightScreenCaptureAccess() ? .granted : .denied"))
    }

    /// A tap failure is one line with its step, and the session doesn't add a second.
    func testTapFailureIsOneLineWithItsStep() throws {
        let tap = try read("Packages/ListenMoreKit/Sources/ListenMoreMac/ProcessTapCapture.swift")
        XCTAssertTrue(tap.contains("enum TapError: LoggedFailure"))
        XCTAssertEqual(tap.components(separatedBy: "CoachLog.record(").count - 1, 1)
        XCTAssertTrue(tap.contains("step: step"))
        for step in ["createTap", "tapFormat", "createAggregate", "ioProc", "start"] { XCTAssertTrue(tap.contains("check(.\(step),"), step) }
        let session = try read("Packages/ListenMoreKit/Sources/ListenMoreCore/CoachSession.swift")
        XCTAssertTrue(session.contains("if !(error is LoggedFailure)"))
    }

    func testMicOpenFailureNamesItsStep() throws {
        let mic = try read("Packages/ListenMoreKit/Sources/ListenMoreMac/MicCapture.swift")
        for step in [".voiceProcessing", ".device", ".format", ".engineStart"] { XCTAssertTrue(mic.contains("step = \(step)") || mic.contains("MicOpenStep\(step)"), step) }
        XCTAssertTrue(mic.contains("throw Self.failure(error, step: step)"))
        XCTAssertTrue(mic.contains("case let .openFailed(plan, step, status):"))
    }

    /// UI snapshot runs build many controllers: every one is given a discarding sink, so none writes the real log.
    func testSnapshotRunsNeverWriteTheRealLog() throws {
        let snaps = try read("App/UISnapshots.swift")
        let controllers = snaps.components(separatedBy: "CoachController(").count - 1
        let discarding = snaps.components(separatedBy: "CoachController(defaults: defaults, coachLogSink: DiscardingCoachLog(), ").count - 1
        XCTAssertGreaterThanOrEqual(controllers, 10)
        XCTAssertEqual(discarding, controllers, "every snapshot controller gets the discarding sink")
        let controller = try read("App/CoachController.swift")
        XCTAssertTrue(controller.contains("CoachLog.install(coachLogSink ?? coachLogFile)"))
        XCTAssertTrue(controller.contains("coachLogSink: CoachLogSink? = nil"), "the app writes the file unless a sink is injected")
    }

    /// Quitting waits for the log's own thread to finish writing.
    func testQuitFlushesTheLog() throws {
        let controller = try read("App/CoachController.swift")
        let quit = try XCTUnwrap(controller.components(separatedBy: "    func willQuit() {").dropFirst().first?.components(separatedBy: "\n    }\n").first)
        XCTAssertTrue(quit.contains("service?.quit()"))
        XCTAssertTrue(quit.contains("CoachLog.flush()"))
    }
}
