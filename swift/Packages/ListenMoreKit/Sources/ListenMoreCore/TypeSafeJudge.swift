import Foundation

/// The TypeSafe System One judge: POST `judge.typesafe.url` with `{model, state, questions}` and a
/// Bearer key. The state is the minimal redacted window (`JudgeLine`s: speaker label, seconds ago,
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

    public static func requestBody(_ c: ListenMoreConfig.Judge.TypeSafe, window: [JudgeLine]) -> [String: Any] {
        ["model": c.model, "state": state(window), "questions": questions(c)]
    }

    static func state(_ window: [JudgeLine]) -> [String: Any] {
        ["transcript": window.map { line -> [String: Any] in
            ["speaker": line.speaker.rawValue, "seconds_ago": (line.secondsAgo * 10).rounded() / 10, "text": line.text]
        }]
    }

    static func questions(_ c: ListenMoreConfig.Judge.TypeSafe) -> [String: Any] {
        var out: [String: Any] = [:]
        for (type, q) in c.questions.asked {
            out[type.rawValue] = [
                "type": "choice",
                "instructions": c.context + " " + q.instructions,
                "criteria": ["fire": q.fire, "no_fire": q.noFire],
            ] as [String: Any]
        }
        return out
    }

    public func judge(_ input: JudgeInput) async throws -> JudgeReply {
        .decided(await decide(input.window))
    }

    func decide(_ window: [JudgeLine]) async -> JudgeDecision {
        guard let url = URL(string: config.url),
              let body = try? JSONSerialization.data(withJSONObject: Self.requestBody(config, window: window), options: [.sortedKeys])
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
    }

    /// `answers` keyed by question id; only the questions asked count. A missing answer, a `no_fire`
    /// choice or a missing confidence gives no cue.
    static func parse(_ data: Data, config: ListenMoreConfig.Judge.TypeSafe) throws -> Parsed {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let answers = root["answers"] as? [String: Any] else { throw JudgeFailure.badResponse }
        var out = Parsed(verdicts: [], belowFloor: 0, inputTokens: 0, outputTokens: 0)
        for (type, _) in config.questions.asked {
            guard let a = answers[type.rawValue] as? [String: Any], a["choice"] as? String == "fire" else { continue }
            let confidence = (a["confidence"] as? NSNumber)?.doubleValue ?? 0
            if confidence >= config.minConfidence {
                out.verdicts.append(JudgeVerdict(label: type.rawValue, confidence: confidence))
            } else {
                out.belowFloor += 1
            }
        }
        let usage = root["usage"] as? [String: Any] ?? [:]
        out.inputTokens = (usage["input_tokens"] as? NSNumber)?.intValue ?? 0
        out.outputTokens = (usage["output_tokens"] as? NSNumber)?.intValue ?? 0
        return out
    }
}

/// Redaction for transcript text a state-based judge receives, on top of the coach's rules (RAM only,
/// never logged or stored): links (a meeting link can carry its passcode), email addresses, runs of
/// five or more digits (phone numbers, meeting IDs, passcodes, account numbers) and the host's
/// configured `text.user_names`. Speakers are only ever ME and OTHERS.
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
