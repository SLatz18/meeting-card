import Foundation
import ListenMoreHarness

let usage = """
usage: lm-harness [--live] [--scenario NAME]... [--out DIR] [--tts-model MODEL] [--list]

  (default)          offline: synthetic audio, scripted transcription, deterministic, no network
  --live             real OpenAI TTS + realtime transcription + judge; reads OPENAI_API_KEY from the
                     environment (never pass the key as an argument)
  --scenario NAME    run only NAME (repeatable); --list shows the names
  --out DIR          where results.md, results.json and cost-log.jsonl go
                     (default: a new folder under the system temp directory)

Exit status: 0 when every scenario passes, 1 when a check fails, 2 on a usage or setup error.
"""

@MainActor
func main() async -> Int32 {
    let args = Array(CommandLine.arguments.dropFirst())
    let env = ProcessInfo.processInfo.environment
    do {
        try Harness.checkArguments(args, environment: env)
    } catch {
        FileHandle.standardError.write(Data("\(error)\n".utf8))
        return 2
    }
    var mode = Mode.offline
    var names: [String] = []
    var out: URL?
    var ttsModel = "gpt-4o-mini-tts"
    var i = 0
    while i < args.count {
        let a = args[i]
        func value() -> String? {
            i += 1
            return i < args.count ? args[i] : nil
        }
        switch a {
        case "--live": mode = .live
        case "--offline": mode = .offline
        case "--scenario":
            guard let v = value() else { print(usage); return 2 }
            names.append(v)
        case "--out":
            guard let v = value() else { print(usage); return 2 }
            out = URL(fileURLWithPath: v, isDirectory: true)
        case "--tts-model":
            guard let v = value() else { print(usage); return 2 }
            ttsModel = v
        case "--list":
            for s in Scenarios.all { print("\(s.name)\t\(s.summary)") }
            return 0
        case "-h", "--help":
            print(usage)
            return 0
        default:
            print("unknown argument: \(a)\n\n\(usage)")
            return 2
        }
        i += 1
    }
    var scenarios = Scenarios.all
    if !names.isEmpty {
        let unknown = names.filter { Scenarios.named($0) == nil }
        guard unknown.isEmpty else {
            print("unknown scenario: \(unknown.joined(separator: ", ")) (see --list)")
            return 2
        }
        scenarios = names.compactMap(Scenarios.named)
    }
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let dir = out ?? FileManager.default.temporaryDirectory.appendingPathComponent("lm-harness-out/\(mode.rawValue)-\(stamp)", isDirectory: true)
    do {
        let summary = try await Harness.run(HarnessOptions(mode: mode, scenarios: scenarios, outputDirectory: dir, environment: env,
                                                           ttsModel: ttsModel)) { print($0) }
        print("results: \(dir.appendingPathComponent("results.md").path)")
        if !summary.leaks.isEmpty { print("FAIL: secret material reached output files (scrubbed): \(summary.leaks.joined(separator: ", "))") }
        let passed = summary.results.filter(\.passed).count
        print("\(passed)/\(summary.results.count) scenarios pass")
        return summary.passed ? 0 : 1
    } catch {
        print("error: \(error)")
        return 2
    }
}

exit(await main())
