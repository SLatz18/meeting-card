import Foundation
import ListenMoreCore

public struct HarnessOptions {
    public var mode: Mode
    public var scenarios: [Scenario]
    public var outputDirectory: URL
    public var environment: [String: String]
    /// Live only: the network (nil = OpenAI). Tests inject fakes.
    public var liveBackend: LiveBackend?
    public var ttsModel: String
    /// Test hook: config overrides for the engine only (the oracle keeps the built-in rules), to show
    /// the checks catch an engine regression.
    public var engineOverrides: [String: Any]
    /// Test hook: controls the runner skips (a broken Mute or Pause).
    public var ignoredControls: Set<ControlKind>

    public init(mode: Mode = .offline, scenarios: [Scenario] = Scenarios.all, outputDirectory: URL,
                environment: [String: String] = ProcessInfo.processInfo.environment, liveBackend: LiveBackend? = nil,
                ttsModel: String = "gpt-4o-mini-tts", engineOverrides: [String: Any] = [:], ignoredControls: Set<ControlKind> = []) {
        self.mode = mode
        self.scenarios = scenarios
        self.outputDirectory = outputDirectory
        self.environment = environment
        self.liveBackend = liveBackend
        self.ttsModel = ttsModel
        self.engineOverrides = engineOverrides
        self.ignoredControls = ignoredControls
    }
}

public struct HarnessSummary {
    public var mode: Mode
    public var results: [ScenarioResult]
    public var outputDirectory: URL
    public var files: [URL]
    /// Output files a secret would have reached (scrubbed; any entry fails the run).
    public var leaks: [String]
    public var costEntries: [CostEntry]

    public var passed: Bool { results.allSatisfy(\.passed) && leaks.isEmpty }
}

public enum Harness {
    public static let keyVariable = "OPENAI_API_KEY"

    /// The key comes from the environment only: an argument that looks like key material is refused.
    public static func checkArguments(_ args: [String], environment: [String: String]) throws {
        let key = environment[keyVariable].flatMap { $0.count >= 8 ? $0 : nil }
        for a in args {
            let looksLikeKey = a.range(of: #"sk-[A-Za-z0-9_\-]{8,}"#, options: .regularExpression) != nil
            if looksLikeKey || a.uppercased().contains(keyVariable) || (key.map { a.contains($0) } ?? false) {
                throw HarnessError.unsafeArgument
            }
        }
    }

    @MainActor
    public static func run(_ o: HarnessOptions, log: (String) -> Void = { _ in }) async throws -> HarnessSummary {
        var liveKey: APIKey?
        if o.mode == .live {
            guard let k = APIKey(o.environment[keyVariable] ?? "") else { throw HarnessError.missingKey }
            liveKey = k
        }
        let writer = try OutputWriter(directory: o.outputDirectory, secrets: liveKey.map { [$0.value] } ?? [])
        let base = try ListenMoreConfig.builtIn()
        var results: [ScenarioResult] = []
        var cost: [CostEntry] = []
        var clipCache: [String: [Float]] = [:]
        for scenario in o.scenarios {
            log("\(scenario.name): running (\(o.mode.rawValue))")
            let scenarioOverrides: [String: Any] = scenario.budgetUsd.map { ["gpt": ["budget_usd_per_call": $0]] } ?? [:]
            let config = scenarioOverrides.isEmpty ? base : try ListenMoreConfig.load(overrides: scenarioOverrides)
            let engineConfig = o.engineOverrides.isEmpty ? config
                : try ListenMoreConfig.load(overrides: deepMerge(scenarioOverrides, o.engineOverrides))
            let dir = try RunDirectory.create()
            let audit = DiskAudit(roots: DiskAudit.defaultRoots() + [o.outputDirectory], exclude: dir.url)
            var record: RunRecord
            var meteredHTTP: MeteredHTTP?
            do {
                var services: RunServices
                switch o.mode {
                case .offline:
                    services = offlineServices(scenario, config: config)
                case .live:
                    let built = try await liveServices(scenario, config: config, key: liveKey!, options: o, cache: &clipCache, cost: &cost)
                    services = built.services
                    meteredHTTP = built.http
                }
                services.engineConfig = engineConfig
                services.ignoredControls = o.ignoredControls
                record = try await ScenarioRun(scenario: scenario, services: services, workDir: dir.url).run()
            } catch {
                dir.wipe()
                throw error
            }
            record.workDirWiped = dir.wipe()
            record.diskViolations = audit.violations()
            let result = Checks.evaluate(record)
            results.append(result)
            cost += costEntries(result, record: record, http: meteredHTTP)
            log("\(scenario.name): \(result.passed ? "PASS" : "FAIL") (\(result.checks.filter(\.passed).count)/\(result.checks.count) checks)")
            for f in result.failures { log("  FAIL \(f.name): \(f.detail)") }
        }

        let header = [
            "Mode: \(o.mode.rawValue)" + (o.mode == .offline
                ? " (synthetic audio, scripted transcription text, stub judge, simulated clock; WER checks the plumbing)"
                : " (OpenAI TTS \(o.ttsModel), realtime transcription \(base.gpt.transcribeModel), judge \(base.gpt.judgeModel))"),
            "Generated: \(ISO8601DateFormatter().string(from: Date()))",
            "Engine: ListenMoreCore's CoachSession / LocalCoachEngine / GptLayer / LiveTranscriber, built-in config",
            "Streams: You = mic, Them = call (two Them voices in two-them-voices)",
        ]
        try writer.write("results.md", Report.markdown(results, mode: o.mode, header: header))
        try writer.write("results.json", Report.json(results, mode: o.mode))
        try writer.write("cost-log.jsonl", cost.map(\.json).joined(separator: "\n") + "\n")
        return HarnessSummary(mode: o.mode, results: results, outputDirectory: o.outputDirectory, files: writer.written,
                              leaks: writer.leaks, costEntries: cost)
    }

    static func offlineServices(_ scenario: Scenario, config: ListenMoreConfig) -> RunServices {
        let clock = HarnessClock(.simulated)
        let server = ScriptedRealtime(clock: clock, sampleRate: config.audio.sampleRate)
        let judge = StubJudgeHTTP()
        return RunServices(mode: .offline, config: config, engineConfig: config, key: scenario.keyless ? nil : APIKey("offline-stub"),
                           transports: GptTransports(http: judge, webSocket: server, scheduler: InstantScheduler(clock: clock)),
                           clock: clock, sockets: server, offlineServer: server, judgeCalls: { judge.calls },
                           clips: SyntheticVoice.clips(scenario, sampleRate: config.audio.sampleRate),
                           shapes: SyntheticVoice.shapes(scenario))
    }

    static func liveServices(_ scenario: Scenario, config: ListenMoreConfig, key: APIKey, options o: HarnessOptions,
                             cache: inout [String: [Float]], cost: inout [CostEntry]) async throws -> (services: RunServices, http: MeteredHTTP) {
        let backend = o.liveBackend ?? .real()
        let sr = config.audio.sampleRate
        let tts = OpenAITTS(key: key, http: backend.http, model: o.ttsModel)
        var clips: [String: [Float]] = [:]
        var shapes: [String: ClipShape] = [:]
        for line in scenario.lines {
            let cacheKey = line.voice.rawValue + "|" + line.text
            let samples: [Float]
            if let hit = cache[cacheKey] {
                samples = hit
            } else {
                samples = try await tts.speak(line.text, voice: line.voice, sampleRate: sr)
                cache[cacheKey] = samples
                let seconds = Double(samples.count) / Double(sr)
                cost.append(CostEntry(kind: "tts", scenario: scenario.name,
                                      fields: ["characters": Double(line.text.count), "audio_seconds": seconds,
                                               "estimated_usd": seconds / 60 * OpenAITTS.estimatedUsdPerMinute],
                                      labels: ["model": o.ttsModel, "voice": OpenAITTS.voices[line.voice] ?? "", "line": line.id]))
            }
            clips[line.id] = samples
            shapes[line.id] = ClipMeasure.shape(samples, sampleRate: sr)
        }
        let clock = HarnessClock(.wall)
        let http = MeteredHTTP(inner: backend.http)
        let ws = MeteredConnector(inner: backend.webSocket, clock: clock)
        let services = RunServices(mode: .live, config: config, engineConfig: config, key: scenario.keyless ? nil : key,
                                   transports: GptTransports(http: http, webSocket: ws, scheduler: backend.scheduler),
                                   clock: clock, sockets: ws, offlineServer: nil, judgeCalls: { http.calls }, clips: clips, shapes: shapes)
        return (services, http)
    }

    static func deepMerge(_ a: [String: Any], _ b: [String: Any]) -> [String: Any] {
        var out = a
        for (k, v) in b {
            if let sub = v as? [String: Any], let base = out[k] as? [String: Any] {
                out[k] = deepMerge(base, sub)
            } else {
                out[k] = v
            }
        }
        return out
    }

    static func costEntries(_ r: ScenarioResult, record: RunRecord, http: MeteredHTTP?) -> [CostEntry] {
        let prices = record.config.gpt.pricesUsd
        let meter = record.meters.last
        var out = [CostEntry(kind: "transcription", scenario: r.scenario,
                             fields: ["billed_seconds_reported": record.sockets.billedSeconds,
                                      "billed_seconds_engine": meter?.billedAudioS ?? 0,
                                      "usd": meter?.transcribeUsd ?? record.sockets.billedSeconds / 60 * prices.transcribePerMinute],
                             labels: ["mode": record.mode.rawValue])]
        var judge: [String: Double] = ["calls": Double(record.judgeCalls), "usd": meter?.judgeUsd ?? 0]
        if let http {
            judge["input_tokens"] = Double(http.tokens.input)
            judge["output_tokens"] = Double(http.tokens.output)
            judge["failed_calls"] = Double(http.failures)
        }
        out.append(CostEntry(kind: "judge", scenario: r.scenario, fields: judge, labels: ["mode": record.mode.rawValue]))
        return out
    }
}
