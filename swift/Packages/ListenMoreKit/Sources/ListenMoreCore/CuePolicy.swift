import Foundation

/// Colour per cue type, ~3 s fade, 20 s cooldown per cue type, never any sound
/// (port of the reference engine's `cues.py`).
public enum CueType: String, CaseIterable, Equatable, Sendable {
    case interrupt
    case talkOver = "talk_over"
    case aggressive
    case notListening = "not_listening"
    case missedQuestion = "missed_question"
    case monologue
    case talkShare = "talk_share"

    /// GPT judge labels -> cue types. GPT "interrupting" shares the interrupt cooldown with the local detector.
    public init?(gptLabel: String) {
        switch gptLabel {
        case "interrupting": self = .interrupt
        case "aggressive": self = .aggressive
        case "not_listening": self = .notListening
        case "missed_question": self = .missedQuestion
        default: return nil
        }
    }
}

public enum CueSource: String, Equatable, Sendable {
    case local
    case gpt
}

public struct Cue: Equatable, Sendable {
    public var type: CueType
    public var color: CueColor
    /// Engine time (seconds) the glow starts.
    public var t: TimeInterval
    /// Engine time of the behaviour that caused it.
    public var onset: TimeInterval
    public var latencyMs: Int
    public var source: CueSource
    public var fadeS: Double
    public var confidence: Double?
}

public final class CuePolicy {
    public let cooldown: TimeInterval
    public let fade: Double
    public let minConfidence: Double
    private let colors: [String: CueColor]
    private var last: [CueType: TimeInterval] = [:]
    public private(set) var suppressed = 0
    public var paused = false

    public init(config: ListenMoreConfig.Cues) {
        cooldown = config.cooldownS
        fade = config.fadeS
        minConfidence = config.gptMinConfidence
        colors = config.colors
    }

    public func offer(_ type: CueType, t: TimeInterval, onset: TimeInterval, source: CueSource,
                      confidence: Double? = nil) -> Cue? {
        guard let color = colors[type.rawValue] else { return nil }
        if paused { return nil }
        if source == .gpt {
            guard let confidence, confidence >= minConfidence else { return nil }
        }
        if let prev = last[type], t - prev < cooldown {
            suppressed += 1
            return nil
        }
        last[type] = t
        return Cue(type: type, color: color, t: t, onset: onset,
                   latencyMs: Int(((t - onset) * 1000).rounded()), source: source, fadeS: fade, confidence: confidence)
    }

    /// Forget cooldowns, e.g. when a new call starts.
    public func reset() {
        last.removeAll()
        suppressed = 0
    }
}
