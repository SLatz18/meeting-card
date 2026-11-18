import XCTest
import ListenMoreCore
@testable import ListenMoreHarness

/// The checks catch a broken engine: each test simulates one regression (engine-only config, or a
/// control that does nothing) and expects the named check to fail. The oracle keeps the built-in rules.
@MainActor
final class MutationTests: XCTestCase {
    func run(_ scenario: Scenario, overrides: [String: Any] = [:], ignoring: Set<ControlKind> = []) async throws -> ScenarioResult {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("lm-harness-test-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: out) }
        let summary = try await Harness.run(HarnessOptions(mode: .offline, scenarios: [scenario], outputDirectory: out, environment: [:],
                                                           engineOverrides: overrides, ignoredControls: ignoring))
        return try XCTUnwrap(summary.results.first)
    }

    func assertFails(_ r: ScenarioResult, _ names: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertFalse(r.passed, "the regression went unnoticed", file: file, line: line)
        for n in names {
            XCTAssertEqual(r.check(n)?.passed, false, "\(n) should fail: \(r.check(n)?.detail ?? "missing")", file: file, line: line)
        }
    }

    func testNoUnmuteGraceIsCaught() async throws {
        let r = try await run(Scenarios.muteUnmute, overrides: ["local": ["unmute_grace_s": 0.0]])
        assertFails(r, ["coaching", "unmute grace: no false cue"])
    }

    func testMuteThatDoesNothingIsCaught() async throws {
        let r = try await run(Scenarios.muteUnmute, ignoring: [.mute, .unmute])
        assertFails(r, ["muted: zero mic frames", "muted: no You lines, Them continue", "muted: nothing of You kept", "muted: indicator"])
    }

    func testPauseThatDoesNothingIsCaught() async throws {
        let r = try await run(Scenarios.pause, ignoring: [.pause, .resume])
        assertFails(r, ["coaching", "paused: no frames, traffic or captions", "paused: engine stopped and restarted"])
    }

    func testMissedCutInIsCaught() async throws {
        let r = try await run(Scenarios.interruption, overrides: ["local": ["cut_in_min_overlap_ms": 5000]])
        assertFails(r, ["coaching"])
        XCTAssertEqual(r.cues.missed.map(\.type), [.interrupt])
    }

    func testEarlyMonologueIsCaught() async throws {
        let r = try await run(Scenarios.monologue, overrides: ["local": ["monologue_soft_s": 40]])
        assertFails(r, ["coaching"])
    }

    func testMissedQuestionTimingIsCaught() async throws {
        let r = try await run(Scenarios.missedQuestion, overrides: ["text": ["question_decide_words": 100]])
        assertFails(r, ["coaching"])
    }

    func testEarlyStopIsCaught() async throws {
        let r = try await run(Scenarios.silenceToStop, overrides: ["trigger": ["stop_after_s": 10]])
        assertFails(r, ["silence: stops after stop_after_s"])
    }

    func testIgnoredSpeakerTagIsCaught() async throws {
        let r = try await run(Scenarios.twoThemVoices, ignoring: [.renameThem])
        assertFails(r, ["speaker name (X4)"])
    }

    func testTranscriptKeptAfterDeleteIsCaught() async throws {
        let r = try await run(Scenarios.missedQuestion, ignoring: [.deleteTranscript])
        assertFails(r, ["transcript-deleted-mid-call"])
    }
}

/// Offline runs are deterministic: the same cues and captions at the same times, every run.
@MainActor
final class DeterminismTests: XCTestCase {
    func timeline(_ scenario: Scenario) async throws -> [String] {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("lm-harness-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: out) }
        let summary = try await Harness.run(HarnessOptions(mode: .offline, scenarios: [scenario], outputDirectory: out, environment: [:]))
        let r = try XCTUnwrap(summary.results.first)
        let cues = (r.cues.outcomes.compactMap(\.actual) + r.cues.falseCues + r.cues.tolerated)
            .map { String(format: "cue %@ %.3f %.3f", $0.type.rawValue, $0.t, $0.engineT) }
        let tx = Speaker.allCases.map { s in "\(s.rawValue) \(r.transcription[s]?.latencies.map { String(format: "%.3f", $0) } ?? [])" }
        return cues.sorted() + tx
    }

    func testRepeatedRunsMatch() async throws {
        for s in [Scenarios.interruption, Scenarios.muteUnmute, Scenarios.missedQuestion] {
            let a = try await timeline(s)
            let b = try await timeline(s)
            XCTAssertEqual(a, b, s.name)
        }
    }
}
