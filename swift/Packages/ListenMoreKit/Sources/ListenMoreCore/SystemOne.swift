import Foundation

/// The TypeSafe System One wire format, as confirmed by a real call.
///
/// Request: `{"model", "state", "questions"}`, where `questions` is an object keyed by question id and
/// each value is `{"type": "choice", "instructions", "criteria": {"fire", "no_fire"}}`.
/// Response: `{"model", "answers", "usage"}`, where `answers` is keyed by the same ids and a choice
/// answer is `{"type": "choice", "choice", "confidence", "probabilities"}`, and `usage` carries
/// `input_tokens` and `output_tokens`.
public enum SystemOne {
    public struct Request: Encodable, Equatable, Sendable {
        public var model: String
        public var state: State
        public var questions: [String: Question]
    }

    /// The minimal transcript window, oldest first.
    public struct State: Encodable, Equatable, Sendable {
        public var transcript: [Line]
    }

    public struct Line: Encodable, Equatable, Sendable {
        public var speaker: String
        /// Rounded to 0.1 s.
        public var secondsAgo: Double
        public var text: String

        enum CodingKeys: String, CodingKey {
            case speaker
            case secondsAgo = "seconds_ago"
            case text
        }
    }

    public struct Question: Encodable, Equatable, Sendable {
        public var type = "choice"
        public var instructions: String
        public var criteria: Criteria
    }

    public struct Criteria: Encodable, Equatable, Sendable {
        public var fire: String
        public var noFire: String

        enum CodingKeys: String, CodingKey {
            case fire
            case noFire = "no_fire"
        }
    }

    public struct Response: Decodable, Equatable, Sendable {
        public var model: String?
        public var answers: [String: Answer]
        public var usage: Usage?
    }

    /// Every field is optional and decoded leniently, so an answer of another type or shape decodes
    /// (and then gives no cue) instead of failing the whole reply.
    public struct Answer: Decodable, Equatable, Sendable {
        public var type: String?
        public var choice: String?
        public var confidence: Double?
        public var probabilities: [String: Double]?

        public init(type: String?, choice: String?, confidence: Double?, probabilities: [String: Double]?) {
            self.type = type
            self.choice = choice
            self.confidence = confidence
            self.probabilities = probabilities
        }

        enum CodingKeys: String, CodingKey {
            case type, choice, confidence, probabilities
        }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            type = try? c.decodeIfPresent(String.self, forKey: .type)
            choice = try? c.decodeIfPresent(String.self, forKey: .choice)
            confidence = try? c.decodeIfPresent(Double.self, forKey: .confidence)
            probabilities = try? c.decodeIfPresent([String: Double].self, forKey: .probabilities)
        }

        /// A `choice` answer that picked `fire`.
        public var fires: Bool { type == "choice" && choice == "fire" }
    }

    public struct Usage: Decodable, Equatable, Sendable {
        public var inputTokens: Int?
        public var outputTokens: Int?

        enum CodingKeys: String, CodingKey {
            case inputTokens = "input_tokens"
            case outputTokens = "output_tokens"
        }
    }

    /// The request for `window` with one choice question per judged cue in `config`.
    public static func request(_ config: ListenMoreConfig.Judge.TypeSafe, window: [JudgeLine]) -> Request {
        var questions: [String: Question] = [:]
        for (type, q) in config.questions.asked {
            questions[type.rawValue] = Question(instructions: config.context + " " + q.instructions,
                                                criteria: Criteria(fire: q.fire, noFire: q.noFire))
        }
        let lines = window.map {
            Line(speaker: $0.speaker.rawValue, secondsAgo: ($0.secondsAgo * 10).rounded() / 10, text: $0.text)
        }
        return Request(model: config.model, state: State(transcript: lines), questions: questions)
    }

    public static func encode(_ request: Request) throws -> Data {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try e.encode(request)
    }

    /// Throws when the body is not a System One reply (no `answers` object).
    public static func decode(_ data: Data) throws -> Response {
        try JSONDecoder().decode(Response.self, from: data)
    }
}
