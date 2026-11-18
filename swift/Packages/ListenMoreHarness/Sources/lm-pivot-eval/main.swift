import Foundation
import ListenMoreCore
import ListenMoreHarness

let usage = """
usage: lm-pivot-eval [--dry-run [--stub-answer none|self_pivot]] [--out DIR]

The self-pivot (ask-back) precision run: synthetic positive and negative exchanges through the real gate and
self-pivot judge lane, with MeetingCard's config. Reports false self_pivot cues on the negatives (bar: 0),
recall against the gate's shadow recall, the store:false check and the no-case-text check.

  (default)          PAID: one OpenAI Responses request per gate candidate (about 15 short requests,
                     store false). Needs OPENAI_API_KEY in the environment (never an argument) and
                     LISTEN_MORE_PAID_RUN=1.
  --dry-run          a local stub answers instead (default none); no network, no key.
  --stub-answer A    with --dry-run: what the stub answers every request (none or self_pivot, at 0.99)
  --out DIR          where pivot-eval.md, pivot-eval.json, SUMMARY.md and cost-log.jsonl go (numbers and labels
                     only); they carry self_pivot_usd per case and in total

Exit status: 0 when the bar holds, 1 when it doesn't, 2 on a usage or setup error.
"""

let env = ProcessInfo.processInfo.environment

func say(_ text: String) {
    print(Harness.scrub(text, environment: env))
}

func main() async -> Int32 {
    let args = Array(CommandLine.arguments.dropFirst())
    do {
        try Harness.checkArguments(args, environment: env)
    } catch {
        FileHandle.standardError.write(Data((Harness.scrub("\(error)", environment: env) + "\n").utf8))
        return 2
    }
    var dryRun = false
    var answer = "none"
    var out: URL?
    var i = 0
    while i < args.count {
        let a = args[i]
        func value() -> String? {
            i += 1
            return i < args.count ? args[i] : nil
        }
        switch a {
        case "--dry-run": dryRun = true
        case "--stub-answer":
            guard let v = value(), ["none", "self_pivot"].contains(v) else { say(usage); return 2 }
            answer = v
        case "--out":
            guard let v = value() else { say(usage); return 2 }
            out = URL(fileURLWithPath: v, isDirectory: true)
        case "-h", "--help":
            say(usage)
            return 0
        default:
            say("unknown argument: \(a)\n\n\(usage)")
            return 2
        }
        i += 1
    }
    let http: HTTPTransport
    let key: APIKey
    let mode: String
    if dryRun {
        http = StubJudgeHTTP(selfPivotAnswer: (answer, 0.99))
        key = APIKey("dry-run-stub")!
        mode = "dry run, stub answers \(answer)"
    } else {
        guard env["LISTEN_MORE_PAID_RUN"] == "1" else {
            say("this is a paid run: set LISTEN_MORE_PAID_RUN=1 to confirm, or use --dry-run")
            return 2
        }
        guard let k = APIKey(env[Harness.keyVariable] ?? "") else {
            say("the paid run needs \(Harness.keyVariable) in the environment")
            return 2
        }
        http = EphemeralHTTPTransport.shared
        key = k
        mode = "paid, OpenAI Responses"
    }
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let dir = out ?? FileManager.default.temporaryDirectory.appendingPathComponent("lm-pivot-eval/\(stamp)", isDirectory: true)
    do {
        let (report, _, keyLeaks) = try await PivotEval.runAndWrite(http: http, key: key, secrets: dryRun ? [] : [key.value],
                                                                    out: dir, mode: mode) { say($0) }
        say("results: \(dir.appendingPathComponent("pivot-eval.md").path)")
        say("summary: \(dir.appendingPathComponent("SUMMARY.md").path)")
        say("cost log: \(dir.appendingPathComponent("cost-log.jsonl").path)")
        say("false self_pivot cues on negatives: \(report.falseCues.count) of \(report.negatives.count) (bar: 0)")
        say(String(format: "recall %.0f%% vs shadow %.0f%%", report.recall * 100, report.shadowRecall * 100))
        say("requests \(report.requests), without store false \(report.storeViolations), cue judge requests \(report.otherJudgeRequests), "
            + "cases with an uncounted request \(report.requestMismatches.count)")
        say("self_pivot_usd total \(PivotEval.usd(report.selfPivotUsd)) (per case in SUMMARY.md and cost-log.jsonl)")
        say("outputs carrying case text: \(report.snippetLeaks.count); failed calls: \(report.failures.count)")
        if !keyLeaks.isEmpty { say("FAIL: secret material reached output files (scrubbed): \(keyLeaks.joined(separator: ", "))") }
        let passed = report.passed && keyLeaks.isEmpty
        say(passed ? "PASS" : "FAIL")
        return passed ? 0 : 1
    } catch {
        say("error: \(error)")
        return 2
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
exit(await main())
