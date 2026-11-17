import Foundation

/// Which side of the call a buffer came from. Two streams give speaker attribution for free.
public enum AudioStream: String, Equatable, Sendable {
    /// Microphone (voice-processed, echo-cancelled) = me.
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

/// A cue proposed by the engine (local layer or GPT judge). The shell passes it through `CuePolicy`
/// before anything glows, so cooldown and confidence rules live in one place.
public struct CueSuggestion: Equatable, Sendable {
    public var type: CueType
    public var t: TimeInterval
    public var onset: TimeInterval
    public var source: CueSource
    public var confidence: Double?

    public init(type: CueType, t: TimeInterval, onset: TimeInterval, source: CueSource, confidence: Double? = nil) {
        self.type = type
        self.t = t
        self.onset = onset
        self.source = source
        self.confidence = confidence
    }
}

public protocol CoachEngineDelegate: AnyObject {
    func engine(_ engine: CoachEngine, didSuggest cue: CueSuggestion)
    /// The GPT layer turned itself off for the rest of the session; the local layer keeps running.
    func engine(_ engine: CoachEngine, gptDisabled reason: GptErrorKind)
}

/// Boundary between the Mac shell and the coaching engine. Implementations keep audio and text in
/// memory only and never log content.
public protocol CoachEngine: AnyObject {
    var delegate: CoachEngineDelegate? { get set }
    var isRunning: Bool { get }

    /// `apiKey` is nil when no key is stored; the engine then runs the local layer only.
    func start(config: ListenMoreConfig, apiKey: APIKey?)
    /// Mono Float32 PCM at `config.audio.sampleRate`.
    func ingest(_ stream: AudioStream, samples: [Float])
    func stop()
}
