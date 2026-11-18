import Foundation
import XCTest
import ListenMoreCore
@testable import ListenMoreHarness

/// The nine scenarios with the engine's `cut_in_onset_gap_ms` swept (the oracle keeps the built-in
/// rules): per value and voice, the expected interrupts that fired or missed and every false cue.
/// `LM_OVERLAP_GAP_SWEEP=1` runs it (160-600 ms, or the list in `LM_OVERLAP_GAP_SWEEP_MS`); espeak only
/// where espeak-ng is installed.
@MainActor
final class OverlapGapSweepTests: XCTestCase {
    func testSweep() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["LM_OVERLAP_GAP_SWEEP"] == "1" else { throw XCTSkip("set LM_OVERLAP_GAP_SWEEP=1 to run the sweep") }
        let values = env["LM_OVERLAP_GAP_SWEEP_MS"].map { $0.split(separator: ",").compactMap { Double($0) } }
            ?? Array(stride(from: 160.0, through: 600.0, by: 20.0))
        let voices: [OfflineVoices] = EspeakVoice.executable == nil ? [.synthetic] : [.synthetic, .espeak]
        var lines = ["| cut_in_onset_gap_ms | voices | scenarios passing | interrupts expected | fired | missed | false interrupts | other false cues |",
                     "|---|---|---|---|---|---|---|---|"]
        var detail: [String] = []
        for ms in values {
            for v in voices {
                let out = FileManager.default.temporaryDirectory.appendingPathComponent("lm-sweep-\(UUID().uuidString)", isDirectory: true)
                defer { try? FileManager.default.removeItem(at: out) }
                let summary = try await Harness.run(HarnessOptions(mode: .offline, outputDirectory: out, environment: [:], offlineVoices: v,
                                                                   engineOverrides: ["local": ["cut_in_onset_gap_ms": ms]]))
                let outcomes = summary.results.flatMap { r in r.cues.outcomes.filter { $0.expected.type == .interrupt }.map { (r.scenario, $0) } }
                let fired = outcomes.filter { $0.1.actual != nil }
                let falseCues = summary.results.flatMap { r in r.cues.falseCues.map { (r.scenario, $0) } }
                let falseInterrupts = falseCues.filter { $0.1.type == .interrupt }
                lines.append("| \(Int(ms)) | \(v.rawValue) | \(summary.results.filter(\.passed).count)/\(summary.results.count) | \(outcomes.count) | \(fired.count) | \(outcomes.count - fired.count) | \(falseInterrupts.count) | \(falseCues.count - falseInterrupts.count) |")
                let times = fired.map { "\($0.0) \($0.1.expected.line ?? "")@\(String(format: "%.2f", $0.1.actual!.t))" }
                let falses = falseCues.map { "\($0.0) \($0.1.type.rawValue)@\(String(format: "%.2f", $0.1.t))" }
                detail.append("\(Int(ms)) \(v.rawValue): fired \(times); false \(falses)")
            }
        }
        let text = (lines + [""] + detail).joined(separator: "\n")
        print(text)
        if let path = env["LM_OVERLAP_GAP_SWEEP_OUT"] { try text.write(toFile: path, atomically: true, encoding: .utf8) }
    }
}
