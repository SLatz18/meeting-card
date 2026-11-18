import Foundation
import ListenMoreHarness

let usage = """
usage: lm-harness [--live] [--scenario NAME]... [--out DIR] [--judge | --no-judge] [--voices synthetic|espeak]
                  [--tts-model MODEL] [--list]

  (default)          offline: synthetic audio, scripted transcription, deterministic, no network
  --live             real OpenAI TTS + realtime transcription; reads OPENAI_API_KEY from the
                     environment (never pass the key as an argument)
  --judge            live: also run the not_listening judge (default off live: 0 judge calls)
  --no-judge         0 judge calls in either mode (offline's judge is a free stub, on by default)
  --voices espeak    offline: speak the script with a local espeak-ng instead of the synthetic
                     signal (real word timing and pauses; diagnostic, needs espeak-ng)
  --scenario NAME    run only NAME (repeatable); --list shows the names
  --out DIR          where results.md, results.json and cost-log.jsonl go
                     (default: a new folder under the system temp directory)

Exit status: 0 when every scenario passes, 1 when a check fails, 2 on a usage or setup error.
"""

let env = ProcessInfo.processInfo.environment

/// Every line this tool prints goes through the key scrubber.
func say(_ text: String) {
    print(Harness.scrub(text, environment: env))
}

@MainActor
func main() async -> Int32 {
    let args = Array(CommandLine.arguments.dropFirst())
    do {
        try Harness.checkArguments(args, environment: env)
    } catch {
        FileHandle.standardError.write(Data((Harness.scrub("\(error)", environment: env) + "\n").utf8))
        return 2
    }
    var mode = Mode.offline
    var names: [String] = []
    var out: URL?
    var ttsModel = "gpt-4o-mini-tts"
    var judge: Bool?
    var voices = OfflineVoices.synthetic
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
        case "--judge": judge = true
        case "--no-judge": judge = false
        case "--voices":
            guard let v = value(), let parsed = OfflineVoices(rawValue: v) else { say(usage); return 2 }
            voices = parsed
        case "--scenario":
            guard let v = value() else { say(usage); return 2 }
            names.append(v)
        case "--out":
            guard let v = value() else { say(usage); return 2 }
            out = URL(fileURLWithPath: v, isDirectory: true)
        case "--tts-model":
            guard let v = value() else { say(usage); return 2 }
            ttsModel = v
        case "--list":
            for s in Scenarios.all { say("\(s.name)\t\(s.summary)") }
            return 0
        case "-h", "--help":
            say(usage)
            return 0
        default:
            say("unknown argument: \(a)\n\n\(usage)")
            return 2
        }
        i += 1
    }
    var scenarios = Scenarios.all
    if !names.isEmpty {
        let unknown = names.filter { Scenarios.named($0) == nil }
        guard unknown.isEmpty else {
            say("unknown scenario: \(unknown.joined(separator: ", ")) (see --list)")
            return 2
        }
        scenarios = names.compactMap(Scenarios.named)
    }
    let stamp = ISO8601DateFormatter().string(from: Date()).replacingOccurrences(of: ":", with: "-")
    let dir = out ?? FileManager.default.temporaryDirectory.appendingPathComponent("lm-harness-out/\(mode.rawValue)-\(stamp)", isDirectory: true)
    do {
        let options = HarnessOptions(mode: mode, scenarios: scenarios, outputDirectory: dir, environment: env,
                                     ttsModel: ttsModel, offlineVoices: voices, judge: judge)
        let summary = try await Harness.run(options) { say($0) }
        say("results: \(dir.appendingPathComponent("results.md").path)")
        if !summary.leaks.isEmpty { say("FAIL: secret material reached output files (scrubbed): \(summary.leaks.joined(separator: ", "))") }
        let passed = summary.results.filter(\.passed).count
        say("\(passed)/\(summary.results.count) scenarios pass")
        return summary.passed ? 0 : 1
    } catch {
        say("error: \(error)")
        return 2
    }
}

setvbuf(stdout, nil, _IOLBF, 0)
exit(await main())
