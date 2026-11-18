import Foundation

/// Port of the data types in `listen_more/gpt_layer.py`. Everything here is RAM only; transcript
/// text and judge reasons are content and must never be logged.
public enum Speaker: String, CaseIterable, Sendable {
    case me = "ME"
    case others = "OTHERS"
}

public enum GptJudgeSpec {
    public static let labels = ["none", "not_listening"]

    public static var schema: [String: Any] { JudgeSpec.cue.schema }

    public static let instructions = """
    You are a silent, conservative listening coach for ME on a live work call.
    You see the last ~90 seconds of a speaker-labelled transcript (ME = the user's mic, OTHERS = everyone else
    on the call), plus local acoustic flags. Cut-ins, talk-over, long runs, unanswered questions and heated
    wording are handled by other detectors. Your only job: decide if ME's LATEST line, which directly
    follows a turn by OTHERS, brushes past the specific point OTHERS just made.
    Labels:
    - not_listening: OTHERS made a concrete point, request or concern in their last turn, and ME's latest
      line does not engage with it at all: it dismisses it ("anyway", "whatever", "that's not the point"),
      talks over it with an earlier point, or restates a position as if they had not spoken.
    - none: everything else, including: agreeing or acknowledging; answering or building on their point; asking
      a follow-up; disagreeing while addressing what they said; small talk, greetings, wrap-ups; a long
      explanation or a story (run length is another detector's job); a new topic after OTHERS finished theirs;
      a last OTHERS turn that was only a backchannel ("yeah", "right", "mm-hm").
    Prefer none when unsure. A false alarm is much worse than a miss. Use confidence above 0.85 only when the
    brush-off is unmistakable from the words alone.
    Return confidence in [0,1] and a short_reason of at most 12 words.
    """
}

/// One Responses judge question: its instructions and the strict schema of its answer. The cue judge
/// (`GptJudgeSpec`, the me_reply trigger) and the self-pivot judge (`SelfPivotJudgeSpec`) are each one.
public struct JudgeSpec: Equatable, Sendable {
    public var name: String
    public var instructions: String
    public var labels: [String]

    public static let cue = JudgeSpec(name: "listen_more_cue", instructions: GptJudgeSpec.instructions, labels: GptJudgeSpec.labels)
    public static let selfPivot = JudgeSpec(name: SelfPivotJudgeSpec.name, instructions: SelfPivotJudgeSpec.instructions,
                                            labels: SelfPivotJudgeSpec.labels)

    public var schema: [String: Any] {
        [
            "type": "object",
            "additionalProperties": false,
            "properties": [
                "cue": ["type": "string", "enum": labels],
                "confidence": ["type": "number"],
                "short_reason": ["type": "string"],
            ],
            "required": ["cue", "confidence", "short_reason"],
        ]
    }
}

/// The self-pivot judge: a candidate from `PivotGate` (they shared something personal, the user answered
/// at length about themselves and asked nothing back) is confirmed or not from the two turns alone.
public enum SelfPivotJudgeSpec {
    public static let name = "listen_more_self_pivot"
    public static let label = CueType.selfPivot.rawValue
    public static let labels = ["none", label]

    public static let instructions = """
    You are a silent, conservative listening coach for ME on a live call.
    You see two turns, redacted: what OTHERS just said (OTHERS is everyone else on the call, and can be several
    people), then ME's reply. Decide if ME's reply turned the talk to ME's own story instead of staying with what
    OTHERS shared.
    Labels:
    - self_pivot: OTHERS shared something personal (news, a feeling, an event in their life), and ME's reply is
      mainly ME's own experience (a story, a comparison, ME's own news) and asks OTHERS nothing back about what they
      shared. Acknowledging first ("congrats", "so sorry", "that sounds great") and then telling ME's own story
      still counts as self_pivot.
    - none: everything else, including: ME asks OTHERS a question or invites them to say more; ME reacts,
      sympathizes or congratulates without a story of ME's own; ME offers help, time, or well-wishes; ME plans
      something for them or for the group (a celebration, a dinner); ME passes on a message for them from someone
      else; ME's reply is about work or the agenda; OTHERS had moved on to the agenda or handed the floor to
      someone before ME spoke; OTHERS' turn was not a personal share.
    Prefer none when unsure. A false alarm is much worse than a miss. Use confidence above 0.85 only when the
    turn to ME's own story is unmistakable from the words alone.
    Return confidence in [0,1] and a short_reason of at most 12 words.
    """
}

public struct JudgeResult: Equatable, Sendable {
    public var cue: String
    public var confidence: Double
    /// Content: kept in memory for the caller only, never logged.
    public var shortReason: String

    public init(cue: String, confidence: Double, shortReason: String) {
        self.cue = cue
        self.confidence = confidence
        self.shortReason = shortReason
    }
}

public struct JudgeUsage: Equatable, Sendable {
    public var inputTokens: Int
    public var cachedTokens: Int
    public var outputTokens: Int

    public init(inputTokens: Int = 0, cachedTokens: Int = 0, outputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.cachedTokens = cachedTokens
        self.outputTokens = outputTokens
    }
}

/// Errors whose descriptions cannot carry request headers, bodies or transcript text (so never the key).
public enum GptError: Error, Equatable, CustomStringConvertible {
    case http(Int)
    case badResponse
    case notConnected
    case budgetExhausted
    /// The configured Responses host answered 401 incorrect_hostname and the regional host it named
    /// failed too. Hosts and the inner error class only.
    case hostRejected(first: String, regional: String, inner: String)
    /// A 401 incorrect_hostname named a host that isn't `api.openai.com` or `<label>.api.openai.com` over https.
    /// Nothing is sent to it. A judge error: it stops that judge's cue only.
    case untrustedHost
    /// A 401 incorrect_hostname named only the host just used: there is nowhere else to send it.
    case redirectToSameHost
    /// A 401 incorrect_hostname whose one resend the call's owner refused (the switch is off, a cap is reached
    /// or the layer stopped). Not a fault of the judge: the self-pivot lane goes on.
    case resendRefused

    public var description: String {
        switch self {
        case .http(let code): return "HTTP \(code)"
        case .badResponse: return "bad response"
        case .notConnected: return "not connected"
        case .budgetExhausted: return "budget cap reached"
        case .untrustedHost: return "responses host redirect to a host that is not an OpenAI API host; set gpt.responses_url"
        case .redirectToSameHost: return "responses host redirect names the host just used; set gpt.responses_url"
        case .resendRefused: return "responses host redirect not followed (resend not allowed)"
        case let .hostRejected(first, regional, inner):
            return "responses host \(first) rejected the key (incorrect_hostname) and the regional host \(regional) failed too (\(inner)); set gpt.responses_url"
        }
    }

    /// Port of `safe_err`: status code or error type name only.
    public static func safe(_ error: Error) -> String {
        if let g = error as? GptError { return g.description }
        if let u = error as? URLError { return "URLError \(u.code.rawValue)" }
        return String(describing: type(of: error))
    }

    /// Redirect-path errors: the cue judge stops judging for them (never the layer), and the self-pivot lane
    /// stops for all but `resendRefused`.
    public var isRedirectProblem: Bool {
        switch self {
        case .untrustedHost, .redirectToSameHost, .resendRefused, .hostRejected: return true
        case .http, .badResponse, .notConnected, .budgetExhausted: return false
        }
    }

    /// The learned host (if the call used one) is no good for this key: forget it.
    var isHostFault: Bool {
        switch self {
        case .untrustedHost, .redirectToSameHost, .resendRefused, .hostRejected: return true
        case .http(let code): return !(code == 429 || code >= 500)
        case .badResponse, .notConnected, .budgetExhausted: return false
        }
    }

    /// Port of `is_transient`: network blips and overload skip one verdict instead of stopping the layer.
    public static func isTransient(_ error: Error) -> Bool {
        if case .http(let code)? = error as? GptError { return code == 429 || code >= 500 }
        return error is URLError
    }
}

/// ~90 s speaker-labelled transcript, RAM only.
public struct RollingTranscript {
    public struct Line: Equatable {
        public var t: TimeInterval
        public var speaker: Speaker
        public var text: String
    }

    public let windowS: Double
    public private(set) var lines: [Line] = []

    public init(windowS: Double) {
        self.windowS = windowS
    }

    public mutating func add(t: TimeInterval, speaker: Speaker, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty { lines.append(Line(t: t, speaker: speaker, text: trimmed)) }
        prune(now: t)
    }

    public mutating func prune(now: TimeInterval) {
        while let first = lines.first, now - first.t > windowS { lines.removeFirst() }
    }

    public mutating func render(now: TimeInterval) -> String {
        prune(now: now)
        return lines.map { "[-\(Self.fixed1(now - $0.t, width: 4))s] \($0.speaker.rawValue): \($0.text)" }.joined(separator: "\n")
    }

    public mutating func clear() {
        lines.removeAll()
    }

    /// Python `f"{x:4.1f}"`.
    static func fixed1(_ x: Double, width: Int) -> String {
        let s = String(format: "%.1f", x)
        return String(repeating: " ", count: max(0, width - s.count)) + s
    }
}

/// Port of `CostTracker`. Transcription is billed per committed segment, rounded up to whole seconds.
/// The meter counts API-reported seconds as they arrive and estimates segments the API has not reported
/// yet (and the open one) with that rule, so the budget cap tracks the bill rather than the audio sent.
public struct CostTracker: Equatable {
    public let prices: ListenMoreConfig.Gpt.Prices
    public let budget: Double?
    public private(set) var audioS = 0.0
    /// Seconds reported back by the API.
    public private(set) var apiAudioS = 0.0
    public private(set) var segments = 0
    public private(set) var openS: [Speaker: Double] = [:]
    private var unreported: [Speaker: [Double]] = [:]
    public private(set) var inTok = 0
    public private(set) var cachedTok = 0
    public private(set) var outTok = 0
    public private(set) var judgeCalls = 0
    /// Flat per-call judge prices (`judge.typesafe.cost_usd_per_call`), summed. 0 on the GPT judge,
    /// which is metered by tokens, and for a provider with no configured price.
    public private(set) var judgeCallUsd = 0.0

    public init(prices: ListenMoreConfig.Gpt.Prices, budget: Double?) {
        self.prices = prices
        self.budget = budget
    }

    public mutating func addAudio(seconds: Double, speaker: Speaker) {
        audioS += seconds
        openS[speaker, default: 0] += seconds
    }

    public mutating func commit(speaker: Speaker) {
        let sent = openS.removeValue(forKey: speaker) ?? 0
        if sent > 0 {
            segments += 1
            unreported[speaker, default: []].append(sent)
        }
    }

    /// The open segment was cleared, never committed: nothing of it is transcribed or billed.
    public mutating func discardOpen(speaker: Speaker) {
        openS.removeValue(forKey: speaker)
    }

    public mutating func addApiAudio(seconds: Double, speaker: Speaker) {
        apiAudioS += seconds
        if unreported[speaker]?.isEmpty == false { unreported[speaker]?.removeFirst() }
    }

    public var estimatedUnreportedS: Double {
        let open = openS.values.filter { $0 > 0 }.reduce(0) { $0 + $1.rounded(.up) }
        return open + unreported.values.flatMap { $0 }.reduce(0) { $0 + $1.rounded(.up) }
    }

    public var billedAudioS: Double { apiAudioS + estimatedUnreportedS }

    /// The self-pivot judge's share of the judge calls and tokens above (`SelfPivotLane`); the rest is
    /// the cue judge's.
    public private(set) var selfPivotCalls = 0
    public private(set) var selfPivotInTok = 0
    public private(set) var selfPivotCachedTok = 0
    public private(set) var selfPivotOutTok = 0

    public mutating func addJudge(_ u: JudgeUsage) {
        judgeCalls += 1
        inTok += u.inputTokens
        cachedTok += u.cachedTokens
        outTok += u.outputTokens
    }

    /// One answered self-pivot judge call: counted in the totals and in its own share.
    public mutating func addSelfPivotJudge(_ u: JudgeUsage) {
        addJudge(u)
        selfPivotCalls += 1
        selfPivotInTok += u.inputTokens
        selfPivotCachedTok += u.cachedTokens
        selfPivotOutTok += u.outputTokens
    }

    /// What `u` costs at the judge's token prices.
    public func judgeUsd(_ u: JudgeUsage) -> Double {
        Self.tokenUsd(prices, input: u.inputTokens, cached: u.cachedTokens, output: u.outputTokens)
    }

    private static func tokenUsd(_ p: ListenMoreConfig.Gpt.Prices, input: Int, cached: Int, output: Int) -> Double {
        (Double(input - cached) * p.judgeInputPerMtok + Double(cached) * p.judgeCachedInputPerMtok
            + Double(output) * p.judgeOutputPerMtok) / 1e6
    }

    public var selfPivotJudgeUsd: Double {
        Self.tokenUsd(prices, input: selfPivotInTok, cached: selfPivotCachedTok, output: selfPivotOutTok)
    }

    /// One call to a provider priced per call (nil: no price configured). Its tokens are never
    /// priced at the GPT judge's rates.
    public mutating func addJudgeCall(usd: Double?) {
        judgeCalls += 1
        judgeCallUsd += usd ?? 0
    }

    public var transcribeUsd: Double {
        billedAudioS / 60 * prices.transcribePerMinute
    }

    public var judgeUsd: Double {
        Self.tokenUsd(prices, input: inTok, cached: cachedTok, output: outTok)
    }

    public var totalUsd: Double {
        transcribeUsd + judgeUsd + judgeCallUsd
    }

    public var exhausted: Bool {
        guard let budget else { return false }
        return totalUsd >= budget
    }

    public var reading: CostReading {
        CostReading(transcribeUsd: transcribeUsd, judgeUsd: judgeUsd, budgetUsd: budget, billedAudioS: billedAudioS,
                    selfPivotJudgeUsd: selfPivotJudgeUsd)
    }
}

/// The per-call cost meter's lines, for a host to show. Numbers only.
public struct CostReading: Equatable, Sendable {
    public var transcribeUsd: Double
    public var judgeUsd: Double
    public var budgetUsd: Double?
    public var billedAudioS: Double
    /// The self-pivot judge's part of `judgeUsd`.
    public var selfPivotJudgeUsd: Double

    public init(transcribeUsd: Double = 0, judgeUsd: Double = 0, budgetUsd: Double? = nil, billedAudioS: Double = 0,
                selfPivotJudgeUsd: Double = 0) {
        self.transcribeUsd = transcribeUsd
        self.judgeUsd = judgeUsd
        self.budgetUsd = budgetUsd
        self.billedAudioS = billedAudioS
        self.selfPivotJudgeUsd = selfPivotJudgeUsd
    }

    public var totalUsd: Double { transcribeUsd + judgeUsd }

    /// Captions and the saved transcript reuse the cue transcription: no extra API calls, so they add
    /// nothing to the bill. Kept as its own line so the meter says so.
    public var transcriptUsd: Double { 0 }
}
