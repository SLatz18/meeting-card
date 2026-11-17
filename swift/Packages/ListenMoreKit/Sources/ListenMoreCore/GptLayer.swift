import Foundation

// GPT layer (port of `gpt_layer.py`): realtime transcription, one session per stream, plus a
// structured-output judge over a RAM-only rolling transcript. Audio, transcript text and judge
// output stay in memory; errors are enums with at most an HTTP status, so nothing content-like (and
// never the key) can reach a log.

public struct JudgeResult: Equatable, Sendable {
    public var cue: String
    public var confidence: Double

    public init(cue: String, confidence: Double) {
        self.cue = cue
        self.confidence = confidence
    }
}

public struct JudgeUsage: Equatable, Sendable {
    public var inputTokens = 0
    public var cachedTokens = 0
    public var outputTokens = 0

    public init(inputTokens: Int = 0, cachedTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.cachedTokens = cachedTokens
        self.outputTokens = outputTokens
    }
}

public enum GptErrorKind: String, Equatable, Sendable {
    case realtimeConnect
    case realtimeSend
    case realtimeRead
    case realtimeServer
    case judgeHTTP
    case judgeTimeout
    case judgeTransport
    case judgeDecode
    case budgetCap
}

/// Error that cannot carry request headers, bodies or text: a kind and an optional HTTP status.
public struct GptError: Error, Equatable, Sendable, CustomStringConvertible {
    public var kind: GptErrorKind
    public var httpStatus: Int?

    public init(_ kind: GptErrorKind, httpStatus: Int? = nil) {
        self.kind = kind
        self.httpStatus = httpStatus
    }

    public var description: String { httpStatus.map { "\(kind.rawValue)(\($0))" } ?? kind.rawValue }
}

public enum Speaker: String, CaseIterable, Sendable {
    case me = "ME"
    case others = "OTHERS"
}

/// One realtime transcription session for one stream. Callbacks may arrive on any thread.
public protocol Transcriber: AnyObject {
    func start(onText: @escaping (_ text: String, _ refT: Double?) -> Void, onError: @escaping (GptError) -> Void)
    func sendAudio(_ pcm16: Data)
    /// Ends the current turn; `refT` is the audio time of the turn's end (the local VAD offset).
    func commit(refT: Double)
    func close()
    /// Audio seconds the API reported back (if any), for cost accounting.
    var reportedAudioSeconds: Double { get }
}

public protocol Judge: AnyObject {
    func judge(prompt: String, completion: @escaping (Result<(JudgeResult, JudgeUsage), GptError>) -> Void)
}

/// ~90 s speaker-labelled transcript, RAM only.
public struct RollingTranscript: Sendable {
    public struct Line: Equatable, Sendable {
        public var t: Double
        public var speaker: Speaker
        public var text: String
    }

    public let windowS: Double
    public private(set) var lines: [Line] = []

    public init(windowS: Double) {
        self.windowS = windowS
    }

    public mutating func add(t: Double, speaker: Speaker, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { lines.append(Line(t: t, speaker: speaker, text: trimmed)) }
        prune(now: t)
    }

    public mutating func prune(now: Double) {
        lines.removeAll { now - $0.t > windowS }
    }

    public mutating func render(now: Double) -> String {
        prune(now: now)
        return lines.map { String(format: "[-%4.1fs] ", now - $0.t) + "\($0.speaker.rawValue): \($0.text)" }.joined(separator: "\n")
    }

    public mutating func clear() {
        lines.removeAll()
    }
}

public struct CostTracker: Sendable {
    public let prices: ListenMoreConfig.Prices
    public let budgetUsd: Double
    public private(set) var audioS = 0.0
    public var apiAudioS = 0.0
    public private(set) var inputTokens = 0
    public private(set) var cachedTokens = 0
    public private(set) var outputTokens = 0
    public private(set) var judgeCalls = 0

    public init(prices: ListenMoreConfig.Prices, budgetUsd: Double) {
        self.prices = prices
        self.budgetUsd = budgetUsd
    }

    public mutating func addAudio(seconds: Double) { audioS += seconds }

    public mutating func addJudge(_ u: JudgeUsage) {
        judgeCalls += 1
        inputTokens += u.inputTokens
        cachedTokens += u.cachedTokens
        outputTokens += u.outputTokens
    }

    public var transcribeUsd: Double { max(audioS, apiAudioS) / 60 * prices.transcribePerMinute }

    public var judgeUsd: Double {
        let uncached = Double(inputTokens - cachedTokens)
        return (uncached * prices.judgeInputPerMtok + Double(cachedTokens) * prices.judgeCachedInputPerMtok
            + Double(outputTokens) * prices.judgeOutputPerMtok) / 1e6
    }

    public var totalUsd: Double { transcribeUsd + judgeUsd }
    public var exhausted: Bool { totalUsd >= budgetUsd }
}

/// Orchestrates the transcribers and the judge. Every method must be called on `queue`; callbacks
/// from the transports are hopped back onto it.
public final class GptLayer {
    struct JudgeRequest {
        var refT: Double
        var reason: String
        var questionT: Double?
    }

    let config: ListenMoreConfig
    let queue: DispatchQueue
    let now: () -> Double
    let wallClock: () -> Double
    let transcribers: [Speaker: Transcriber]
    let judge: Judge
    let offer: (_ label: String, _ t: Double, _ refT: Double, _ confidence: Double) -> Void
    let onDisabled: (GptErrorKind) -> Void

    public private(set) var enabled = true
    public private(set) var cost: CostTracker
    public private(set) var transcript: RollingTranscript
    private var preroll: [Speaker: RingBuffer]
    private var streaming: [Speaker: Bool] = [.me: false, .others: false]
    private var inFlight = false
    private var pending: JudgeRequest?
    private var lastJudgeWall = -1e9
    private var prosody: ProsodyFlags?
    private var pendingQuestion: Double?
    private var meSpokeAfterQuestion = false
    private var localRecent: [(t: Double, kind: LocalEvent.Kind)] = []
    private var closed = false

    public init(config: ListenMoreConfig, queue: DispatchQueue, now: @escaping () -> Double,
                wallClock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime },
                transcribers: [Speaker: Transcriber], judge: Judge,
                offer: @escaping (String, Double, Double, Double) -> Void,
                onDisabled: @escaping (GptErrorKind) -> Void) {
        self.config = config
        self.queue = queue
        self.now = now
        self.wallClock = wallClock
        self.transcribers = transcribers
        self.judge = judge
        self.offer = offer
        self.onDisabled = onDisabled
        cost = CostTracker(prices: config.gpt.pricesUsd, budgetUsd: config.gpt.budgetUsdPerCall)
        transcript = RollingTranscript(windowS: config.gpt.judgeWindowS)
        let n = Int(config.gpt.transcribePrerollMs / 1000 * Double(config.audio.sampleRate))
        preroll = [.me: RingBuffer(capacity: n), .others: RingBuffer(capacity: n)]
    }

    public func start() {
        for (speaker, tx) in transcribers {
            tx.start(onText: { [weak self] text, ref in
                self?.queue.async { self?.onText(speaker, text, ref) }
            }, onError: { [weak self] e in
                self?.queue.async { self?.disable(e.kind) }
            })
        }
    }

    public func close() {
        closed = true
        for tx in transcribers.values { tx.close() }
        cost.apiAudioS = transcribers.values.reduce(0) { $0 + $1.reportedAudioSeconds }
        transcript.clear()
        pending = nil
    }

    func disable(_ kind: GptErrorKind) {
        guard enabled else { return }
        enabled = false
        onDisabled(kind)
    }

    // MARK: audio path

    public func feed(_ speaker: Speaker, frame: ArraySlice<Float>, onset: Double?, offset: Double?) {
        guard enabled, !closed, let tx = transcribers[speaker] else { return }
        if cost.exhausted {
            disable(.budgetCap)
            return
        }
        let rate = Double(config.audio.sampleRate)
        if onset != nil && streaming[speaker] != true {
            streaming[speaker] = true
            let pre = preroll[speaker]?.read() ?? []
            if !pre.isEmpty {
                tx.sendAudio(PCM.pcm16(pre))
                cost.addAudio(seconds: Double(pre.count) / rate)
            }
            preroll[speaker]?.clear()
        }
        if streaming[speaker] == true {
            tx.sendAudio(PCM.pcm16(frame))
            cost.addAudio(seconds: Double(frame.count) / rate)
            if let offset {
                streaming[speaker] = false
                tx.commit(refT: offset)
            }
        } else {
            preroll[speaker]?.push(frame)
        }
    }

    // MARK: local signals

    public func onLocal(_ ev: LocalEvent) {
        switch ev.kind {
        case .prosody:
            prosody = ev.prosody
        case .interrupt, .talkOver:
            localRecent.append((ev.onset, ev.kind))
            if localRecent.count > 20 { localRecent.removeFirst(localRecent.count - 20) }
        case .meOnset:
            if let q = pendingQuestion, ev.onset > q { meSpokeAfterQuestion = true }
        case .monologue, .talkShare, .meOffset, .othersOnset, .othersOffset:
            break
        }
    }

    // MARK: transcript path

    func onText(_ speaker: Speaker, _ text: String, _ refT: Double?) {
        guard !closed else { return }
        let t = now()
        transcript.add(t: t, speaker: speaker, text: text)
        let ref = refT ?? t
        if speaker == .others && text.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("?") {
            pendingQuestion = ref
            meSpokeAfterQuestion = false
            let wait = config.gpt.questionWaitS
            queue.asyncAfter(deadline: .now() + max(0, ref + wait - now())) { [weak self] in
                guard let self, !self.closed, self.pendingQuestion == ref else { return }
                self.request(JudgeRequest(refT: ref + wait, reason: "question_deadline", questionT: ref))
            }
        } else if speaker == .me && pendingQuestion != nil {
            meSpokeAfterQuestion = true
        }
        request(JudgeRequest(refT: ref, reason: "\(speaker.rawValue.lowercased())_turn"))
    }

    func request(_ r: JudgeRequest) {
        guard enabled, !closed else { return }
        if inFlight {
            pending = r
            return
        }
        runJudge(r)
    }

    /// Prompt for the judge: transcript + local flags, including the prosody flags from the local layer.
    func buildPrompt(_ r: JudgeRequest) -> String {
        let t = now()
        let p = prosody
        let recent = localRecent.filter { t - $0.t < 30 }.map { "\($0.kind.rawValue)@-" + String(format: "%.1f", t - $0.t) + "s" }
        let pq = pendingQuestion.map { t - $0 < 30 } ?? false
        return "TRANSCRIPT (oldest first):\n\(transcript.render(now: t))\n\n"
            + "LOCAL_FLAGS: prosody_flagged=\(p?.flagged == true ? "yes" : "no") "
            + "loudness_jump_db=\(p?.loudnessJumpDb ?? 0) rate_jump_pct=\(p?.rateJumpPct ?? 0) "
            + "recent_overlaps=\(recent.isEmpty ? "none" : recent.joined(separator: ","))\n"
            + "PENDING_QUESTION: \(pq ? "yes" : "no") ME_ANSWERED_SINCE: \(pq && meSpokeAfterQuestion ? "yes" : "no")\n"
            + "TRIGGER: \(r.reason)"
    }

    private func runJudge(_ r: JudgeRequest) {
        inFlight = true
        let gap = config.gpt.judgeMinIntervalS - (wallClock() - lastJudgeWall)
        if gap > 0 {
            queue.asyncAfter(deadline: .now() + gap) { [weak self] in self?.fireJudge(r) }
        } else {
            fireJudge(r)
        }
    }

    private func fireJudge(_ r: JudgeRequest) {
        guard enabled, !closed else {
            inFlight = false
            return
        }
        if cost.exhausted {
            inFlight = false
            disable(.budgetCap)
            return
        }
        lastJudgeWall = wallClock()
        judge.judge(prompt: buildPrompt(r)) { [weak self] result in
            self?.queue.async { self?.judgeDone(r, result) }
        }
    }

    private func judgeDone(_ r: JudgeRequest, _ result: Result<(JudgeResult, JudgeUsage), GptError>) {
        inFlight = false
        guard !closed else { return }
        switch result {
        case .success(let (res, usage)):
            cost.addJudge(usage)
            if res.cue != "none" {
                if res.cue == "missed_question" && r.questionT != nil { pendingQuestion = nil }
                offer(res.cue, now(), r.refT, res.confidence)
            }
        case .failure(let e):
            disable(e.kind)
        }
        if let next = pending, enabled {
            pending = nil
            runJudge(next)
        }
    }
}

// MARK: test doubles

/// Replays a synthetic clip's scripted text for one stream after a fixed latency. Exercises the
/// plumbing, not transcription quality.
public final class MockTranscriber: Transcriber {
    public struct Utterance: Sendable {
        public var speaker: Speaker
        public var end: Double
        public var text: String

        public init(speaker: Speaker, end: Double, text: String) {
            self.speaker = speaker
            self.end = end
            self.text = text
        }
    }

    let items: [Utterance]
    let latency: Double
    private var emitted = 0
    private var onText: ((String, Double?) -> Void)?
    public private(set) var audioBytes = 0
    public let reportedAudioSeconds = 0.0

    public init(script: [Utterance], speaker: Speaker, latency: Double = 0.05) {
        items = script.filter { $0.speaker == speaker }.sorted { $0.end < $1.end }
        self.latency = latency
    }

    public func start(onText: @escaping (String, Double?) -> Void, onError: @escaping (GptError) -> Void) {
        self.onText = onText
    }

    public func sendAudio(_ pcm16: Data) { audioBytes += pcm16.count }

    public func commit(refT: Double) {
        var due: [String] = []
        while emitted < items.count && items[emitted].end <= refT + 0.3 {
            due.append(items[emitted].text)
            emitted += 1
        }
        guard !due.isEmpty, let onText else { return }
        let text = due.joined(separator: " ")
        DispatchQueue.global().asyncAfter(deadline: .now() + latency) { onText(text, refT) }
    }

    public private(set) var closed = false

    public func close() { closed = true }
}

/// Test double: content-free marker rules + fixed latency. NOT a measure of GPT quality.
public final class MockJudge: Judge {
    /// A ME line containing this marker is judged aggressive.
    public static let hostileMarker = "[mock-hostile]"
    let latency: Double
    public private(set) var prompts: [String] = []

    public init(latency: Double = 0) {
        self.latency = latency
    }

    public static func decide(_ prompt: String) -> JudgeResult {
        let lastMe = prompt.split(separator: "\n").last { $0.contains("] ME:") }?.lowercased() ?? ""
        if lastMe.contains(hostileMarker) { return JudgeResult(cue: "aggressive", confidence: 0.9) }
        if prompt.contains("PENDING_QUESTION: yes") && prompt.contains("ME_ANSWERED_SINCE: no") {
            return JudgeResult(cue: "missed_question", confidence: 0.85)
        }
        return JudgeResult(cue: "none", confidence: 0.9)
    }

    public func judge(prompt: String, completion: @escaping (Result<(JudgeResult, JudgeUsage), GptError>) -> Void) {
        prompts.append(prompt)
        let r = Self.decide(prompt)
        DispatchQueue.global().asyncAfter(deadline: .now() + latency) {
            completion(.success((r, JudgeUsage(inputTokens: 500, cachedTokens: 0, outputTokens: 20))))
        }
    }
}
