import AVFoundation
import ListenMoreCore
@testable import ListenMoreMac
import XCTest

/// Voice processing stays on with other-audio ducking at its minimum, advanced ducking off; stopping
/// releases the engine and voice processing; both states reach the unified log. CI has no
/// microphone, so the device path is pinned from the source.
final class MicCaptureTests: XCTestCase {
    static let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().appendingPathComponent("Sources/ListenMoreMac/MicCapture.swift")

    func body(of signature: String, in text: String) throws -> String {
        try XCTUnwrap(text.components(separatedBy: signature).dropFirst().first?.components(separatedBy: "\n    }\n").first,
                      signature)
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
        XCTAssertTrue(MicCapture.duckingConfiguration(.init(advanced: true, level: .min)).enableAdvancedDucking.boolValue)
    }

    func testDefaultProcessingIsThisMacsPlan() {
        let mic = MicCapture()
        XCTAssertEqual(mic.processing, MicProcessing.plan(macOS: ProcessInfo.processInfo.operatingSystemVersion))
        XCTAssertTrue(mic.processing.voiceProcessing, "the Kit's minimum macOS is 14")
        XCTAssertEqual(mic.processing.ducking, MicProcessing.minimumDucking)
        XCTAssertFalse(mic.isRunning)
        XCTAssertNil(mic.applied)
    }

    func testStartSetsTheDuckingBeforeTheEngineRuns() throws {
        let text = try String(contentsOf: Self.source, encoding: .utf8)
        let start = try body(of: "public func start(sampleRate: Int", in: text)
        let enable = try XCTUnwrap(start.range(of: "try input.setVoiceProcessingEnabled(true)"))
        let duck = try XCTUnwrap(start.range(of: "input.voiceProcessingOtherAudioDuckingConfiguration = Self.duckingConfiguration(ducking)"))
        let run = try XCTUnwrap(start.range(of: "try engine.start()"))
        XCTAssertLessThan(enable.lowerBound, duck.lowerBound, "ducking is set on an enabled voice-processing node")
        XCTAssertLessThan(duck.lowerBound, run.lowerBound)
        XCTAssertTrue(start.contains("if processing.voiceProcessing {"))
        XCTAssertTrue(start.contains("let applied = Self.readBack(input)"), "the log reports what the engine applied")
    }

    func testStopReleasesTheEngineAndVoiceProcessing() throws {
        let text = try String(contentsOf: Self.source, encoding: .utf8)
        let stop = try body(of: "public func stop()", in: text)
        for step in ["engine.inputNode.removeTap(onBus: 0)", "engine.stop()", "try? engine.inputNode.setVoiceProcessingEnabled(false)",
                     "isRunning = false", "applied = nil"] {
            XCTAssertTrue(stop.contains(step), step)
        }
    }

    func testVoiceProcessingAndDuckingAreLogged() throws {
        let text = try String(contentsOf: Self.source, encoding: .utf8)
        let started = try XCTUnwrap(text.components(separatedBy: "\n").first { $0.contains("Log.capture.info(\"mic started") })
        for field in ["voice processing \\(input.isVoiceProcessingEnabled, privacy: .public)",
                      "advanced ducking \\(applied.ducking?.advanced ?? false, privacy: .public)",
                      "ducking level \\(applied.ducking?.level.rawValue ?? -1, privacy: .public)"] {
            XCTAssertTrue(started.contains(field), field)
        }
        let stopped = try XCTUnwrap(text.components(separatedBy: "\n").first { $0.contains("Log.capture.info(\"mic stopped") })
        XCTAssertTrue(stopped.contains("voice processing \\(self.engine.inputNode.isVoiceProcessingEnabled, privacy: .public)"))
    }
}
