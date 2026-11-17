import Foundation

/// Port of the data types in `listen_more/gpt_layer.py`. Everything here is RAM only; transcript
/// text and judge reasons are content and must never be logged.
public enum Speaker: String, CaseIterable, Sendable {
    case me = "ME"
    case others = "OTHERS"
}

public enum GptJudgeSpec {
    public static let labels = ["none", "not_listening"]

    public static var schema: [String: Any] {
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

    public var description: String {
        switch self {
        case .http(let code): return "HTTP \(code)"
        case .badResponse: return "bad response"
        case .notConnected: return "not connected"
        case .budgetExhausted: return "budget cap reached"
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

    public mutating func addJudge(_ u: JudgeUsage) {
        judgeCalls += 1
        inTok += u.inputTokens
        cachedTok += u.cachedTokens
        outTok += u.outputTokens
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
        let uncached = Double(inTok - cachedTok)
        return (uncached * prices.judgeInputPerMtok + Double(cachedTok) * prices.judgeCachedInputPerMtok
                + Double(outTok) * prices.judgeOutputPerMtok) / 1e6
    }

    public var totalUsd: Double {
        transcribeUsd + judgeUsd + judgeCallUsd
    }

    public var exhausted: Bool {
        guard let budget else { return false }
        return totalUsd >= budget
    }

    public var reading: CostReading {
        CostReading(transcribeUsd: transcribeUsd, judgeUsd: judgeUsd, budgetUsd: budget, billedAudioS: billedAudioS)
    }
}

/// The per-call cost meter's lines, for a host to show. Numbers only.
public struct CostReading: Equatable, Sendable {
    public var transcribeUsd: Double
    public var judgeUsd: Double
    public var budgetUsd: Double?
    public var billedAudioS: Double

    public init(transcribeUsd: Double = 0, judgeUsd: Double = 0, budgetUsd: Double? = nil, billedAudioS: Double = 0) {
        self.transcribeUsd = transcribeUsd
        self.judgeUsd = judgeUsd
        self.budgetUsd = budgetUsd
        self.billedAudioS = billedAudioS
    }

    public var totalUsd: Double { transcribeUsd + judgeUsd }

    /// Captions and the saved transcript reuse the cue transcription: no extra API calls, so they add
    /// nothing to the bill. Kept as its own line so the meter says so.
    public var transcriptUsd: Double { 0 }
}
