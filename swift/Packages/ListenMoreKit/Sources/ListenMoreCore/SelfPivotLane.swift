import Foundation

/// Why self-pivot judging stopped for the rest of a call. A class only, never content.
public enum SelfPivotStop: String, Equatable, Sendable {
    /// `gpt.self_pivot_budget_usd_per_call` is spent.
    case budgetCap = "budget_cap"
    /// A judge error that won't clear by itself, or `gpt.judge_max_transient_errors` transient ones.
    case judgeError = "judge_error"
}

/// One call's self-pivot state, shared by every engine run of the call (Pause and the call app's mute
/// restart the engine): the gate's candidates, judge calls sent, spend, the last candidate's turn end on
/// the call's clock, and why judging stopped. Numbers and times only. `CoachSession` starts a new one
/// with each call.
public final class SelfPivotLedger: @unchecked Sendable {
    private let lock = NSLock()
    private var _candidates = 0
    private var _judgeCalls = 0
    private var _usd = 0.0
    private var _lastCandidateTurnEnd: TimeInterval?
    private var _stop: SelfPivotStop?

    public init() {}

    public var candidates: Int { lock.withLock { _candidates } }
    /// Self-pivot judge requests sent this call (the per-call cap counts these).
    public var judgeCalls: Int { lock.withLock { _judgeCalls } }
    public var usd: Double { lock.withLock { _usd } }
    /// On the call's clock (`CoachCallContext.offset` + run time).
    public var lastCandidateTurnEnd: TimeInterval? { lock.withLock { _lastCandidateTurnEnd } }
    public var stop: SelfPivotStop? { lock.withLock { _stop } }

    func recordCandidate(turnEnd: TimeInterval) {
        lock.withLock {
            _candidates += 1
            _lastCandidateTurnEnd = turnEnd
        }
    }

    func recordCall() { lock.withLock { _judgeCalls += 1 } }
    func addUsd(_ usd: Double) { lock.withLock { _usd += usd } }
    /// The first reason sticks.
    func stop(_ reason: SelfPivotStop) { lock.withLock { if _stop == nil { _stop = reason } } }
}

/// The call an engine run belongs to: its self-pivot ledger, and where the run starts on the call's clock
/// (run time + `offset` = call time), so the self-pivot caps and re-arm hold for the whole call.
public struct CoachCallContext: Sendable {
    public let selfPivot: SelfPivotLedger
    public let offset: TimeInterval

    public init(selfPivot: SelfPivotLedger = SelfPivotLedger(), offset: TimeInterval = 0) {
        self.selfPivot = selfPivot
        self.offset = offset
    }
}

/// The self-pivot judge's lane in `GptCore`, apart from the cue judge's: its own request in flight and
/// one queued, its own floor, caps, errors and counters. So neither judge drops the other's request,
/// and a self-pivot error or cap never stops anything else (transcription, captions, the cue judge).
/// A `PivotGate` candidate is judged only when all of these hold:
/// - a self-pivot judge is wired (`wire()`): the configured provider can ask the question
///   (`JudgeProviders.selfPivotJudge`); nothing ever goes to another provider;
/// - `self_pivot` isn't in `cues.disabled`, and `allowed()` (the host's switch, read at each step) says yes;
/// - the call is under `gpt.self_pivot_max_judge_calls_per_call` calls and `gpt.self_pivot_budget_usd_per_call`
///   of spend, and judging hasn't stopped for the call.
/// A verdict becomes an offer when it says self_pivot at `gpt.self_pivot_min_confidence` or more, within
/// `gpt.self_pivot_max_verdict_age_s` of the reply's end, while still allowed. The judge sees only the two
/// turns, redacted (`JudgeRedactor`); the prompt lives in the request, in RAM, and is never logged.
final class SelfPivotLane {
    struct Request: Equatable, Sendable {
        /// The user's last speech in the reply: the cue's onset.
        var replyEnd: TimeInterval
        var turnEnd: TimeInterval
        /// Content: RAM only, never logged.
        var prompt: String
    }

    /// Per engine run, counts only.
    struct Counters: Equatable, Sendable {
        /// Requests sent.
        var calls = 0
        /// Candidates not judged because of the per-call cap, the spend cap or a stop.
        var capped = 0
        var belowFloor = 0
        /// Requests or verdicts past `self_pivot_max_verdict_age_s`.
        var stale = 0
        /// Candidates or verdicts dropped because the host's switch was off.
        var switchedOff = 0
        var failures = 0
    }

    static let label = SelfPivotJudgeSpec.label

    let ledger: SelfPivotLedger
    let offset: TimeInterval
    private let gpt: ListenMoreConfig.Gpt
    private let names: [String]
    private let allowed: @Sendable () -> Bool
    private let enabledByConfig: Bool
    private(set) var wired = false
    private var inFlight = false
    private var pending: Request?
    private var starts: [Request] = []
    private var lastJudgeAt = -1e9
    private var transientErrors = 0
    private(set) var counters = Counters()

    init(config: ListenMoreConfig, call: CoachCallContext, allowed: @escaping @Sendable () -> Bool) {
        gpt = config.gpt
        names = config.text.userNames
        ledger = call.selfPivot
        offset = call.offset
        self.allowed = allowed
        enabledByConfig = !config.cues.disabledTypes.contains(.selfPivot) && config.gpt.selfPivotMaxJudgeCallsPerCall > 0
    }

    /// A self-pivot judge is there to ask.
    func wire() { wired = true }

    /// It would judge a candidate now (ignoring the host's switch and the caps).
    var available: Bool { wired && enabledByConfig }

    /// The gate's seed for a new run: the call's candidates so far and the last one's turn end on this run's clock.
    var seed: PivotGate.Seed {
        PivotGate.Seed(candidates: ledger.candidates, lastCandidateTurnEnd: ledger.lastCandidateTurnEnd.map { $0 - offset })
    }

    func candidate(_ c: PivotGate.Candidate, snippet: PivotGate.Snippet?) {
        ledger.recordCandidate(turnEnd: c.turnEnd + offset)
        guard available, let snippet else { return }
        guard allowed() else {
            counters.switchedOff += 1
            return
        }
        guard ledger.stop == nil, ledger.judgeCalls < gpt.selfPivotMaxJudgeCallsPerCall else {
            counters.capped += 1
            return
        }
        let req = Request(replyEnd: c.replyEnd, turnEnd: c.turnEnd, prompt: Self.prompt(snippet, names: names))
        if inFlight {
            pending = req
        } else {
            inFlight = true
            starts.append(req)
        }
    }

    /// Requests to start now, oldest first.
    func takeStarts() -> [Request] {
        defer { starts.removeAll() }
        return starts
    }

    /// How long to wait before the request, for `judge_min_interval_s` between self-pivot calls.
    func gap(now: TimeInterval) -> Double {
        gpt.judgeMinIntervalS - (now - lastJudgeAt)
    }

    /// The prompt to send now, or nil when the request may no longer go out (the lane's slot stays taken
    /// until `ended()`).
    func begin(_ req: Request, now: TimeInterval) -> String? {
        guard available else { return nil }
        guard allowed() else {
            counters.switchedOff += 1
            return nil
        }
        guard Elapsed.span(now - req.replyEnd) <= gpt.selfPivotMaxVerdictAgeS else {
            counters.stale += 1
            return nil
        }
        if ledger.stop == nil && ledger.usd >= gpt.selfPivotBudgetUsdPerCall { ledger.stop(.budgetCap) }
        guard ledger.stop == nil, ledger.judgeCalls < gpt.selfPivotMaxJudgeCallsPerCall else {
            counters.capped += 1
            return nil
        }
        ledger.recordCall()
        counters.calls += 1
        lastJudgeAt = now
        return req.prompt
    }

    /// A self-pivot judge call finished. Errors stop self-pivot judging only (for the rest of the call).
    func finish(_ req: Request, result: Result<(JudgeResult, JudgeUsage), Error>, cost: inout CostTracker,
                now: TimeInterval) -> GptCore.Offer? {
        switch result {
        case .failure(let error):
            counters.failures += 1
            if GptError.isTransient(error) {
                transientErrors += 1
                if transientErrors >= gpt.judgeMaxTransientErrors { ledger.stop(.judgeError) }
            } else {
                ledger.stop(.judgeError)
            }
            return nil
        case .success(let (res, usage)):
            cost.addSelfPivotJudge(usage)
            ledger.addUsd(cost.judgeUsd(usage))
            if ledger.usd >= gpt.selfPivotBudgetUsdPerCall { ledger.stop(.budgetCap) }
            guard res.cue == Self.label else { return nil }
            guard res.confidence >= gpt.selfPivotMinConfidence else {
                counters.belowFloor += 1
                return nil
            }
            guard Elapsed.span(now - req.replyEnd) <= gpt.selfPivotMaxVerdictAgeS else {
                counters.stale += 1
                return nil
            }
            guard allowed() else {
                counters.switchedOff += 1
                return nil
            }
            return GptCore.Offer(label: Self.label, t: now, refT: req.replyEnd, confidence: res.confidence)
        }
    }

    /// The call is over (whatever happened). Returns the queued request to start next, if any.
    func ended() -> Request? {
        inFlight = false
        guard let next = pending else { return nil }
        pending = nil
        guard available, ledger.stop == nil else { return nil }
        inFlight = true
        return next
    }

    /// The layer stopped or closed: nothing queued goes out.
    func clear() {
        pending = nil
        starts.removeAll()
    }

    /// Their lines, then the user's reply, each redacted, with the speaker labels the cue judge uses.
    static func prompt(_ s: PivotGate.Snippet, names: [String]) -> String {
        let theirs = s.theirs.map { "\(Speaker.others.rawValue): \(JudgeRedactor.redact($0, names: names))" }
        let mine = s.mine.map { "\(Speaker.me.rawValue): \(JudgeRedactor.redact($0, names: names))" }
        return """
        OTHERS' TURN (oldest first):
        \(theirs.joined(separator: "\n"))

        ME'S REPLY:
        \(mine.joined(separator: "\n"))
        TRIGGER: self_pivot
        """
    }
}
