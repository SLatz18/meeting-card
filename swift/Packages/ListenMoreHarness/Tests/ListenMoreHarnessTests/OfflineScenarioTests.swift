import XCTest
import ListenMoreCore
@testable import ListenMoreHarness

/// Every scenario, offline: synthetic audio through the real CoachSession / LocalCoachEngine /
/// GptLayer / LiveTranscriber with the scripted realtime server. Deterministic, no network.
@MainActor
final class OfflineScenarioTests: XCTestCase {
    func run(_ scenario: Scenario, file: StaticString = #filePath, line: UInt = #line) async throws -> ScenarioResult {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("lm-harness-test-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: out) }
        let summary = try await Harness.run(HarnessOptions(mode: .offline, scenarios: [scenario], outputDirectory: out, environment: [:]))
        let r = try XCTUnwrap(summary.results.first)
        for f in r.failures { XCTFail("\(scenario.name): \(f.name): \(f.detail)", file: file, line: line) }
        XCTAssertTrue(summary.leaks.isEmpty, file: file, line: line)
        return r
    }

    func cues(_ r: ScenarioResult) -> [String] {
        (r.cues.outcomes.compactMap(\.actual) + r.cues.falseCues).sorted { $0.t < $1.t }
            .map { $0.type.rawValue + ($0.level.map { "/" + $0.rawValue } ?? "") }
    }

    func testInterruption() async throws {
        let r = try await run(Scenarios.interruption)
        XCTAssertEqual(cues(r), ["interrupt"])
        XCTAssertEqual(r.speakers.accuracy, 1)
        XCTAssertEqual(r.totalErrors.errors, 0)
    }

    func testMonologue() async throws {
        let r = try await run(Scenarios.monologue)
        XCTAssertEqual(cues(r), ["monologue/soft"])
    }

    func testMissedQuestion() async throws {
        let r = try await run(Scenarios.missedQuestion)
        XCTAssertEqual(cues(r), ["missed_question/soft"])
        XCTAssertNotNil(r.check("transcript-deleted-mid-call"))
    }

    func testMuteUnmute() async throws {
        let r = try await run(Scenarios.muteUnmute)
        XCTAssertEqual(cues(r), ["interrupt"])
        XCTAssertEqual(r.checks.filter { $0.name.hasPrefix("muted:") || $0.name.hasPrefix("unmute") }.count, 5)
    }

    func testPause() async throws {
        let r = try await run(Scenarios.pause)
        XCTAssertEqual(cues(r), ["interrupt", "interrupt"], "one before Pause, one after Resume")
    }

    func testSilenceToStop() async throws {
        let r = try await run(Scenarios.silenceToStop)
        XCTAssertEqual(cues(r), [])
        XCTAssertNotNil(r.check("keep-nothing"))
    }

    func testTwoThemVoices() async throws {
        let r = try await run(Scenarios.twoThemVoices)
        XCTAssertEqual(cues(r), [])
        XCTAssertEqual(r.speakers.multiThem, .mergedAsThem)
    }

    func testNoKey() async throws {
        let r = try await run(Scenarios.noKey)
        XCTAssertEqual(cues(r), ["interrupt"])
    }

    func testCostCap() async throws {
        let r = try await run(Scenarios.costCap)
        XCTAssertEqual(cues(r), ["interrupt"])
    }
}
