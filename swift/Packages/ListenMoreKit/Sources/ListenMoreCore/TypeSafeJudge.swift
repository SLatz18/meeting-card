import Foundation

/// The TypeSafe System One judge: POST `judge.typesafe.url` with `{model, state, questions}` (the
/// confirmed `SystemOne` format) and a Bearer key. The state is the minimal redacted window (`JudgeLine`s: speaker label, seconds ago,
/// text); each judged cue is a `choice` question whose criteria are `fire` and `no_fire`. A `fire`
/// answer at or above `min_confidence` is a verdict; anything under it, an HTTP error, a bad reply,
/// a transport error or no answer within `timeout_s` gives no cue. It never throws.
///
/// The key goes only into the Authorization header handed to the transport. Failures carry a status
/// code or a class; reply bodies are parsed for answers and usage only and never kept. Reflection
/// (`dump`, debuggers) shows the config only, never the key or the transport.
public final class TypeSafeJudge: JudgeProvider, Sendable, CustomReflectable {
    public let config: ListenMoreConfig.Judge.TypeSafe
    private let key: APIKey
    private let http: HTTPTransport
    private let clock: GptScheduler

    /// `clock` bounds each call at `timeout_s` (its sleep), on top of the transport's own timeout.
    public init(config: ListenMoreConfig.Judge.TypeSafe, key: APIKey, http: HTTPTransport, clock: GptScheduler) {
        self.config = config
        self.key = key
        self.http = http
        self.clock = clock
    }

    public var kind: JudgeProviderKind { .typesafe }

    public var customMirror: Mirror { Mirror(self, children: ["config": config]) }

    public func judge(_ input: JudgeInput) async throws -> JudgeReply {
        .decided(await decide(input.window))
    }

    func decide(_ window: [JudgeLine]) async -> JudgeDecision {
        guard let url = URL(string: config.url),
              let body = try? SystemOne.encode(SystemOne.request(config, window: window))
        else { return JudgeDecision(failure: .badResponse) }
        var d = JudgeDecision(costUsd: config.costUsdPerCall)
        do {
            let (status, data) = try await post(url, body)
            guard status == 200 else {
                d.failure = .http(status)
                return d
            }
            let parsed = try Self.parse(data, config: config)
            d.verdicts = parsed.verdicts
            d.belowFloor = parsed.belowFloor
            d.inputTokens = parsed.inputTokens
            d.outputTokens = parsed.outputTokens
            d.model = parsed.model
        } catch {
            d.failure = JudgeFailure.classify(error)
        }
        return d
    }

    /// The transport call raced against `timeout_s` on `clock`; whichever finishes first wins and the
    /// other is cancelled.
    private func post(_ url: URL, _ body: Data) async throws -> (status: Int, body: Data) {
        let headers = ["Authorization": "Bearer \(key.value)", "Content-Type": "application/json"]
        let http = http, clock = clock, timeout = config.timeoutS
        return try await withThrowingTaskGroup(of: (status: Int, body: Data)?.self) { group in
            group.addTask { try await http.post(url: url, headers: headers, body: body, timeout: timeout) }
            group.addTask {
                try await clock.sleep(seconds: timeout)
                return nil
            }
            defer { group.cancelAll() }
            guard let first = try await group.next(), let reply = first else { throw JudgeFailure.timeout }
            return reply
        }
    }

    struct Parsed: Equatable {
        var verdicts: [JudgeVerdict]
        var belowFloor: Int
        var inputTokens: Int
        var outputTokens: Int
        var model: String?
    }

    /// Answers are matched to the questions asked by id. A missing or unknown answer (another id,
    /// another type, any choice but `fire`) gives no cue; a `fire` without a confidence is under the floor.
    static func parse(_ data: Data, config: ListenMoreConfig.Judge.TypeSafe) throws -> Parsed {
        guard let reply = try? SystemOne.decode(data) else { throw JudgeFailure.badResponse }
        var out = Parsed(verdicts: [], belowFloor: 0, inputTokens: reply.usage?.inputTokens ?? 0,
                         outputTokens: reply.usage?.outputTokens ?? 0, model: reply.model)
        for (type, _) in config.questions.asked {
            guard let a = reply.answers[type.rawValue], a.fires else { continue }
            let confidence = a.confidence ?? 0
            if confidence >= config.minConfidence {
                out.verdicts.append(JudgeVerdict(label: type.rawValue, confidence: confidence))
            } else {
                out.belowFloor += 1
            }
        }
        return out
    }
}

/// Redaction for transcript text a state-based judge receives, on top of the coach's rules (RAM only,
/// never logged or stored): links (a meeting link can carry its passcode), email addresses, runs of
/// five or more digits (phone numbers, meeting IDs, passcodes, account numbers) and the host's
/// configured `text.user_names`. Speaker identities use anonymous stream labels or call-local numbers.
public enum JudgeRedactor {
    private static let rules: [(NSRegularExpression, String)] = [
        (#"(?i)[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}"#, "[email]"),
        (#"(?i)\b(?:https?://|www\.)\S+"#, "[link]"),
        (#"(?i)\b[a-z0-9-]+(?:\.[a-z0-9-]+)*\.[a-z]{2,}/\S*"#, "[link]"),
        (#"\+?\d(?:[ ().-]{0,2}\d){4,}"#, "[number]"),
    ].compactMap { pattern, token in (try? NSRegularExpression(pattern: pattern)).map { ($0, token) } }

    public static func redact(_ text: String, names: [String]) -> String {
        var s = text
        for (re, token) in rules {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: token)
        }
        return redactNames(s, names: names)
    }

    static func redactNames(_ text: String, names: [String]) -> String {
        var s = text
        for name in names {
            let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !n.isEmpty,
                  let re = try? NSRegularExpression(pattern: "(?<![\\p{L}\\p{N}])" + NSRegularExpression.escapedPattern(for: n) + "(?![\\p{L}\\p{N}])",
                                                    options: [.caseInsensitive]) else { continue }
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: "[name]")
        }
        return s
    }
}
