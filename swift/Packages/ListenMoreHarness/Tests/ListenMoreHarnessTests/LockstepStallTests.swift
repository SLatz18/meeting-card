import XCTest
import ListenMoreCore
@testable import ListenMoreHarness

/// Offline lockstep waits for each final transcript the scripted server sent to reach the caption feed.
/// The GPT layer legitimately drops some finals, so one that never arrives must cost one barrier timeout,
/// not a wait on every later frame; and a run that keeps losing finals stops instead of stalling.
@MainActor
final class LockstepStallTests: XCTestCase {
    static let scenario = Scenario(
        name: "lockstep-drops",
        summary: "six short alternating lines",
        lines: [
            Line("a1", .themA, "The draft is ready for a first look.", .at(0.3)),
            Line("y1", .you, "Thanks, I will read it after lunch.", .after("a1", gap: 1.5)),
            Line("a2", .themA, "Take your time, there is no rush on it.", .after("y1", gap: 1.5)),
            Line("y2", .you, "I will send notes by the end of the day.", .after("a2", gap: 1.5)),
            Line("a3", .themA, "That works for the whole team on our side.", .after("y2", gap: 1.5)),
            Line("y3", .you, "Good, then we are agreed on the plan.", .after("a3", gap: 1.5)),
        ],
        tail: 2.0)

    func run(dropping drops: Int) async throws -> (record: RunRecord, seconds: TimeInterval) {
        let config = try ListenMoreConfig.builtIn()
        var services = try Harness.offlineServices(Self.scenario, config: config, voices: .synthetic)
        services.barrierTimeoutS = 1.0
        services.offlineServer?.dropNextFinals(drops)
        let dir = try RunDirectory.create()
        defer { dir.wipe() }
        let started = Date()
        let record = try await ScenarioRun(scenario: Self.scenario, services: services, workDir: dir.url).run()
        return (record, Date().timeIntervalSince(started))
    }

    func assertCountersAddUp(_ r: RunRecord, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(r.barrierTimeouts, r.callBarrierTimeouts + r.finalsBarrierTimeouts + r.engineBarrierTimeouts,
                       "call \(r.callBarrierTimeouts) + finals \(r.finalsBarrierTimeouts) + engine \(r.engineBarrierTimeouts)", file: file, line: line)
    }

    func testBaselineHasNoTimeouts() async throws {
        let (record, _) = try await run(dropping: 0)
        XCTAssertEqual(record.barrierTimeouts, 0)
        assertCountersAddUp(record)
        XCTAssertFalse(record.problems.contains("lockstep stalled"))
    }

    /// Digital silence on the call isn't a session problem on the scripted streams; a call that delivered
    /// no buffers and any other report still is.
    func testASilentCallReportIsNotASessionProblem() {
        XCTAssertFalse(ScenarioRun.isSessionProblem("callAudioSilent(ListenMoreCore.SilenceKind.digitalSilence)"))
        XCTAssertFalse(ScenarioRun.isSessionProblem("transcriberClearRejected"))
        XCTAssertTrue(ScenarioRun.isSessionProblem("callAudioSilent(ListenMoreCore.SilenceKind.noBuffers)"))
        XCTAssertTrue(ScenarioRun.isSessionProblem("keyUnreadable"))
        XCTAssertTrue(ScenarioRun.isSessionProblem("lockstep stalled"))
    }

    func testOneDroppedFinalCostsOneTimeoutNotOnePerFrame() async throws {
        let (record, seconds) = try await run(dropping: 1)
        XCTAssertEqual(record.finalsBarrierTimeouts, 1, "re-baselined after the dropped final")
        assertCountersAddUp(record)
        XCTAssertFalse(record.problems.contains("lockstep stalled"))
        XCTAssertLessThan(seconds, 60)
        let result = Checks.evaluate(record)
        XCTAssertEqual(result.check("lockstep")?.passed, false, "the timeout is still reported")
    }

    func testARunThatKeepsLosingFinalsStopsAfterFiveTimeouts() async throws {
        let (record, seconds) = try await run(dropping: 1000)
        XCTAssertGreaterThanOrEqual(record.barrierTimeouts, 5)
        XCTAssertGreaterThanOrEqual(record.finalsBarrierTimeouts, 1)
        assertCountersAddUp(record)
        XCTAssertEqual(record.finalsBarrierTimeouts, record.barrierTimeouts - record.callBarrierTimeouts - record.engineBarrierTimeouts,
                       "finals timeouts are what is left after the call-frame and engine waits")
        XCTAssertTrue(record.problems.contains("lockstep stalled"))
        XCTAssertLessThan(seconds, 60)
        let result = Checks.evaluate(record)
        XCTAssertEqual(result.check("lockstep")?.passed, false)
        XCTAssertEqual(result.check("session-problems")?.passed, false, "the stall is a named problem")
    }
}
