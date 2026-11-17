import Foundation

/// Which side of the call a buffer came from. Two streams give speaker attribution for free.
public enum AudioStream: String, Equatable, Sendable {
    /// Microphone (voice-processed, echo-cancelled) = me (the user).
    case mic
    /// Call output from ScreenCaptureKit / process tap = everyone else.
    case call
}

/// The OpenAI key, held only in memory. `description` and `debugDescription` are redacted so the
/// key cannot leak through string interpolation, `print`, or logging.
public struct APIKey: Sendable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public let value: String

    public init?(_ value: String) {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        self.value = trimmed
    }

    public var description: String { "APIKey(<redacted>)" }
    public var debugDescription: String { description }
    public var customMirror: Mirror { Mirror(self, children: []) }
}

/// A cue candidate: from the local layer, the transcript rules or the GPT judge. The engine's pipeline
/// offers candidates to `CuePolicy`; the session re-offers what comes out to its own policy, which
/// adds the pause gate.
public struct CueSuggestion: Equatable, Sendable {
    public var type: CueType
    public var t: TimeInterval
    public var onset: TimeInterval
    public var source: CueSource
    public var confidence: Double?
    public var level: CueLevel?

    public init(type: CueType, t: TimeInterval, onset: TimeInterval, source: CueSource, confidence: Double? = nil,
                level: CueLevel? = nil) {
        self.type = type
        self.t = t
        self.onset = onset
        self.source = source
        self.confidence = confidence
        self.level = level
    }
}

/// Why the GPT layer turned itself off for the rest of a session (the local layer keeps running).
public enum GptStopReason: String, Equatable, Sendable {
    /// A transport or API error (never retried within the session).
    case error
    /// The per-call budget is spent.
    case budgetCap
}

public protocol CoachEngineDelegate: AnyObject {
    func engine(_ engine: CoachEngine, didSuggest cue: CueSuggestion)
    func engine(_ engine: CoachEngine, gptStopped reason: GptStopReason)
    /// Judging stopped for the session after repeated provider failures; `failure` is the one that
    /// stopped it (a status code or a class, never content or a key).
    func engine(_ engine: CoachEngine, judgeStopped failure: JudgeFailure)
    /// Live transcription text (content: RAM only, never logged).
    func engine(_ engine: CoachEngine, caption: CaptionEvent)
    func engine(_ engine: CoachEngine, meter: CostReading)
}

public extension CoachEngineDelegate {
    func engine(_ engine: CoachEngine, gptStopped reason: GptStopReason) {}
    func engine(_ engine: CoachEngine, judgeStopped failure: JudgeFailure) {}
    func engine(_ engine: CoachEngine, caption: CaptionEvent) {}
    func engine(_ engine: CoachEngine, meter: CostReading) {}
}

/// Boundary between the host and the coaching engine (`LocalCoachEngine`; the Python core in
/// listen-more is the reference). Implementations keep audio and text in memory only and never log content.
public protocol CoachEngine: AnyObject {
    var delegate: CoachEngineDelegate? { get set }
    var isRunning: Bool { get }

    /// `apiKey` is nil when no key is stored; the engine then runs the local layer only.
    func start(config: ListenMoreConfig, apiKey: APIKey?)
    /// Mono Float32 PCM at `config.audio.sampleRate`. `time` is seconds since `start`.
    func ingest(_ stream: AudioStream, samples: [Float], time: TimeInterval)
    /// The user's mic went off (true) or came back (false) within the session. While off, mic
    /// samples are dropped and nothing that reads the user's speech may fire from the gap or right
    /// after it. `start` begins with the mic on.
    func setMicMuted(_ muted: Bool)
    func stop()
}

/// Placeholder engine: accepts audio, counts frames, never suggests a cue.
public final class StubCoachEngine: CoachEngine {
    public weak var delegate: CoachEngineDelegate?
    public private(set) var isRunning = false
    public private(set) var hasKey = false
    public private(set) var samplesIngested: [AudioStream: Int] = [:]
    public private(set) var micMuted = false

    public init() {}

    public func start(config: ListenMoreConfig, apiKey: APIKey?) {
        isRunning = true
        hasKey = apiKey != nil
        samplesIngested = [:]
        micMuted = false
    }

    public func ingest(_ stream: AudioStream, samples: [Float], time: TimeInterval) {
        guard isRunning, !(stream == .mic && micMuted) else { return }
        samplesIngested[stream, default: 0] += samples.count
    }

    public func setMicMuted(_ muted: Bool) {
        micMuted = muted
    }

    public func stop() {
        isRunning = false
    }
}
