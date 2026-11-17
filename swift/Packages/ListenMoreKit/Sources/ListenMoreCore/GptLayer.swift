import Foundation

/// The GPT layer's rules, synchronous and single-owner (port of `GptLayer` in `gpt_layer.py`):
/// - sends only voiced audio: silent frames inside an utterance are held and sent only if speech
///   resumes, so the VAD hangover never goes out; pre-roll before each onset;
/// - commits at the VAD offset (utterances closer than `transcribe_commit_gap_ms` share a commit; a
///   segment past `transcribe_max_segment_s` commits at its next pause);
/// - meters billed seconds against the per-call budget; at the cap it stops cleanly (no further API
///   calls, transcribers closed) while the local layer keeps cueing;
/// - judges only the user's first line after a substantive OTHERS turn, never mid-monologue, and drops
///   not_listening below `not_listening_min_confidence`; never judges while every cue the provider
///   decides is in `cues.disabled` (GPT decides only not_listening);
/// - stops on the first hard error; transient judge errors skip a verdict up to `judge_max_transient_errors`.
///
/// The judge is a `JudgeProvider` (`judge.provider`). The GPT judge's prompt, verdict rules and errors
/// are the ones above. A state-based provider (TypeSafe) gets the minimal redacted window instead of
/// the prompt; its failures give no cue and never stop the layer, but `max_consecutive_errors` in a
/// row stop judging for the session. Every judge call's latency is kept (counters only).
///
/// `GptLayer` drives it with real sockets and timers; a test or parity harness can drive it on a
/// simulated clock. Transcript text stays in RAM.
public final class GptCore {
    public enum TxAction: Equatable {
        case send(Speaker, [Float])
        case commit(Speaker, refT: TimeInterval)
    }

    public struct JudgeRequest: Equatable, Sendable {
        public var refT: TimeInterval
        public var reason: String
    }

    public struct Offer: Equatable, Sendable {
        public var label: String
        public var t: TimeInterval
        public var refT: TimeInterval
        public var confidence: Double
    }

    public struct Snapshot: Equatable, Sendable {
        public var enabled: Bool
        public var errors: [String]
        public var transientErrors: Int
        public var droppedVerdicts: Int
        public var judgeCalls: Int
        public var totalUsd: Double
        public var audioSecondsSent: Double
        public var billedAudioSeconds: Double
        public var budgetExhausted: Bool
        public var judgeProvider: JudgeProviderKind
        /// False when no judge is wired (a provider without its key) or judging stopped after
        /// repeated provider failures.
        public var judgeActive: Bool
        /// Provider calls that gave no answer (state-based providers; GPT judge errors are above).
        public var judgeFailures: Int
        /// Class of the last provider failure (a status code or a class, never content).
        public var lastJudgeFailure: String?
        public var belowFloorVerdicts: Int
        /// Latency of each recent judge call in ms, oldest first (at most `GptCore.latencyKept`).
        public var judgeLatenciesMs: [Int]
        /// Spend on a per-call priced provider; nil when no price is configured for it.
        public var judgeCallUsd: Double?
        /// Why judging stopped after `max_consecutive_errors` failures in a row (nil while it runs).
        public var judgeStopReason: JudgeFailure?
        /// Tokens a state-based provider reported in `usage`, summed over the session's calls.
        public var judgeInputTokens: Int
        public var judgeOutputTokens: Int
        /// The model the provider's last reply named.
        public var judgeModel: String?
        /// Engine audio time of the latest frame: how long this call has been coached.
        public var callSeconds: Double

        /// Provider tokens per hour of coached call (the provider reports cost as tokens, with no
        /// dollar rate). nil before any audio.
        public var judgeTokensPerCallHour: (input: Double, output: Double)? {
            guard callSeconds > 0 else { return nil }
            let hours = callSeconds / 3600
            return (Double(judgeInputTokens) / hours, Double(judgeOutputTokens) / hours)
        }
    }

    /// Judge call latencies kept for the snapshot.
    public static let latencyKept = 64

    private let config: ListenMoreConfig
    public private(set) var transcript: RollingTranscript
    public private(set) var cost: CostTracker
    public private(set) var enabled = true
    public private(set) var errors: [String] = []
    public private(set) var transientErrors = 0
    public private(set) var droppedVerdicts = 0
    /// Set once, when the layer turns itself off.
    public private(set) var stopReason: GptStopReason?
    /// The budget cap asks for the transcriber sockets to close now; the driver clears it.
    public var closeTranscribersRequested = false
    private var preroll: [Speaker: RingBuffer]
    private var streaming: [Speaker: Bool] = [.me: false, .others: false]
    private var tail: [Speaker: [[Float]]] = [.me: [], .others: []]
    private var commitDue: [Speaker: TimeInterval] = [:]
    private var commitRef: [Speaker: TimeInterval] = [.me: 0, .others: 0]
    private let commitGap: Double
    private let maxSegment: Double
    private var othersSpoke = false
    private var inFlight = false
    private var pending: JudgeRequest?
    private var lastJudgeAt = -1e9
    private var prosody: ProsodyReading?
    private var localRecent: [(TimeInterval, LocalEvent.Kind)] = []
    private var meRunS = 0.0
    public private(set) var judgeActive = true
    public private(set) var judgeFailures = 0
    public private(set) var lastJudgeFailure: JudgeFailure?
    public private(set) var belowFloorVerdicts = 0
    public private(set) var judgeLatenciesMs: [Int] = []
    public private(set) var judgeStopReason: JudgeFailure?
    public private(set) var judgeInputTokens = 0
    public private(set) var judgeOutputTokens = 0
    public private(set) var judgeModel: String?
    public private(set) var callSeconds = 0.0
    private var failuresInARow = 0
    private let judges: Bool

    public init(config: ListenMoreConfig) {
        self.config = config
        judges = !CueType.decided(by: config.judge.provider).isSubset(of: config.cues.disabledTypes)
        transcript = RollingTranscript(windowS: config.gpt.judgeWindowS)
        cost = CostTracker(prices: config.gpt.pricesUsd, budget: config.gpt.budgetUsdPerCall)
        let prerollSamples = Int(Double(config.gpt.transcribePrerollMs) / 1000 * Double(config.audio.sampleRate))
        preroll = [.me: RingBuffer(capacity: prerollSamples), .others: RingBuffer(capacity: prerollSamples)]
        commitGap = config.gpt.transcribeCommitGapMs / 1000
        maxSegment = config.gpt.transcribeMaxSegmentS
    }

    public var snapshot: Snapshot {
        let priced: Bool
        switch config.judge.provider {
        case .gpt: priced = false
        case .typesafe: priced = config.judge.typesafe.costUsdPerCall != nil
        }
        return Snapshot(enabled: enabled, errors: errors, transientErrors: transientErrors, droppedVerdicts: droppedVerdicts,
                        judgeCalls: cost.judgeCalls, totalUsd: cost.totalUsd, audioSecondsSent: cost.audioS,
                        billedAudioSeconds: cost.billedAudioS, budgetExhausted: cost.exhausted,
                        judgeProvider: config.judge.provider, judgeActive: judgeActive, judgeFailures: judgeFailures,
                        lastJudgeFailure: lastJudgeFailure?.description, belowFloorVerdicts: belowFloorVerdicts,
                        judgeLatenciesMs: judgeLatenciesMs, judgeCallUsd: priced ? cost.judgeCallUsd : nil,
                        judgeStopReason: judgeStopReason, judgeInputTokens: judgeInputTokens,
                        judgeOutputTokens: judgeOutputTokens, judgeModel: judgeModel, callSeconds: callSeconds)
    }

    /// No judge calls for the rest of the session (no provider wired, or repeated provider failures).
    /// Transcription and the transcript rules keep running.
    public func stopJudging() {
        judgeActive = false
        pending = nil
    }

    public func recordJudgeLatency(ms: Int) {
        judgeLatenciesMs.append(ms)
        if judgeLatenciesMs.count > Self.latencyKept { judgeLatenciesMs.removeFirst(judgeLatenciesMs.count - Self.latencyKept) }
    }

    public func fail(_ msg: String, reason: GptStopReason = .error) {
        errors.append(msg)
        enabled = false
        if stopReason == nil { stopReason = reason }
    }

    private func budgetStop() {
        fail(GptError.budgetExhausted.description, reason: .budgetCap)
        pending = nil
        closeTranscribersRequested = true
    }

    // MARK: audio path

    /// The user's current run length (local layer), for the mid-monologue judge gate.
    public func setMeRun(_ seconds: Double) {
        meRunS = seconds
    }

    /// One frame of one stream. The driver performs the returned actions in order.
    public func feed(_ speaker: Speaker, frame: [Float], vad: VadState, now: TimeInterval) -> [TxAction] {
        if now > callSeconds { callSeconds = now }
        guard enabled else { return [] }
        if cost.exhausted {
            budgetStop()
            return []
        }
        var out: [TxAction] = []
        if vad.onset != nil && streaming[speaker] != true {
            streaming[speaker] = true
            commitDue[speaker] = nil
            let pre = preroll[speaker]?.read() ?? []
            if !pre.isEmpty { out.append(send(speaker, pre)) }
            preroll[speaker]?.clear()
        }
        if streaming[speaker] == true {
            if vad.raw {
                for held in tail[speaker] ?? [] { out.append(send(speaker, held)) }
                tail[speaker] = []
                out.append(send(speaker, frame))
            } else {
                tail[speaker, default: []].append(frame)
            }
            if let offset = vad.offset {
                streaming[speaker] = false
                tail[speaker] = []
                commitRef[speaker] = offset
                let long = (cost.openS[speaker] ?? 0) >= maxSegment
                commitDue[speaker] = now + (long ? 0 : commitGap)
            }
        } else {
            preroll[speaker]?.push(frame[...])
        }
        if let due = commitDue[speaker], now >= due - 1e-9 {
            commitDue[speaker] = nil
            cost.commit(speaker: speaker)
            out.append(.commit(speaker, refT: commitRef[speaker] ?? 0))
        }
        return out
    }

    private func send(_ speaker: Speaker, _ samples: [Float]) -> TxAction {
        cost.addAudio(seconds: Double(samples.count) / Double(config.audio.sampleRate), speaker: speaker)
        return .send(speaker, samples)
    }

    public func addApiAudio(seconds: Double, speaker: Speaker) {
        cost.addApiAudio(seconds: seconds, speaker: speaker)
    }

    // MARK: local signals

    public func onLocal(_ ev: LocalEvent) {
        switch ev.kind {
        case .prosody:
            prosody = ev.prosody
        case .interrupt, .talkOver:
            localRecent.append((ev.onset, ev.kind))
            if localRecent.count > 20 { localRecent.removeFirst(localRecent.count - 20) }
        case .monologue, .talkShare, .meOnset, .meOffset, .othersOnset, .othersOffset:
            break
        }
    }

    // MARK: transcript path

    /// A transcript arrived. Returns the segment's reference time (for the transcript rules) and a judge
    /// request to start now, if any.
    public func onText(_ speaker: Speaker, text: String, refT: TimeInterval, now: TimeInterval) -> (refT: TimeInterval, start: JudgeRequest?) {
        transcript.add(t: now, speaker: speaker, text: text)
        let ref = refT >= 0 ? refT : now
        if speaker == .others {
            if text.split(whereSeparator: \.isWhitespace).count >= config.gpt.judgeMinOthersWords { othersSpoke = true }
            return (ref, nil)
        }
        var start: JudgeRequest?
        if othersSpoke && !inLongRun && judges { start = request(JudgeRequest(refT: ref, reason: "me_reply")) }
        othersSpoke = false
        return (ref, start)
    }

    private var inLongRun: Bool { meRunS >= config.gpt.judgeSkipRunS }

    /// Returns the request when it should start now; otherwise it is queued (one deep) or dropped.
    public func request(_ req: JudgeRequest) -> JudgeRequest? {
        guard enabled, judgeActive else { return nil }
        if inFlight {
            pending = req
            return nil
        }
        inFlight = true
        return req
    }

    /// How long to wait before the judge call, for `judge_min_interval_s`.
    public func judgeGap(now: TimeInterval) -> Double {
        config.gpt.judgeMinIntervalS - (now - lastJudgeAt)
    }

    /// The prompt to send, or nil when the budget is spent (the layer stops).
    public func beginJudge(_ req: JudgeRequest, now: TimeInterval) -> String? {
        if cost.exhausted {
            budgetStop()
            return nil
        }
        let prompt = buildPrompt(req, now: now)
        lastJudgeAt = now
        return prompt
    }

    /// The input for `kind`, or nil when the budget is spent (the layer stops). The GPT judge gets
    /// `beginJudge(_:now:)`'s prompt; a state-based provider gets only the minimal redacted window.
    public func beginJudge(_ req: JudgeRequest, now: TimeInterval, for kind: JudgeProviderKind) -> JudgeInput? {
        switch kind {
        case .gpt:
            return beginJudge(req, now: now).map { JudgeInput(prompt: $0, window: []) }
        case .typesafe:
            if cost.exhausted {
                budgetStop()
                return nil
            }
            lastJudgeAt = now
            return JudgeInput(prompt: "", window: judgeWindow(now: now))
        }
    }

    /// What a state-based judge sees: at most `max_lines` lines heard in the last `window_s` seconds,
    /// each with its speaker label, seconds ago and redacted text. No prosody, overlaps or trigger.
    func judgeWindow(now t: TimeInterval) -> [JudgeLine] {
        let ts = config.judge.typesafe
        transcript.prune(now: t)
        return transcript.lines.filter { t - $0.t <= ts.windowS }.suffix(ts.maxLines).map {
            JudgeLine(speaker: $0.speaker, secondsAgo: max(0, t - $0.t), text: JudgeRedactor.redact($0.text, names: config.text.userNames))
        }
    }

    /// A judge call finished, from any provider. GPT replies and errors go through
    /// `finishJudge(_:result:now:)` unchanged.
    public func finishJudge(_ req: JudgeRequest, reply: Result<JudgeReply, Error>, now: TimeInterval) -> [Offer] {
        switch reply {
        case .failure(let error):
            return finishJudge(req, result: .failure(error), now: now).map { [$0] } ?? []
        case .success(.gpt(let res, let usage)):
            return finishJudge(req, result: .success((res, usage)), now: now).map { [$0] } ?? []
        case .success(.decided(let d)):
            return finishDecision(req, d, now: now)
        }
    }

    private func finishDecision(_ req: JudgeRequest, _ d: JudgeDecision, now: TimeInterval) -> [Offer] {
        cost.addJudgeCall(usd: d.costUsd)
        belowFloorVerdicts += d.belowFloor
        judgeInputTokens += d.inputTokens
        judgeOutputTokens += d.outputTokens
        if let model = d.model { judgeModel = model }
        if let failure = d.failure {
            judgeFailures += 1
            lastJudgeFailure = failure
            failuresInARow += 1
            if failuresInARow >= config.judge.typesafe.maxConsecutiveErrors && judgeActive {
                judgeStopReason = failure
                stopJudging()
            }
            return []
        }
        failuresInARow = 0
        return d.verdicts.compactMap { v in
            if v.label == CueType.notListening.rawValue && inLongRun {
                droppedVerdicts += 1
                return nil
            }
            return Offer(label: v.label, t: now, refT: req.refT, confidence: v.confidence)
        }
    }

    /// A judge call finished. Returns the verdict to offer, if any.
    public func finishJudge(_ req: JudgeRequest, result: Result<(JudgeResult, JudgeUsage), Error>, now: TimeInterval) -> Offer? {
        switch result {
        case .failure(let error):
            if GptError.isTransient(error) {
                transientErrors += 1
                if transientErrors >= config.gpt.judgeMaxTransientErrors { fail("judge: repeated transient errors") }
            } else {
                fail("judge: \(GptError.safe(error))")
            }
            return nil
        case .success(let (res, usage)):
            cost.addJudge(usage)
            if res.cue == "not_listening" && (res.confidence < config.gpt.notListeningMinConfidence || inLongRun) {
                droppedVerdicts += 1
                return nil
            }
            guard res.cue != "none" else { return nil }
            return Offer(label: res.cue, t: now, refT: req.refT, confidence: res.confidence)
        }
    }

    /// The judge call is over (whatever happened). Returns the queued request to start next, if any.
    public func judgeEnded() -> JudgeRequest? {
        inFlight = false
        guard let next = pending, enabled else { return nil }
        pending = nil
        inFlight = true
        return next
    }

    func buildPrompt(_ req: JudgeRequest, now t: TimeInterval) -> String {
        let p = prosody
        let recent = localRecent.filter { t - $0.0 < 30 }.map { "\($0.1.rawValue)@-\(String(format: "%.1f", t - $0.0))s" }
        return """
        TRANSCRIPT (oldest first):
        \(transcript.render(now: t))

        LOCAL_FLAGS: prosody_enabled=\(config.local.prosodyEnabled ? "yes" : "no") \
        prosody_flagged=\(p?.flagged == true ? "yes" : "no") loudness_jump_db=\(Self.num(p?.loudnessJumpDb ?? 0)) \
        rate_jump_pct=\(Self.num(p?.rateJumpPct ?? 0)) recent_overlaps=\(recent.isEmpty ? "none" : recent.joined(separator: ","))
        TRIGGER: \(req.reason)
        """
    }

    /// Python prints floats with `{}`: 0.0 for zero, one decimal for the rounded jumps.
    static func num(_ x: Double) -> String {
        x == x.rounded() && abs(x) < 1e15 ? String(format: "%.1f", x) : String(x)
    }

    public func clearTranscript() {
        transcript.clear()
    }
}

/// Realtime transcription + judge around `GptCore`, on one serial event loop (`inbox`), so frames,
/// local events, transcripts and judge results are handled in order, like the Python asyncio loop.
/// Transcripts go to `onSegment` (the transcript rules) and verdicts to `offer`, both from the loop.
/// `onCaption` gets partial and final text while the layer is on (nothing once it stops), and
/// `onMeter` the cost reading after each billed segment, judge call and stop.
public final class GptLayer: @unchecked Sendable {
    public typealias Offer = @Sendable (_ label: String, _ t: TimeInterval, _ refT: TimeInterval, _ confidence: Double) -> Void
    public typealias SegmentSink = @Sendable (_ speaker: Speaker, _ text: String, _ refT: TimeInterval, _ now: TimeInterval) -> Void
    public typealias CaptionSink = @Sendable (CaptionEvent) -> Void
    public typealias MeterSink = @Sendable (CostReading) -> Void
    public typealias Snapshot = GptCore.Snapshot

    enum Command {
        case start
        case frame(me: [Float], meVad: VadState, others: [Float], othersVad: VadState, meRunS: Double)
        case local(LocalEvent)
        case transcript(TranscriptEvent)
        case runJudge(GptCore.JudgeRequest)
        case judgeDone(GptCore.JudgeRequest, Result<JudgeReply, Error>, latencyMs: Int)
        case snapshot(CheckedContinuation<Snapshot, Never>)
        case close(CheckedContinuation<Void, Never>)
    }

    private let core: GptCore
    private let now: @Sendable () -> TimeInterval
    private let offer: Offer
    private let onSegment: SegmentSink?
    private let onStopped: (@Sendable (GptStopReason) -> Void)?
    private let onJudgeStopped: (@Sendable (JudgeFailure) -> Void)?
    private let onCaption: CaptionSink?
    private let onMeter: MeterSink?
    private let scheduler: GptScheduler
    private let judge: JudgeProvider?
    private var transcribers: [Speaker: TranscriptionSession] = [:]
    private let inbox: AsyncStream<Command>.Continuation
    private var loop: Task<Void, Never>?
    private var tasks: [Task<Void, Never>] = []
    private var stopReported = false
    private var judgeStopReported = false
    private var transcribersClosed = false

    /// `transcriberFactory` builds one session per speaker and must route its events to the given callback.
    /// `onStopped` is called once, from the event loop, when the layer turns itself off; `onJudgeStopped`
    /// once when judging stops after repeated provider failures, with the failure that stopped it.
    /// `provider` nil: nothing is judged (transcripts still reach `onSegment`).
    public init(config: ListenMoreConfig, now: @escaping @Sendable () -> TimeInterval, offer: @escaping Offer,
                onSegment: SegmentSink? = nil, onStopped: (@Sendable (GptStopReason) -> Void)? = nil,
                onJudgeStopped: (@Sendable (JudgeFailure) -> Void)? = nil,
                onCaption: CaptionSink? = nil, onMeter: MeterSink? = nil,
                provider: JudgeProvider?, scheduler: GptScheduler,
                transcriberFactory: (Speaker, @escaping @Sendable (TranscriptEvent) -> Void) -> TranscriptionSession) {
        core = GptCore(config: config)
        if provider == nil { core.stopJudging() }
        self.now = now
        self.offer = offer
        self.onSegment = onSegment
        self.onStopped = onStopped
        self.onJudgeStopped = onJudgeStopped
        self.onCaption = onCaption
        self.onMeter = onMeter
        self.judge = provider
        self.scheduler = scheduler
        var continuation: AsyncStream<Command>.Continuation!
        let stream = AsyncStream<Command> { continuation = $0 }
        inbox = continuation
        for speaker in Speaker.allCases {
            transcribers[speaker] = transcriberFactory(speaker) { [inbox] ev in inbox.yield(.transcript(ev)) }
        }
        loop = Task { [weak self] in
            for await cmd in stream {
                guard let self else { return }
                if await self.handle(cmd) { return }
            }
        }
    }

    /// The GPT judge (any `CueJudge`) as the provider.
    public convenience init(config: ListenMoreConfig, now: @escaping @Sendable () -> TimeInterval, offer: @escaping Offer,
                            onSegment: SegmentSink? = nil, onStopped: (@Sendable (GptStopReason) -> Void)? = nil,
                            onCaption: CaptionSink? = nil, onMeter: MeterSink? = nil,
                            judge: CueJudge, scheduler: GptScheduler,
                            transcriberFactory: (Speaker, @escaping @Sendable (TranscriptEvent) -> Void) -> TranscriptionSession) {
        self.init(config: config, now: now, offer: offer, onSegment: onSegment, onStopped: onStopped,
                  onCaption: onCaption, onMeter: onMeter,
                  provider: GptJudgeProvider(judge), scheduler: scheduler, transcriberFactory: transcriberFactory)
    }

    /// Production wiring: realtime transcription over WebSocket (OpenAI, `key`) + the judge
    /// `config.judge.provider` selects (`JudgeProviders.make`; `judgeKey` is the TypeSafe key).
    public convenience init(config: ListenMoreConfig, key: APIKey, judgeKey: APIKey? = nil, transports: GptTransports,
                            now: @escaping @Sendable () -> TimeInterval, offer: @escaping Offer,
                            onSegment: SegmentSink? = nil, onStopped: (@Sendable (GptStopReason) -> Void)? = nil,
                            onJudgeStopped: (@Sendable (JudgeFailure) -> Void)? = nil,
                            onCaption: CaptionSink? = nil, onMeter: MeterSink? = nil) {
        self.init(config: config, now: now, offer: offer, onSegment: onSegment, onStopped: onStopped, onJudgeStopped: onJudgeStopped,
                  onCaption: onCaption, onMeter: onMeter,
                  provider: JudgeProviders.make(config: config, openAIKey: key, judgeKey: judgeKey, http: transports.http,
                                                scheduler: transports.scheduler),
                  scheduler: transports.scheduler) { speaker, onEvent in
            LiveTranscriber(config: config, key: key, speaker: speaker, connector: transports.webSocket, onEvent: onEvent)
        }
    }

    // MARK: inputs (any thread; processed in order)

    public func start() { inbox.yield(.start) }

    /// Both streams' frame and VAD state, plus the user's current run length.
    public func feed(me: [Float], meVad: VadState, others: [Float], othersVad: VadState, meRunS: Double) {
        inbox.yield(.frame(me: me, meVad: meVad, others: others, othersVad: othersVad, meRunS: meRunS))
    }

    public func onLocal(_ event: LocalEvent) { inbox.yield(.local(event)) }

    public func snapshot() async -> Snapshot {
        await withCheckedContinuation { inbox.yield(.snapshot($0)) }
    }

    /// Cancels timers and judge calls, closes both sessions and clears the transcript.
    public func close() async {
        await withCheckedContinuation { inbox.yield(.close($0)) }
        inbox.finish()
    }

    // MARK: event loop

    /// Returns true when the loop should stop.
    private func handle(_ cmd: Command) async -> Bool {
        switch cmd {
        case .start:
            do {
                for speaker in Speaker.allCases { try await transcribers[speaker]?.start() }
            } catch {
                core.fail("realtime connect: \(GptError.safe(error))")
            }
        case let .frame(me, meVad, others, othersVad, meRunS):
            core.setMeRun(meRunS)
            await perform(core.feed(.me, frame: me, vad: meVad, now: now()))
            await perform(core.feed(.others, frame: others, vad: othersVad, now: now()))
        case .local(let ev):
            core.onLocal(ev)
        case .transcript(.text(let speaker, let text, let refT)):
            let t = now()
            let r = core.onText(speaker, text: text, refT: refT, now: t)
            onSegment?(speaker, text, r.refT, t)
            if core.enabled { onCaption?(.final(speaker, text: text)) }
            if let req = r.start { schedule(req) }
        case .transcript(.delta(let speaker, let text, let item)):
            if core.enabled { onCaption?(.partial(speaker, item: item, text: text)) }
        case .transcript(.usage(let speaker, let seconds)):
            core.addApiAudio(seconds: seconds, speaker: speaker)
            onMeter?(core.cost.reading)
        case .transcript(.error(let msg)):
            core.fail(msg)
        case .runJudge(let req):
            runJudge(req)
        case let .judgeDone(req, result, latencyMs):
            core.recordJudgeLatency(ms: latencyMs)
            for o in core.finishJudge(req, reply: result, now: now()) { offer(o.label, o.t, o.refT, o.confidence) }
            onMeter?(core.cost.reading)
            if let next = core.judgeEnded() { schedule(next) }
        case .snapshot(let c):
            c.resume(returning: core.snapshot)
        case .close(let c):
            tasks.forEach { $0.cancel() }
            tasks.removeAll()
            await closeTranscribers()
            core.clearTranscript()
            c.resume()
            return true
        }
        if core.closeTranscribersRequested {
            core.closeTranscribersRequested = false
            await closeTranscribers()
        }
        if let reason = core.stopReason, !stopReported {
            stopReported = true
            onMeter?(core.cost.reading)
            onStopped?(reason)
        }
        if let failure = core.judgeStopReason, !judgeStopReported {
            judgeStopReported = true
            onJudgeStopped?(failure)
        }
        return false
    }

    private func perform(_ actions: [GptCore.TxAction]) async {
        for action in actions {
            guard core.enabled else { return }
            do {
                switch action {
                case let .send(speaker, samples):
                    try await transcribers[speaker]?.sendAudio(AudioMath.pcm16Data(samples[...]))
                case let .commit(speaker, refT):
                    try await transcribers[speaker]?.commit(refT: refT)
                }
            } catch {
                core.fail("realtime send: \(GptError.safe(error))")
            }
        }
    }

    private func closeTranscribers() async {
        guard !transcribersClosed else { return }
        transcribersClosed = true
        for t in transcribers.values { await t.close() }
    }

    private func spawn(_ op: @escaping @Sendable () async -> Void) {
        tasks.removeAll { $0.isCancelled }
        tasks.append(Task { await op() })
    }

    private func schedule(_ req: GptCore.JudgeRequest) {
        let gap = core.judgeGap(now: now())
        spawn { [scheduler, inbox] in
            if gap > 0 { try? await scheduler.sleep(seconds: gap) }
            guard !Task.isCancelled else { return }
            inbox.yield(.runJudge(req))
        }
    }

    private func runJudge(_ req: GptCore.JudgeRequest) {
        guard let judge, let input = core.beginJudge(req, now: now(), for: judge.kind) else {
            if let next = core.judgeEnded() { schedule(next) }
            return
        }
        spawn { [scheduler, inbox] in
            let start = scheduler.monotonic()
            let result: Result<JudgeReply, Error>
            do {
                result = .success(try await judge.judge(input))
            } catch {
                result = .failure(error)
            }
            let ms = Int(((scheduler.monotonic() - start) * 1000).rounded())
            inbox.yield(.judgeDone(req, result, latencyMs: ms))
        }
    }
}
