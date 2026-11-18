import Foundation
import ListenMoreCore

/// The self-pivot precision run: each case (`PivotEvalCases.swift`) goes through the real `GptLayer` (the gate
/// and the self-pivot judge's lane, the cue judge off) on a simulated clock, with MeetingCard's config. Its
/// transcripts come from a scripted transcriber; its one self-pivot judge request goes to the given transport
/// (the real Responses API in a paid run, a stub otherwise). It reports, per case, whether the gate took it
/// (the shadow number), whether it was judged, the verdict's label and confidence, and whether it became a
/// cue; then false self_pivot cues on the negatives (bar: 0), recall against the shadow recall, that every
/// request sent `store: false`, and that no case's words reached any output. Numbers and labels only.
public enum PivotEval {
    public enum CaseSet: String, Sendable, Codable {
        case positive
        case negative
    }

    public struct Turn: Sendable {
        public var speaker: Speaker
        public var text: String
        public var from: Double
        public var to: Double
    }

    public struct Case: Sendable {
        public var name: String
        public var set: CaseSet
        public var turns: [Turn]

        /// Them's lines back to back (0.6 s apart), then You 1 s after the last; each at 2.6 words a second.
        public static func reply(_ name: String, _ set: CaseSet, them: [String], you: String) -> Case {
            var turns: [Turn] = []
            var t = 0.5
            for line in them {
                let d = seconds(line)
                turns.append(Turn(speaker: .others, text: line, from: t, to: t + d))
                t += d + 0.6
            }
            let start = t - 0.6 + 1.0
            turns.append(Turn(speaker: .me, text: you, from: start, to: start + seconds(you)))
            return Case(name: name, set: set, turns: turns)
        }

        static func seconds(_ s: String) -> Double {
            (Double(s.split(whereSeparator: \.isWhitespace).count) / 2.6 * 50).rounded() / 50
        }
    }

    public struct Outcome: Sendable, Equatable {
        public var name: String
        public var set: CaseSet
        /// The gate took it for a candidate (the shadow number).
        public var candidate: Bool
        public var judged: Bool
        public var verdict: String?
        public var confidence: Double?
        public var cue: Bool
        /// A failure class (HTTP status, timeout), never a body.
        public var failure: String?
    }

    public struct Report: Sendable {
        public var outcomes: [Outcome]
        public var requests: Int
        public var storeViolations: Int
        public var otherJudgeRequests: Int
        /// Outputs or log lines that carried four words in a row from any case.
        public var snippetLeaks: [String]

        public var positives: [Outcome] { outcomes.filter { $0.set == .positive } }
        public var negatives: [Outcome] { outcomes.filter { $0.set == .negative } }
        public var falseCues: [Outcome] { negatives.filter(\.cue) }
        public var recall: Double { Double(positives.filter(\.cue).count) / Double(max(1, positives.count)) }
        public var shadowRecall: Double { Double(positives.filter(\.candidate).count) / Double(max(1, positives.count)) }
        public var failures: [Outcome] { outcomes.filter { $0.failure != nil } }
        /// The bar: no false self_pivot cue on a negative, store false on every request, no case text anywhere,
        /// no cue judge request, and every judged case answered.
        public var passed: Bool {
            falseCues.isEmpty && storeViolations == 0 && snippetLeaks.isEmpty && otherJudgeRequests == 0 && failures.isEmpty
        }
    }

    /// MeetingCard's config (not_listening off), with no wait between judge calls.
    public static func config() throws -> ListenMoreConfig {
        try ListenMoreConfig.load(overrides: ["cues": ["disabled": [CueType.notListening.rawValue]], "gpt": ["judge_min_interval_s": 0]])
    }

    /// Runs every case through its own layer, one at a time.
    public static func run(_ cases: [Case] = cases, http: HTTPTransport, key: APIKey, config: ListenMoreConfig,
                           log: (String) -> Void = { _ in }) async -> Report {
        let recorder = RecordingJudgeHTTP(inner: http)
        var outcomes: [Outcome] = []
        for c in cases {
            let o = await run(c, http: recorder, key: key, config: config)
            outcomes.append(o)
            log("\(c.set.rawValue) \(c.name): candidate \(o.candidate), judged \(o.judged), verdict \(o.verdict ?? "-") "
                + "\(o.confidence.map { String(format: "%.2f", $0) } ?? "-"), cue \(o.cue)\(o.failure.map { ", failed \($0)" } ?? "")")
        }
        return Report(outcomes: outcomes, requests: recorder.facts.count,
                      storeViolations: recorder.facts.filter { !$0.storeFalse }.count,
                      otherJudgeRequests: recorder.facts.filter { !$0.selfPivot }.count, snippetLeaks: [])
    }

    static func run(_ c: Case, http: RecordingJudgeHTTP, key: APIKey, config: ListenMoreConfig) async -> Outcome {
        let clock = EvalClock()
        let offers = EvalOffers()
        let before = http.verdicts.count
        let lines: [Speaker: [String]] = Dictionary(grouping: c.turns, by: \.speaker).mapValues { $0.map(\.text) }
        let layer = GptLayer(config: config, now: { clock.now }, offer: { label, t, refT, conf in offers.add(label, t, refT, conf) },
                             provider: nil, selfPivotJudge: JudgeProviders.selfPivotJudge(config: config, openAIKey: key, http: http),
                             scheduler: EvalScheduler()) { speaker, onEvent in
            ScriptedLines(speaker: speaker, lines: lines[speaker] ?? [], onEvent: onEvent)
        }
        layer.start()
        let frameS = config.frameS
        let hop = config.frameSamples
        let voiced = [Float](repeating: 0.1, count: hop), silent = [Float](repeating: 0, count: hop)
        let end = (c.turns.map(\.to).max() ?? 0) + 6
        var was: [Speaker: Bool] = [.me: false, .others: false]
        let frames = Int((end / frameS).rounded())
        for k in 0...frames {
            let t = Double(k) * frameS
            clock.now = t
            var vads: [Speaker: VadState] = [:]
            for speaker in Speaker.allCases {
                let active = c.turns.contains { $0.speaker == speaker && $0.from <= t + 1e-9 && t <= $0.to + 1e-9 }
                let prev = was[speaker] ?? false
                vads[speaker] = VadState(raw: active, active: active, onset: active && !prev ? t : nil,
                                         offset: !active && prev ? t - frameS : nil, dbfs: active ? -20 : -90)
                was[speaker] = active
            }
            let me = vads[.me]!, others = vads[.others]!
            layer.feed(me: me.raw ? voiced : silent, meVad: me, others: others.raw ? voiced : silent, othersVad: others, meRunS: 0)
            _ = await layer.snapshot()
        }
        // The judge answers in real time; the clock stays at the end, inside the verdict's 10 s.
        let deadline = Date().addingTimeInterval(config.gpt.judgeTimeoutS * 2 + 2)
        var snap = await layer.snapshot()
        while snap.selfPivotJudgeCalls > snap.judgeLatenciesMs.count && Date() < deadline {
            try? await Task.sleep(nanoseconds: 20_000_000)
            snap = await layer.snapshot()
        }
        await layer.close()
        let verdict = http.verdicts.count > before ? http.verdicts.last : nil
        return Outcome(name: c.name, set: c.set, candidate: snap.pivotCandidates > 0, judged: snap.selfPivotJudgeCalls > 0,
                       verdict: verdict?.label, confidence: verdict?.confidence,
                       cue: offers.cues(config: config).contains { $0.type == .selfPivot }, failure: verdict?.failure)
    }

    /// Outputs and log lines that carry four words in a row from any case's lines.
    public static func snippetLeaks(in texts: [(name: String, text: String)], cases: [Case] = cases) -> [String] {
        func words(_ s: String) -> [String] {
            s.lowercased().split(whereSeparator: { !$0.isLetter && $0 != "'" }).map(String.init)
        }
        var phrases = Set<String>()
        for c in cases {
            for turn in c.turns {
                let w = words(turn.text)
                guard w.count >= 4 else { continue }
                for i in 0...(w.count - 4) { phrases.insert(w[i..<(i + 4)].joined(separator: " ")) }
            }
        }
        return texts.compactMap { item in
            let w = words(item.text)
            guard w.count >= 4 else { return nil }
            for i in 0...(w.count - 4) where phrases.contains(w[i..<(i + 4)].joined(separator: " ")) { return item.name }
            return nil
        }
    }

    /// A whole run: every case, then pivot-eval.md and pivot-eval.json (scrubbed of `secrets`), and the
    /// no-case-text check over both files and every log line. `log` gets numbers and labels only.
    public static func runAndWrite(cases: [Case] = cases, http: HTTPTransport, key: APIKey, secrets: [String], out: URL,
                                   mode: String, log: (String) -> Void = { _ in }) async throws
        -> (report: Report, files: [URL], keyLeaks: [String]) {
        let config = try config()
        var lines: [String] = []
        var report = await run(cases, http: http, key: key, config: config) { line in
            lines.append(line)
            log(line)
        }
        let writer = try OutputWriter(directory: out, secrets: secrets)
        let md = markdown(report, mode: mode), js = json(report, mode: mode)
        report.snippetLeaks = snippetLeaks(in: [("pivot-eval.md", md), ("pivot-eval.json", js), ("log", lines.joined(separator: "\n"))], cases: cases)
        try writer.write("pivot-eval.md", markdown(report, mode: mode))
        try writer.write("pivot-eval.json", json(report, mode: mode))
        return (report, writer.written, writer.leaks)
    }

    // MARK: outputs

    public static func markdown(_ r: Report, mode: String) -> String {
        var out = "# Self-pivot precision run (\(mode))\n\n"
        out += "- False self_pivot cues on negatives: **\(r.falseCues.count)** of \(r.negatives.count) (bar: 0)\n"
        out += String(format: "- Recall: %d/%d (%.0f%%) vs shadow (gate candidates) %d/%d (%.0f%%)\n",
                      r.positives.filter(\.cue).count, r.positives.count, r.recall * 100,
                      r.positives.filter(\.candidate).count, r.positives.count, r.shadowRecall * 100)
        out += "- Self-pivot judge requests: \(r.requests); without store false: **\(r.storeViolations)**; cue judge requests: \(r.otherJudgeRequests)\n"
        out += "- Outputs carrying case text: **\(r.snippetLeaks.count)**\(r.snippetLeaks.isEmpty ? "" : " (\(r.snippetLeaks.joined(separator: ", ")))")\n"
        out += "- Failed calls: \(r.failures.count)\n"
        out += "- Result: **\(r.passed ? "PASS" : "FAIL")**\n\n"
        out += "| Set | Case | Gate (shadow) | Judged | Verdict | Confidence | Cue |\n|---|---|---|---|---|---|---|\n"
        for o in r.outcomes {
            out += "| \(o.set.rawValue) | \(o.name) | \(o.candidate ? "yes" : "no") | \(o.judged ? "yes" : "no") | "
                + "\(o.failure.map { "failed: \($0)" } ?? o.verdict ?? "-") | \(o.confidence.map { String(format: "%.2f", $0) } ?? "-") | \(o.cue ? "yes" : "no") |\n"
        }
        return out
    }

    public static func json(_ r: Report, mode: String) -> String {
        let obj: [String: Any] = [
            "mode": mode, "passed": r.passed, "false_cues_on_negatives": r.falseCues.count, "negatives": r.negatives.count,
            "positives": r.positives.count, "recall": r.recall, "shadow_recall": r.shadowRecall, "requests": r.requests,
            "store_false_violations": r.storeViolations, "cue_judge_requests": r.otherJudgeRequests,
            "snippet_leaks": r.snippetLeaks, "failed_calls": r.failures.count,
            "cases": r.outcomes.map { o -> [String: Any] in
                ["name": o.name, "set": o.set.rawValue, "candidate": o.candidate, "judged": o.judged, "verdict": o.verdict as Any,
                 "confidence": o.confidence as Any, "cue": o.cue, "failure": o.failure as Any]
            },
        ]
        let data = (try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

/// Judge requests as the precision run sees them: each request's schema name and store flag, and each reply's
/// label, confidence or failure class. Never a prompt, instructions, a reason or a body.
final class RecordingJudgeHTTP: HTTPTransport, @unchecked Sendable {
    struct Verdict: Sendable {
        var label: String?
        var confidence: Double?
        var failure: String?
    }

    private let inner: HTTPTransport
    private let lock = NSLock()
    private var _facts: [JudgeRequestFacts] = []
    private var _verdicts: [Verdict] = []

    init(inner: HTTPTransport) { self.inner = inner }

    var facts: [JudgeRequestFacts] { lock.withLock { _facts } }
    var verdicts: [Verdict] { lock.withLock { _verdicts } }

    func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval) async throws -> (status: Int, body: Data) {
        lock.withLock { _facts.append(JudgeRequestFacts.read(body)) }
        do {
            let reply = try await inner.post(url: url, headers: headers, body: body, timeout: timeout)
            var v = Verdict()
            if reply.status == 200, let (res, _) = try? LiveJudge.parse(reply.body) {
                v.label = res.cue
                v.confidence = res.confidence
            } else {
                v.failure = reply.status == 200 ? "bad response" : "HTTP \(reply.status)"
            }
            lock.withLock { _verdicts.append(v) }
            return reply
        } catch {
            lock.withLock { _verdicts.append(Verdict(failure: GptError.safe(error))) }
            throw error
        }
    }
}

/// A transcriber that answers each commit with the speaker's next scripted line.
final class ScriptedLines: TranscriptionSession, @unchecked Sendable {
    private let speaker: Speaker
    private let onEvent: @Sendable (TranscriptEvent) -> Void
    private let lock = NSLock()
    private var lines: [String]

    init(speaker: Speaker, lines: [String], onEvent: @escaping @Sendable (TranscriptEvent) -> Void) {
        self.speaker = speaker
        self.lines = lines
        self.onEvent = onEvent
    }

    func start() async throws {}
    func sendAudio(_ pcm16: Data) async throws {}
    func clear() async throws {}
    func close() async {}

    func commit(refT: TimeInterval) async throws {
        guard let line = lock.withLock({ lines.isEmpty ? nil : lines.removeFirst() }) else { return }
        onEvent(.text(speaker, line, refT: refT))
    }
}

final class EvalClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval = 0
    var now: TimeInterval {
        get { lock.withLock { t } }
        set { lock.withLock { t = newValue } }
    }
}

final class EvalOffers: @unchecked Sendable {
    private let lock = NSLock()
    private var offers: [(label: String, t: TimeInterval, refT: TimeInterval, confidence: Double)] = []

    func add(_ label: String, _ t: TimeInterval, _ refT: TimeInterval, _ c: Double) { lock.withLock { offers.append((label, t, refT, c)) } }

    /// Through MeetingCard's cue policy, as the engine would offer them.
    func cues(config: ListenMoreConfig) -> [Cue] {
        let policy = CuePolicy(config: config.cues)
        return lock.withLock { offers }.compactMap { o in
            CueType(judgeLabel: o.label, provider: config.judge.provider).flatMap {
                policy.offer($0, t: o.t, onset: o.refT, source: .gpt, confidence: o.confidence)
            }
        }
    }
}

/// Real time for judge latency; no waiting between calls.
struct EvalScheduler: GptScheduler {
    func monotonic() -> TimeInterval { ProcessInfo.processInfo.systemUptime }
    func sleep(seconds: Double) async throws { await Task.yield() }
}
