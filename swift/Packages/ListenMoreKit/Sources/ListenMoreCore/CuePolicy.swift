import Foundation

/// Swift mirror of `listen_more/cues.py`: colour per cue type, ~3 s fade, one cue at a time, never any
/// sound. A cue is held back when any cue showed in the last `global_cooldown_s` or the same type in
/// the last `cooldown_s`; candidates raised at the same moment are tried in `priority` order.
public enum CueType: String, CaseIterable, Equatable, Sendable {
    case interrupt
    case talkOver = "talk_over"
    case aggressive
    case notListening = "not_listening"
    case missedQuestion = "missed_question"
    case monologue
    case talkShare = "talk_share"

    /// GPT judge labels -> cue types. The judge only decides not_listening; every other cue is a
    /// local or transcript rule.
    public init?(gptLabel: String) {
        switch gptLabel {
        case "not_listening": self = .notListening
        default: return nil
        }
    }

    /// The cues a judge provider can decide. The GPT judge decides only not_listening; a TypeSafe
    /// System One judge is asked about each of these (the transcript rules keep raising aggressive and
    /// missed_question too; the policy's cooldowns keep it to one glow).
    public static let judged: [CueType] = [.aggressive, .notListening, .missedQuestion]

    /// The cues `provider` can decide.
    public static func decided(by provider: JudgeProviderKind) -> Set<CueType> {
        switch provider {
        case .gpt: [.notListening]
        case .typesafe: Set(judged)
        }
    }

    /// A judge label -> cue type, for the provider that produced it.
    public init?(judgeLabel: String, provider: JudgeProviderKind) {
        switch provider {
        case .gpt:
            self.init(gptLabel: judgeLabel)
        case .typesafe:
            guard let type = CueType(rawValue: judgeLabel), CueType.judged.contains(type) else { return nil }
            self = type
        }
    }
}

public enum CueSource: String, Equatable, Sendable {
    case local
    case text
    /// The judge, whichever provider (`judge.provider`) decided it.
    case gpt
}

/// Monologue and missed-question cues come in two strengths.
public enum CueLevel: String, Equatable, Sendable {
    case soft
    case strong
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
    public var level: CueLevel?

    /// Hosts can build cues for previews of their own renderer; live cues come from `CuePolicy`.
    public init(type: CueType, color: CueColor, t: TimeInterval, onset: TimeInterval, latencyMs: Int, source: CueSource,
                fadeS: Double, confidence: Double? = nil, level: CueLevel? = nil) {
        self.type = type
        self.color = color
        self.t = t
        self.onset = onset
        self.latencyMs = latencyMs
        self.source = source
        self.fadeS = fadeS
        self.confidence = confidence
        self.level = level
    }
}

public final class CuePolicy {
    public enum HoldReason: String, Equatable, Sendable {
        /// A closing phrase was heard recently.
        case closing
        /// Another cue showed within `global_cooldown_s`.
        case global
        /// The same type showed within `cooldown_s`.
        case type
    }

    /// A held cue: type, time and reason only.
    public struct Hold: Equatable, Sendable {
        public var type: CueType
        public var t: TimeInterval
        public var why: HoldReason
    }

    public let cooldown: TimeInterval
    public let globalCooldown: TimeInterval
    public let fade: Double
    public let minConfidence: Double
    private let colors: [String: CueColor]
    /// Never offered (`cues.disabled`).
    public let disabled: Set<CueType>
    private let rank: [CueType: Int]
    private var last: [CueType: TimeInterval] = [:]
    private var lastAny: TimeInterval?
    public private(set) var suppressed = 0
    public private(set) var held: [Hold] = []
    public var paused = false

    public init(config: ListenMoreConfig.Cues) {
        cooldown = config.cooldownS
        globalCooldown = config.globalCooldownS
        fade = config.fadeS
        minConfidence = config.gptMinConfidence
        colors = config.colors
        disabled = config.disabledTypes
        let order = config.priority.isEmpty ? CueType.allCases.map(\.rawValue) : config.priority
        var rank: [CueType: Int] = [:]
        for (i, raw) in order.enumerated() {
            if let type = CueType(rawValue: raw), rank[type] == nil { rank[type] = i }
        }
        self.rank = rank
    }

    public func offer(_ type: CueType, t: TimeInterval, onset: TimeInterval, source: CueSource,
                      confidence: Double? = nil, level: CueLevel? = nil, quiet: Bool = false) -> Cue? {
        guard !disabled.contains(type), let color = colors[type.rawValue] else { return nil }
        if paused { return nil }
        if source == .gpt {
            guard let confidence, confidence >= minConfidence else { return nil }
        }
        if quiet {
            hold(type, t, .closing)
            return nil
        }
        if let lastAny, t - lastAny < globalCooldown {
            hold(type, t, .global)
            return nil
        }
        if let prev = last[type], t - prev < cooldown {
            hold(type, t, .type)
            return nil
        }
        last[type] = t
        lastAny = t
        return Cue(type: type, color: color, t: t, onset: onset,
                   latencyMs: Int(((t - onset) * 1000).rounded(.toNearestOrEven)), source: source, fadeS: fade,
                   confidence: confidence, level: level)
    }

    /// Offers candidates raised at the same moment, highest priority first.
    public func offerMany(_ candidates: [CueSuggestion], quiet: Bool = false) -> [Cue] {
        let unranked = rank.count
        let ordered = candidates.enumerated().sorted {
            let a = rank[$0.element.type] ?? unranked, b = rank[$1.element.type] ?? unranked
            return a != b ? a < b : $0.offset < $1.offset
        }
        return ordered.compactMap { c in
            offer(c.element.type, t: c.element.t, onset: c.element.onset, source: c.element.source,
                  confidence: c.element.confidence, level: c.element.level, quiet: quiet)
        }
    }

    private func hold(_ type: CueType, _ t: TimeInterval, _ why: HoldReason) {
        suppressed += 1
        held.append(Hold(type: type, t: t, why: why))
    }

    /// Forget cooldowns, e.g. when a new call starts.
    public func reset() {
        last.removeAll()
        lastAny = nil
        suppressed = 0
        held.removeAll()
    }
}
