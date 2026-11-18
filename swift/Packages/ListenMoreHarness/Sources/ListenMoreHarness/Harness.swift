import Foundation
import ListenMoreCore

/// Offline audio: the synthetic signal (default, CI) or local espeak-ng speech (real word timing and
/// pauses; diagnostic, needs espeak-ng installed).
public enum OfflineVoices: String, Sendable {
    case synthetic
    case espeak
}

public struct HarnessOptions {
    public var mode: Mode
    public var scenarios: [Scenario]
    public var outputDirectory: URL
    public var environment: [String: String]
    /// Live only: the network (nil = OpenAI). Tests inject fakes.
    public var liveBackend: LiveBackend?
    public var ttsModel: String
    public var offlineVoices: OfflineVoices
    /// The not_listening judge. nil: on offline (a free stub), off live (0 judge calls unless asked for).
    public var judge: Bool?
    /// Test hook: config overrides for the engine only (the oracle keeps the built-in rules), to show
    /// the checks catch an engine regression.
    public var engineOverrides: [String: Any]
    /// Test hook: controls the runner skips (a broken Mute or Pause).
    public var ignoredControls: Set<ControlKind>

    public init(mode: Mode = .offline, scenarios: [Scenario] = Scenarios.all, outputDirectory: URL,
                environment: [String: String] = ProcessInfo.processInfo.environment, liveBackend: LiveBackend? = nil,
                ttsModel: String = "gpt-4o-mini-tts", offlineVoices: OfflineVoices = .synthetic, judge: Bool? = nil,
                engineOverrides: [String: Any] = [:], ignoredControls: Set<ControlKind> = []) {
        self.mode = mode
        self.scenarios = scenarios
        self.outputDirectory = outputDirectory
        self.environment = environment
        self.liveBackend = liveBackend
        self.ttsModel = ttsModel
        self.offlineVoices = offlineVoices
        self.judge = judge
        self.engineOverrides = engineOverrides
        self.ignoredControls = ignoredControls
    }

    public var judgeOn: Bool { judge ?? (mode == .offline) }
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
    /// The config that turns the judge off: GPT decides only not_listening, and with that cue disabled
    /// `GptCore` makes no judge calls. Transcription and every other rule are unaffected.
    public static let judgeOff: [String: Any] = ["cues": ["disabled": [CueType.notListening.rawValue]]]

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

    /// Text for stdout or stderr with the environment's key (if any) replaced.
    public static func scrub(_ text: String, environment: [String: String]) -> String {
        guard let key = environment[keyVariable], key.count >= 8 else { return text }
        return text.replacingOccurrences(of: key, with: "[REDACTED]")
    }

    @MainActor
    public static func run(_ o: HarnessOptions, log: (String) -> Void = { _ in }) async throws -> HarnessSummary {
        var liveKey: APIKey?
        if o.mode == .live {
            guard let k = APIKey(o.environment[keyVariable] ?? "") else { throw HarnessError.missingKey }
            liveKey = k
        }
        if o.mode == .offline && o.offlineVoices == .espeak && EspeakVoice.executable == nil {
            throw HarnessError.script("--voices espeak needs espeak-ng installed")
        }
        let swept = RunDirectory.sweepStale()
        if swept > 0 { log("removed \(swept) run folder(s) left by an earlier run that didn't finish") }
        let writer = try OutputWriter(directory: o.outputDirectory, secrets: liveKey.map { [$0.value] } ?? [])
        let runOverrides: [String: Any] = o.judgeOn ? [:] : judgeOff
        let base = runOverrides.isEmpty ? try ListenMoreConfig.builtIn() : try ListenMoreConfig.load(overrides: runOverrides)
        var results: [ScenarioResult] = []
        var cost: [CostEntry] = []
        var clipCache: [String: [Float]] = [:]
        for scenario in o.scenarios {
            log("\(scenario.name): running (\(o.mode.rawValue))")
            var scenarioOverrides = runOverrides
            if let budget = scenario.budgetUsd { scenarioOverrides = deepMerge(scenarioOverrides, ["gpt": ["budget_usd_per_call": budget]]) }
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
                    services = try offlineServices(scenario, config: config, voices: o.offlineVoices)
                case .live:
                    let built = try await liveServices(scenario, config: config, key: liveKey!, options: o, cache: &clipCache, cost: &cost)
                    services = built.services
                    meteredHTTP = built.http
                }
                services.engineConfig = engineConfig
                services.ignoredControls = o.ignoredControls
                services.judgeOn = o.judgeOn
                services.segmentedSpeech = o.mode == .live || o.offlineVoices == .espeak
                record = try await ScenarioRun(scenario: scenario, services: services, workDir: dir.url).run()
            } catch {
                dir.wipe()
                // What was spent and scored so far is still written before the error goes up.
                try? writeOutputs(writer, results: results, cost: cost, options: o, base: base,
                                  failure: "\(scenario.name) stopped: \(writer.scrub("\(error)", context: "error"))")
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
        try writeOutputs(writer, results: results, cost: cost, options: o, base: base, failure: nil)
        return HarnessSummary(mode: o.mode, results: results, outputDirectory: o.outputDirectory, files: writer.written,
                              leaks: writer.leaks, costEntries: cost)
    }

    static func writeOutputs(_ writer: OutputWriter, results: [ScenarioResult], cost: [CostEntry], options o: HarnessOptions,
                             base: ListenMoreConfig, failure: String?) throws {
        let judge = o.judgeOn ? "judge \(base.gpt.judgeModel)" : "judge off (0 calls; not_listening not exercised)"
        let audio = o.offlineVoices == .espeak ? "espeak-ng speech" : "synthetic audio"
        var header = [
            "Mode: \(o.mode.rawValue)" + (o.mode == .offline
                ? " (\(audio), scripted transcription text, stub judge, simulated clock; WER checks the plumbing)"
                : " (OpenAI TTS \(o.ttsModel), realtime transcription \(base.gpt.transcribeModel), \(judge))"),
            "Generated: \(ISO8601DateFormatter().string(from: Date()))",
            "Engine: ListenMoreCore's CoachSession / LocalCoachEngine / GptLayer / LiveTranscriber, built-in config",
            "Streams: You = mic, Them = call (two Them voices in two-them-voices)",
            "Caption latency: end of each transcribed speech segment (its commit, less the VAD hangover) to its final transcript",
        ]
        if let failure { header.append("INCOMPLETE: \(failure)") }
        try writer.write("results.md", Report.markdown(results, mode: o.mode, header: header))
        try writer.write("results.json", Report.json(results, mode: o.mode))
        try writer.write("cost-log.jsonl", cost.map(\.json).joined(separator: "\n") + "\n")
    }

    static func offlineServices(_ scenario: Scenario, config: ListenMoreConfig, voices: OfflineVoices) throws -> RunServices {
        let clock = HarnessClock(.simulated)
        let sr = config.audio.sampleRate
        let server = ScriptedRealtime(clock: clock, sampleRate: sr)
        let judge = StubJudgeHTTP()
        var clips: [String: [Float]]
        var shapes: [String: ClipShape]
        switch voices {
        case .synthetic:
            clips = SyntheticVoice.clips(scenario, sampleRate: sr)
            shapes = SyntheticVoice.shapes(scenario)
        case .espeak:
            clips = [:]
            shapes = [:]
            for line in scenario.lines {
                let samples = try EspeakVoice.speak(line.text, voice: line.voice, sampleRate: sr)
                clips[line.id] = samples
                shapes[line.id] = ClipMeasure.shape(samples, sampleRate: sr)
            }
        }
        return RunServices(mode: .offline, config: config, engineConfig: config, key: scenario.keyless ? nil : APIKey("offline-stub"),
                           transports: GptTransports(http: judge, webSocket: server, scheduler: InstantScheduler(clock: clock)),
                           clock: clock, sockets: server, offlineServer: server, judgeCalls: { judge.calls },
                           clips: clips, shapes: shapes)
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
        let http = MeteredHTTP(inner: backend.http, clock: clock)
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

    /// Each engine (a Pause or the call app's mute restarts it) has its own cost meter starting at 0:
    /// the scenario's total is the sum of each engine's last reading.
    static func perEngineTotal(_ r: RunRecord) -> CostReading {
        var total = CostReading()
        let starts = r.engineStarts.sorted()
        for (i, start) in starts.enumerated() {
            let end = i + 1 < starts.count ? starts[i + 1] : .infinity
            guard let last = r.meterLog.last(where: { $0.t >= start - 1e-6 && $0.t < end - 1e-6 })?.reading else { continue }
            total.transcribeUsd += last.transcribeUsd
            total.judgeUsd += last.judgeUsd
            total.billedAudioS += last.billedAudioS
        }
        return total
    }

    static func costEntries(_ r: ScenarioResult, record: RunRecord, http: MeteredHTTP?) -> [CostEntry] {
        let meter = perEngineTotal(record)
        var out = [CostEntry(kind: "transcription", scenario: r.scenario,
                             fields: ["billed_seconds_reported": record.sockets.billedSeconds,
                                      "billed_seconds_engine": meter.billedAudioS,
                                      "engines": Double(record.engineStarts.count),
                                      "usd": meter.transcribeUsd],
                             labels: ["mode": record.mode.rawValue])]
        var judge: [String: Double] = ["calls": Double(record.judgeCalls), "usd": meter.judgeUsd]
        var labels = ["mode": record.mode.rawValue, "judge": record.judgeOn ? "on" : "off"]
        if let http {
            judge["input_tokens"] = Double(http.tokens.input)
            judge["output_tokens"] = Double(http.tokens.output)
            judge["failed_calls"] = Double(http.failures.count)
            // A judge call cancelled up to a second after an engine stop is the GPT layer closing on Pause
            // (or the call app's mute, or the call's end), as designed; a cancel before any stop is not.
            let cancels = http.cancelled.map { $0 - record.origin }
            let atStop = cancels.filter { c in record.engineStops.contains { c >= $0 - 1e-6 && c - $0 <= 1.0 } }
            judge["cancelled_at_engine_stop"] = Double(atStop.count)
            judge["cancelled_otherwise"] = Double(cancels.count - atStop.count)
            if !http.failures.isEmpty {
                labels["failures"] = Dictionary(grouping: http.failures, by: { $0 }).map { "\($0.key) x\($0.value.count)" }.sorted().joined(separator: ", ")
            }
        }
        out.append(CostEntry(kind: "judge", scenario: r.scenario, fields: judge, labels: labels))
        return out
    }
}
