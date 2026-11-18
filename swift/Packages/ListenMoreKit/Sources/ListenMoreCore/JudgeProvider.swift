import Foundation

/// Which judge decides the judged cues (`judge.provider`). `gpt`, the default, is the Responses judge
/// (`LiveJudge`), unchanged; `typesafe` is `TypeSafeJudge`. Transcription is OpenAI's either way.
public enum JudgeProviderKind: String, CaseIterable, Decodable, Equatable, Sendable {
    case gpt
    case typesafe
}

/// One transcript line as a state-based judge sees it: the speaker label, seconds since the line was
/// heard and the redacted text. Content: RAM only, never logged.
public struct JudgeLine: Equatable, Sendable {
    public var speaker: Speaker
    public var secondsAgo: Double
    public var text: String

    public init(speaker: Speaker, secondsAgo: Double, text: String) {
        self.speaker = speaker
        self.secondsAgo = secondsAgo
        self.text = text
    }
}

/// What one judge call gets. The GPT judge reads `prompt` (exactly what it always read) and gets no
/// window; a state-based provider reads `window` and gets an empty prompt.
public struct JudgeInput: Equatable, Sendable {
    public var prompt: String
    public var window: [JudgeLine]

    public init(prompt: String, window: [JudgeLine]) {
        self.prompt = prompt
        self.window = window
    }
}

/// A judged cue that fired at or above the provider's confidence floor.
public struct JudgeVerdict: Equatable, Sendable {
    public var label: String
    public var confidence: Double

    public init(label: String, confidence: Double) {
        self.label = label
        self.confidence = confidence
    }
}

/// Why a provider call gave no answer. A status code or a class only: never a header, a body, the
/// transcript or the key.
public enum JudgeFailure: Error, Equatable, Sendable, CustomStringConvertible {
    case http(Int)
    case timeout
    case transport
    case badResponse

    public var description: String {
        switch self {
        case .http(let code): "HTTP \(code)"
        case .timeout: "timeout"
        case .transport: "transport error"
        case .badResponse: "bad response"
        }
    }

    /// What kind of problem it was, for a host to explain why judging stopped.
    public var kind: JudgeFailureKind {
        switch self {
        case .http(let code):
            switch code {
            case 401, 403: return .auth
            case 402: return .balance
            case 429: return .rateLimited
            case 500...: return .server
            default: return .rejected
            }
        case .timeout: return .timeout
        case .transport: return .unreachable
        case .badResponse: return .badReply
        }
    }

    /// Network errors by class; anything else is a transport error (its description is never read).
    public static func classify(_ error: Error) -> JudgeFailure {
        if let f = error as? JudgeFailure { return f }
        if error is CancellationError { return .timeout }
        if let u = error as? URLError, u.code == .timedOut { return .timeout }
        return .transport
    }
}

public enum JudgeFailureKind: String, CaseIterable, Equatable, Sendable {
    /// 401 or 403: the key was not accepted.
    case auth
    /// 402: insufficient balance.
    case balance
    /// 429.
    case rateLimited
    /// 5xx.
    case server
    /// Any other HTTP status.
    case rejected
    case timeout
    case unreachable
    case badReply
}

/// One state-based provider call. Content-free: labels, confidences, counts and the configured price.
public struct JudgeDecision: Equatable, Sendable {
    public var verdicts: [JudgeVerdict]
    /// `fire` answers dropped for being under the confidence floor.
    public var belowFloor: Int
    /// Set when the call gave no answer (no cue then).
    public var failure: JudgeFailure?
    /// The reply's `usage` (0 when the reply had none or the call failed).
    public var inputTokens: Int
    public var outputTokens: Int
    /// The model the reply names (e.g. a resolved version of the configured alias).
    public var model: String?
    /// The configured price of a call, nil when none is configured.
    public var costUsd: Double?

    public init(verdicts: [JudgeVerdict] = [], belowFloor: Int = 0, failure: JudgeFailure? = nil,
                inputTokens: Int = 0, outputTokens: Int = 0, model: String? = nil, costUsd: Double? = nil) {
        self.verdicts = verdicts
        self.belowFloor = belowFloor
        self.failure = failure
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.model = model
        self.costUsd = costUsd
    }
}

public enum JudgeReply: Sendable {
    /// The GPT judge's one label, handled by the GPT layer's rules as before.
    case gpt(JudgeResult, JudgeUsage)
    /// A state-based provider's verdicts (already past its floor), or the failure that means no cue.
    case decided(JudgeDecision)
}

/// The judge behind the judged cues. The GPT layer gates when to call it (one in flight, the minimum
/// interval, the budget, never mid-monologue); the provider only answers.
public protocol JudgeProvider: Sendable {
    var kind: JudgeProviderKind { get }
    func judge(_ input: JudgeInput) async throws -> JudgeReply
}

/// The GPT judge as a provider: the prompt goes to the wrapped `CueJudge` untouched, and its result and
/// errors come back untouched.
public struct GptJudgeProvider: JudgeProvider {
    public let cueJudge: CueJudge

    public init(_ cueJudge: CueJudge) {
        self.cueJudge = cueJudge
    }

    public var kind: JudgeProviderKind { .gpt }

    public func judge(_ input: JudgeInput) async throws -> JudgeReply {
        let (result, usage) = try await cueJudge.judge(prompt: input.prompt)
        return .gpt(result, usage)
    }
}

public enum JudgeProviders {
    /// The production judge for `config.judge.provider`. nil when the TypeSafe provider is selected
    /// without a TypeSafe key: then nothing is judged, and transcription and the transcript rules keep
    /// running (there is no fallback to another provider).
    public static func make(config: ListenMoreConfig, openAIKey: APIKey, judgeKey: APIKey?, http: HTTPTransport,
                            scheduler: GptScheduler) -> JudgeProvider? {
        switch config.judge.provider {
        case .gpt:
            return GptJudgeProvider(LiveJudge(config: config, key: openAIKey, http: http))
        case .typesafe:
            guard let judgeKey else { return nil }
            return TypeSafeJudge(config: config.judge.typesafe, key: judgeKey, http: http, clock: scheduler)
        }
    }

    /// Whether `provider` can ask the self-pivot question. The GPT judge can; TypeSafe has no self_pivot
    /// question yet, so self-pivot is off while it is selected.
    public static func judgesSelfPivot(_ provider: JudgeProviderKind) -> Bool {
        switch provider {
        case .gpt: true
        case .typesafe: false
        }
    }

    /// The self-pivot judge, on the configured provider only: the GPT judge asks it on the OpenAI key. nil
    /// when that provider can't ask it (`judgesSelfPivot`): then self-pivot is off. Never another provider's.
    public static func selfPivotJudge(config: ListenMoreConfig, openAIKey: APIKey, http: HTTPTransport) -> CueJudge? {
        switch config.judge.provider {
        case .gpt: LiveJudge(config: config, key: openAIKey, http: http, spec: .selfPivot)
        case .typesafe: nil
        }
    }
}
