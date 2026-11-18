import XCTest
import ListenMoreCore
@testable import ListenMoreHarness

/// After a judged cue a local interrupt waits only for its own cooldown. Every scenario, as shipped and
/// with the gaps that kept its cues clear of a verdict's global cooldown taken out, runs offline with a
/// judge that answers not_listening to every call: no cue shows that the rules don't call for (the
/// judge's verdicts aside), no two cues are closer than `on_screen_s`, and judged cues stay a global
/// cooldown apart.
@MainActor
final class JudgedCueSpacingTests: XCTestCase {
    /// The gaps before the verdict-clear spacing (a5 after y4, a2 after y1, a2 after y1).
    static let unspaced: [String: (line: String, start: Anchor)] = [
        "mute-unmute": ("a5", .after("y4", gap: 3.0)),
        "missed-question": ("a2", .after("y1", gap: 15.0)),
        "cost-cap": ("a2", .after("y1", gap: 1.5)),
    ]

    static func withoutSpacing(_ s: Scenario) -> Scenario {
        guard let gap = unspaced[s.name] else { return s }
        var out = s
        out.lines = s.lines.map { line in
            var l = line
            if l.id == gap.line { l.start = gap.start }
            return l
        }
        return out
    }

    /// In every judge request (the response format's name).
    static let everyCall = "listen_more_cue"

    func run(_ s: Scenario) async throws -> ScenarioResult {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("lm-harness-test-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: out) }
        let summary = try await Harness.run(HarnessOptions(mode: .offline, scenarios: [s], outputDirectory: out, environment: [:],
                                                           offlineNotListeningOn: Self.everyCall))
        return try XCTUnwrap(summary.results.first)
    }

    func testUnspacedVariantMovesOnlyThoseThreeLines() async throws {
        let changed = Scenarios.all.filter { s in
            let v = Self.withoutSpacing(s)
            return zip(s.lines, v.lines).contains { "\($0.start)" != "\($1.start)" }
        }
        XCTAssertEqual(changed.map(\.name), ["missed-question", "mute-unmute", "cost-cap"])
    }

    func testAJudgeOnEveryReplyAddsNoOtherCue() async throws {
        let config = try ListenMoreConfig.builtIn()
        var problems: [String] = []
        var cutInsAfterAVerdict = 0
        for spaced in [true, false] {
            for base in Scenarios.all {
                let s = spaced ? base : Self.withoutSpacing(base)
                let name = s.name + (spaced ? "" : " (unspaced)")
                let r = try await run(s)
                let shown = (r.cues.outcomes.compactMap(\.actual) + r.cues.falseCues + r.cues.tolerated).sorted { $0.t < $1.t }
                print(String(format: "judged-spacing %@: %@; missed %@", name,
                             shown.map { String(format: "%@/%@@%.2f", $0.type.rawValue, $0.source.rawValue, $0.t) }.joined(separator: " "),
                             r.cues.missed.map(\.type.rawValue).joined(separator: " ")))
                for c in r.cues.falseCues where !(c.type == .notListening && c.source == .gpt) {
                    problems.append(String(format: "%@: a cue no rule calls for: %@ at %.2f s", name, c.type.rawValue, c.t))
                }
                for (a, b) in zip(shown, shown.dropFirst()) where b.t - a.t < config.cues.onScreenS - 1e-6 {
                    problems.append(String(format: "%@: %@ at %.2f s while %@ at %.2f s is on screen", name, b.type.rawValue, b.t, a.type.rawValue, a.t))
                }
                let judged = shown.filter { $0.source == .gpt }
                for (a, b) in zip(judged, judged.dropFirst()) where b.t - a.t < config.cues.globalCooldownS - 1e-6 {
                    problems.append(String(format: "%@: judged cues at %.2f and %.2f s", name, a.t, b.t))
                }
                cutInsAfterAVerdict += zip(shown, shown.dropFirst()).filter { a, b in
                    a.source == .gpt && b.type == .interrupt && b.t - a.t < config.cues.globalCooldownS
                }.count
            }
        }
        XCTAssertEqual(problems, [])
        XCTAssertGreaterThan(cutInsAfterAVerdict, 0, "some cut-in lands inside a verdict's global cooldown")
    }
}
