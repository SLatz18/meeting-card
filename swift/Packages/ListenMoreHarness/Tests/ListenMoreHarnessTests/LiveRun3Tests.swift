import XCTest
import ListenMoreCore
@testable import ListenMoreHarness

/// Fixes from the third live run (e2e6b84 on the box).
final class LiveRun3Tests: XCTestCase {
    let config = try! ListenMoreConfig.builtIn()

    /// pause: the paused y2 cut-in would fire past the cooldown of the pre-Pause interrupt even at the
    /// late end of that cue's live window, for TTS from the synthetic 2.6 words/s up to a fast 3.4.
    func testPausedCutInIsPastAPrePauseCueCooldown() throws {
        let s = Scenarios.pause
        for wordsPerS in [2.6, 3.0, 3.4] {
            let shapes = Dictionary(uniqueKeysWithValues: s.lines.map { line -> (String, ClipShape) in
                let voiced = line.seconds ?? Double(line.words.count) / wordsPerS
                return (line.id, ClipShape(lead: 0, voiced: voiced, total: voiced))
            })
            let t = try Timeline.realize(s, shapes: shapes)
            let pre = try XCTUnwrap(CueOracle.expected(t, config: config, facts: .init(keyless: false, gptStopT: nil, mode: .live)).cues.first)
            let y2 = try XCTUnwrap(t.line("y2"))
            let y2Fire = y2.start + config.local.cutInBackchannelMaxMs / 1000
            XCTAssertTrue(t.windows(.pause, .resume, end: t.duration).contains { $0.contains(y2Fire) }, "y2 cuts in while paused")
            XCTAssertGreaterThanOrEqual(y2Fire - pre.window.upperBound, config.cues.cooldownS, "at \(wordsPerS) words/s")
        }
    }

    /// The judge-off mute-unmute take around its false interrupt: Them quiet 28.56-29.16 s at a comma,
    /// You's first words back with comma pauses. The diagnostics list both sides' pauses, so a live run
    /// shows what ended the first words back's exemption.
    func testCutInDiagnosticsListBothSidesPauses() {
        func voiced(_ t: Double, _ spans: [(Double, Double)]) -> Bool { spans.contains { t > $0.0 + 1e-9 && t <= $0.1 + 1e-9 } }
        let them: [(Double, Double)] = [(25.98, 28.56), (29.16, 31.9)]
        let you: [(Double, Double)] = [(28.28, 28.80), (29.12, 29.94), (30.38, 32.5)]
        var trace = ShadowTrace()
        for k in 1...1700 {
            let t = Double(k) * config.frameS
            trace.frames.append(.init(t: t, meRaw: voiced(t, you), meActive: false, othersRaw: voiced(t, them), othersActive: false))
        }
        let span = 27.0...33.0
        let themQuiet = trace.quietStretches(in: span, \.othersRaw, frameS: config.frameS)
        XCTAssertEqual(themQuiet.count, 1)
        XCTAssertEqual(themQuiet.first?.from ?? 0, 28.56, accuracy: 1e-9)
        XCTAssertEqual(themQuiet.first?.to ?? 0, 29.16, accuracy: 1e-9)
        XCTAssertEqual(trace.quietStretches(in: span, \.meRaw, frameS: config.frameS).count, 2, "You's comma pauses (0.32 and 0.44 s)")
        let text = trace.explainCutIn(around: 30.0...31.6, config: config)
        XCTAssertTrue(text.contains("Them quiet 28.56-29.16 (0.60 s)"), text)
        XCTAssertTrue(text.contains("You quiet 28.80-29.12 (0.32 s), 29.94-30.38 (0.44 s)"), text)
        let back = trace.explainFirstWordsBack(unmute: 27.98, config: config)
        XCTAssertTrue(back.hasPrefix("first words back after Unmute at 27.98 s, 28.28-32.00 s:"), back)
        XCTAssertTrue(back.contains("You's longest pause 0.44 s (29.94-30.38) (ends the exemption over 0.50 s)"), back)
        XCTAssertTrue(back.contains("Them's longest pause 0.60 s (28.56-29.16) (a new utterance from 1.00 s)"), back)
    }
}

/// Fixes from the fourth live run (0390f5e on the box).
@MainActor
final class LiveRun4Tests: XCTestCase {
    /// A judged not_listening on You's reply, then You cut in a few seconds later, inside the global
    /// cooldown but after the verdict's `on_screen_s`: the interrupt answers only to its own cooldown and shows.
    static let judgedThenCutIn = Scenario(
        name: "judged-then-cut-in",
        summary: "a judged not_listening, then a cut-in inside the global cooldown",
        lines: [
            Line("a1", .themA, "Let me walk you through the plan for the release next week.", .at(0.5)),
            Line("y1", .you, "Okay, I see what you mean about the plan.", .after("a1", gap: 1.0)),
            Line("a2", .themA, "The first step is the database move and then the services follow one at a time over the weekend.", .after("y1", gap: 1.0)),
            Line("y2", .you, "Sorry to cut in. I think the services should go first because they are smaller.", .beforeEnd("a2", lead: 4.0)),
        ])

    /// The same verdict, then a cut-in while it is still on screen: the policy drops the interrupt.
    static let judgedThenQuickCutIn = Scenario(
        name: "judged-then-quick-cut-in",
        summary: "a judged not_listening, then a cut-in while it is on screen",
        lines: [
            Line("a1", .themA, "Let me walk you through the plan for the release next week.", .at(0.5)),
            Line("y1", .you, "Okay, I see what you mean about the plan.", .after("a1", gap: 1.0)),
            Line("a2", .themA, "The first step is the database move and then the services follow one at a time over the weekend.", .after("y1", gap: 0.3)),
            Line("y2", .you, "Sorry to cut in. I think the services should go first because they are smaller.", .into("a2", offset: 0.6)),
        ])

    /// The same verdict, then Them's question You talk past: the missed-question cue is a transcript
    /// rule's, so the verdict's global cooldown still holds it.
    static let judgedThenMissedQuestion = Scenario(
        name: "judged-then-missed-question",
        summary: "a judged not_listening, then a missed question inside the global cooldown",
        lines: [
            Line("a1", .themA, "Let me walk you through the plan for the release next week.", .at(0.5)),
            Line("y1", .you, "Okay, I see what you mean about the plan.", .after("a1", gap: 1.0)),
            Line("a2", .themA, "Good. What date should we pick for the customer pilot?", .after("y1", gap: 1.0)),
            Line("y2", .you, "I was thinking we should also tidy up the onboarding emails and move the team lunch to the afternoon.", .after("a2", gap: 1.0)),
            Line("a3", .themA, "Okay, let us come back to that later.", .after("y2", gap: 2.5)),
        ])

    /// cost-cap's judge-on take at 01809d9 hit the budget cap at 7.2 s, in the middle of You's first
    /// words: only Them's line was transcribed, and the saved transcript held just that line. Forced
    /// offline with a $0.0019 budget (cap at 7.5 s), the Them-only file passes; a transcribed side's line
    /// without its time or label fails.
    func testSavedTranscriptAfterAnEarlyCapHasLinesOnlyForTheSidesTranscribed() async throws {
        var s = Scenarios.costCap
        s.budgetUsd = 0.0019
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("lm-harness-test-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: out) }
        let summary = try await Harness.run(HarnessOptions(mode: .offline, scenarios: [s], outputDirectory: out, environment: [:]))
        let r = try XCTUnwrap(summary.results.first)
        XCTAssertEqual(r.check("cost cap (T5)")?.passed, true, r.check("cost cap (T5)")?.detail ?? "")
        XCTAssertEqual(r.check("transcription")?.detail.contains("lines captioned 1/1"), true, "only Them's line before the cap")
        XCTAssertEqual(r.check("opt-in-transcript")?.passed, true, r.check("opt-in-transcript")?.detail ?? "")

        let them = "**[00:00:05] Them:** Here is the short version of the budget review for this quarter.\n"
        let you = "**[00:00:07] You:** Okay, go on.\n"
        XCTAssertTrue(Checks.timesAndLabels(them, labels: ["Them"]))
        XCTAssertTrue(Checks.timesAndLabels(them + you, labels: ["You", "Them"]))
        XCTAssertFalse(Checks.timesAndLabels(them, labels: ["You", "Them"]), "You was transcribed but has no line")
        XCTAssertFalse(Checks.timesAndLabels("**Them:** Here is the short version.\n", labels: ["Them"]), "no time")
        XCTAssertFalse(Checks.timesAndLabels("**[00:00:05]** Here is the short version.\n", labels: ["Them"]), "no label")
        XCTAssertFalse(Checks.timesAndLabels("[00:00:05] Them: Here is the short version.\n", labels: ["Them"]), "not the line format")
        XCTAssertFalse(Checks.timesAndLabels("# Call transcript\n", labels: []), "at least one line")
        XCTAssertTrue(Checks.timesAndLabels("**[00:00:05] Them 2:** Here is the short version. ^l1\n", labels: ["Them"]), "a numbered voice within Them")
        XCTAssertTrue(Checks.timesAndLabels("**[00:00:05] Dev\\_Ops:** Here is the short version. ^l1\n", labels: ["Dev_Ops"]), "a Markdown-escaped label")
        XCTAssertFalse(Checks.timesAndLabels("**[00:00:05] Dev_Ops:** Here is the short version.\n", labels: ["Dev_Ops"]), "the note never writes a label unescaped")
    }

    func run(_ s: Scenario) async throws -> ScenarioResult {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("lm-harness-test-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: out) }
        let summary = try await Harness.run(HarnessOptions(mode: .offline, scenarios: [s], outputDirectory: out,
                                                           environment: [:], offlineNotListeningOn: "what you mean"))
        return try XCTUnwrap(summary.results.first)
    }

    /// Until this ruling the policy held this cut-in for the global cooldown (and this test asserted
    /// the miss); after a judged cue a local interrupt now waits only for its own cooldown.
    func testCutInAfterAJudgedCueShows() async throws {
        let r = try await run(Self.judgedThenCutIn)
        XCTAssertEqual(r.cues.falseCues.map(\.type), [.notListening], "offline, the judge's cue isn't tolerated")
        XCTAssertEqual(r.cues.missed.map(\.type), [])
        let verdict = try XCTUnwrap(r.cues.falseCues.first), cutIn = try XCTUnwrap(r.cues.outcomes.first?.actual)
        XCTAssertEqual(cutIn.type, .interrupt)
        XCTAssertGreaterThanOrEqual(cutIn.t - verdict.t, 4.5, "after the verdict left the screen")
        XCTAssertLessThan(cutIn.t - verdict.t, 20, "inside the global cooldown")
    }

    func testHeldCueIsNamedInTheDiagnostics() async throws {
        let r = try await run(Self.judgedThenQuickCutIn)
        XCTAssertEqual(r.cues.falseCues.map(\.type), [.notListening], "offline, the judge's cue isn't tolerated")
        XCTAssertEqual(r.cues.missed.map(\.type), [.interrupt])
        let held = r.diagnostics.first { $0.hasPrefix("missed interrupt: the engine raised it") }
        XCTAssertNotNil(held, "\(r.diagnostics)")
        XCTAssertTrue(held?.contains("held it (the last cue still on screen); last cue shown: not_listening at") ?? false, held ?? "")
    }

    func testGlobalCooldownHoldIsNamedInTheDiagnostics() async throws {
        let r = try await run(Self.judgedThenMissedQuestion)
        XCTAssertEqual(r.cues.falseCues.map(\.type), [.notListening], "offline, the judge's cue isn't tolerated")
        XCTAssertEqual(r.cues.missed.map(\.type), [.missedQuestion])
        let held = r.diagnostics.first { $0.hasPrefix("missed missed_question: the engine raised it") }
        XCTAssertNotNil(held, "\(r.diagnostics)")
        XCTAssertTrue(held?.contains("held it (global cooldown); last cue shown: not_listening at") ?? false, held ?? "")
    }
}
