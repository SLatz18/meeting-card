import Foundation
import ListenMoreCore

/// Writes the run's output files. Every write is scrubbed: a secret (the API key) never reaches a
/// file; if one would, it is replaced and the leak is recorded so the run fails.
public final class OutputWriter {
    public let directory: URL
    private let secrets: [String]
    public private(set) var leaks: [String] = []
    public private(set) var written: [URL] = []

    public init(directory: URL, secrets: [String]) throws {
        self.directory = directory
        self.secrets = secrets.filter { $0.count >= 8 }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    public func scrub(_ text: String, context: String) -> String {
        var out = text
        for s in secrets where out.contains(s) {
            leaks.append(context)
            out = out.replacingOccurrences(of: s, with: "[REDACTED]")
        }
        return out
    }

    @discardableResult
    public func write(_ name: String, _ text: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try Data(scrub(text, context: name).utf8).write(to: url)
        written.append(url)
        return url
    }
}

/// One cost-log entry: counts and dollars only (no text, no audio, no key).
public struct CostEntry: Sendable {
    public var kind: String
    public var scenario: String?
    public var fields: [String: Double]
    public var labels: [String: String]

    public init(kind: String, scenario: String?, fields: [String: Double], labels: [String: String] = [:]) {
        self.kind = kind
        self.scenario = scenario
        self.fields = fields
        self.labels = labels
    }

    var json: String {
        var obj: [String: Any] = ["kind": kind]
        if let scenario { obj["scenario"] = scenario }
        for (k, v) in fields { obj[k] = v }
        for (k, v) in labels { obj[k] = v }
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

public enum Report {
    public static func markdown(_ results: [ScenarioResult], mode: Mode, header: [String]) -> String {
        var out = "# Voice harness results (\(mode.rawValue))\n\n"
        for h in header { out += "- \(h)\n" }
        out += "\n| Scenario | Transcription | Speaker ID | Coaching | Checks |\n|---|---|---|---|---|\n"
        for r in results {
            out += "| \(r.scenario) | \(transcriptionCell(r)) | \(speakerCell(r)) | \(coachingCell(r)) | \(r.checks.filter(\.passed).count)/\(r.checks.count) \(r.passed ? "PASS" : "FAIL") |\n"
        }
        let passed = results.filter(\.passed).count
        out += "\n**\(passed)/\(results.count) scenarios pass.**\n"
        for r in results {
            out += "\n## \(r.scenario)\n\n\(r.summary)\n\n"
            out += "Cues, expected vs actual:\n\n| Expected | Window (s) | Actual | Why |\n|---|---|---|---|\n"
            for o in r.cues.outcomes {
                let e = o.expected
                let name = e.type.rawValue + (e.level.map { " (\($0.rawValue))" } ?? "") + (e.optional ? " [optional]" : "")
                let actual = o.actual.map { "\($0.type.rawValue) at \(f1($0.t)) s (\($0.source.rawValue), engine t \(f1($0.engineT)))" } ?? "none"
                out += "| \(name) | \(f1(e.window.lowerBound))–\(f1(e.window.upperBound)) | \(actual) | \(e.reason) |\n"
            }
            if r.cues.outcomes.isEmpty { out += "| none | – | – | no rule fires for this script |\n" }
            for c in r.cues.falseCues { out += "| none (false cue) | – | \(cueText(c)) | not called for by any rule |\n" }
            for c in r.cues.tolerated { out += "| judged / edge (informational) | – | \(cueText(c)) | not scored |\n" }
            out += "\nChecks:\n\n"
            for c in r.checks { out += "- \(c.passed ? "PASS" : "FAIL") \(c.name): \(c.detail)\n" }
        }
        return out
    }

    static func cueText(_ c: CueRecord) -> String {
        "\(c.type.rawValue)\(c.level.map { " (\($0.rawValue))" } ?? "") at \(f1(c.t)) s (\(c.source.rawValue))"
    }

    static func transcriptionCell(_ r: ScenarioResult) -> String {
        let me = r.transcription[.me], them = r.transcription[.others]
        let lat = ((me?.latencies ?? []) + (them?.latencies ?? []))
        let med = StreamTranscription.percentile(lat, 0.5), mx = lat.max()
        let lines = (me?.linesCaptioned ?? 0) + (them?.linesCaptioned ?? 0)
        let expected = (me?.linesExpected ?? 0) + (them?.linesExpected ?? 0)
        guard expected > 0 || lines > 0 else { return "no transcription (by design)" }
        return "WER You \(pct(me?.errors.rate)) · Them \(pct(them?.errors.rate)) · all \(pct(r.totalErrors.rate)); latency med \(sec(med)) / max \(sec(mx)); lines \(lines)/\(expected)"
    }

    static func speakerCell(_ r: ScenarioResult) -> String {
        let s = r.speakers
        guard s.total > 0 else { return "no captions (by design)" }
        return "\(s.correct)/\(s.total) (\(pct(s.accuracy))); multi-Them: \(s.multiThem.rawValue)"
    }

    static func coachingCell(_ r: ScenarioResult) -> String {
        let expected = r.cues.outcomes.filter { !$0.expected.optional }
        let actual = r.cues.outcomes.compactMap(\.actual) + r.cues.falseCues + r.cues.tolerated
        let names = actual.sorted { $0.t < $1.t }.map { "\($0.type.rawValue)@\(f1($0.t))" }
        return "expected \(expected.count), actual \(actual.count) [\(names.joined(separator: ", "))]; missed \(r.cues.missed.count), false \(r.cues.falseCues.count) \(r.cues.passed ? "PASS" : "FAIL")"
    }

    public static func json(_ results: [ScenarioResult], mode: Mode) -> String {
        let scenarios: [[String: Any]] = results.map { r in
            var tx: [String: Any] = [:]
            for (speaker, t) in r.transcription {
                tx[speaker == .me ? "you" : "them"] = [
                    "wer": t.errors.rate as Any, "substitutions": t.errors.substitutions, "deletions": t.errors.deletions,
                    "insertions": t.errors.insertions, "reference_words": t.errors.referenceWords,
                    "latencies_s": t.latencies, "lines_expected": t.linesExpected, "lines_captioned": t.linesCaptioned,
                ]
            }
            return [
                "scenario": r.scenario, "passed": r.passed,
                "transcription": tx,
                "speaker_id": ["correct": r.speakers.correct, "total": r.speakers.total, "unmatched": r.speakers.unmatched,
                               "accuracy": r.speakers.accuracy as Any, "multi_them": r.speakers.multiThem.rawValue],
                "coaching": [
                    "expected": r.cues.outcomes.map { o -> [String: Any] in
                        ["type": o.expected.type.rawValue, "level": o.expected.level?.rawValue as Any, "optional": o.expected.optional,
                         "window": [o.expected.window.lowerBound, o.expected.window.upperBound], "reason": o.expected.reason,
                         "actual_t": o.actual?.t as Any]
                    },
                    "false": r.cues.falseCues.map { ["type": $0.type.rawValue, "t": $0.t, "source": $0.source.rawValue] },
                    "tolerated": r.cues.tolerated.map { ["type": $0.type.rawValue, "t": $0.t, "source": $0.source.rawValue] },
                    "passed": r.cues.passed,
                ],
                "checks": r.checks.map { ["name": $0.name, "passed": $0.passed, "detail": $0.detail] },
            ]
        }
        let obj: [String: Any] = ["mode": mode.rawValue, "scenarios": scenarios]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }

    static func f1(_ x: Double) -> String { String(format: "%.1f", x) }
    static func pct(_ x: Double?) -> String { x.map { String(format: "%.1f%%", $0 * 100) } ?? "n/a" }
    static func sec(_ x: Double?) -> String { x.map { String(format: "%.2f s", $0) } ?? "n/a" }
}
