import Foundation

/// Coach config (`DefaultConfig.json`, optionally deep-merged with an override file). Keys mirror the
/// Python reference engine's `config/default.json`. No secrets live here.
public struct ListenMoreConfig: Decodable, Equatable, Sendable {
    public struct Audio: Decodable, Equatable, Sendable {
        public var sampleRate: Int
        public var frameMs: Int
    }

    public struct Vad: Decodable, Equatable, Sendable {
        public var onsetFrames: Int
        public var onsetWindow: Int
        public var hangoverMs: Int
        public var minRmsDbfs: Double
        /// Normalized autocorrelation peak a frame needs to count as voiced (Swift VAD, see `StreamVAD`).
        public var voicingThreshold: Double
        public var voicingMinHz: Double
        public var voicingMaxHz: Double
    }

    public struct Local: Decodable, Equatable, Sendable {
        public var interruptConfirmMs: Double
        public var interruptOthersMinActiveMs: Double
        public var talkOverMs: Double
        public var monologueS: Double
        public var monologueOthersFloorMs: Double
        public var monologueMeGapResetS: Double
        public var talkShareWindowS: Double
        public var talkShareMax: Double
        public var talkShareMinSpeechS: Double
        public var prosodyBaselineMinS: Double
        public var prosodyBaselineMaxS: Double
        public var prosodyLoudnessJumpDb: Double
        public var prosodyRateJumpPct: Double
    }

    public struct Cues: Decodable, Equatable, Sendable {
        public var cooldownS: Double
        public var fadeS: Double
        public var gptMinConfidence: Double
        public var colors: [String: CueColor]
    }

    public struct Prices: Decodable, Equatable, Sendable {
        public var transcribePerMinute: Double
        public var judgeInputPerMtok: Double
        public var judgeCachedInputPerMtok: Double
        public var judgeOutputPerMtok: Double
    }

    public struct Gpt: Decodable, Equatable, Sendable {
        public var realtimeUrl: String
        public var transcribeModel: String
        public var transcribeDelay: String?
        public var transcribePrerollMs: Double
        public var responsesUrl: String
        /// A model alias (not a pinned snapshot), so the judge follows the latest version of that model.
        public var judgeModel: String
        public var judgeReasoningEffort: String?
        public var judgeWindowS: Double
        public var judgeMinIntervalS: Double
        public var judgeTimeoutS: Double
        public var questionWaitS: Double
        public var store: Bool
        public var pricesUsd: Prices
        public var budgetUsdPerCall: Double
    }

    public struct Trigger: Decodable, Equatable, Sendable {
        public var pollS: Double
        public var startAfterS: Double
        public var stopAfterS: Double
        public var excludeBundleIds: [String]
    }

    public var audio: Audio
    public var vad: Vad
    public var local: Local
    public var cues: Cues
    public var gpt: Gpt
    public var trigger: Trigger
    public var captureTargets: [CaptureTarget]

    public var frameS: Double { Double(audio.frameMs) / 1000 }
    public var frameSamples: Int { audio.sampleRate * audio.frameMs / 1000 }

    public static func decode(_ data: Data) throws -> ListenMoreConfig {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ListenMoreConfig.self, from: data)
    }

    /// The built-in config, validated.
    public static func builtIn() throws -> ListenMoreConfig {
        try load(overrideURL: nil)
    }

    /// The built-in config deep-merged with an optional override file (nested objects merge,
    /// everything else replaces; same semantics as the Python `load_config`).
    public static func load(overrideURL: URL?) throws -> ListenMoreConfig {
        var dict = try jsonObject(Data(DefaultConfig.json.utf8))
        if let overrideURL {
            dict = deepMerge(dict, try jsonObject(Data(contentsOf: overrideURL)))
        }
        let config = try decode(JSONSerialization.data(withJSONObject: dict))
        try config.validate()
        return config
    }

    public func validate() throws {
        guard captureTargets.contains(where: { $0.kind == .zoom }) else { throw ConfigError.invalid("no zoom capture target") }
        guard captureTargets.contains(where: { $0.kind == .browser }) else { throw ConfigError.invalid("no browser capture target") }
        for type in CueType.allCases where cues.colors[type.rawValue] == nil {
            throw ConfigError.invalid("no color for cue type \(type.rawValue)")
        }
        guard !gpt.store else { throw ConfigError.invalid("gpt.store must be false") }
        guard audio.frameMs > 0, audio.sampleRate % 1000 == 0 else { throw ConfigError.invalid("bad audio rate/frame") }
        guard trigger.startAfterS > 0, trigger.stopAfterS > 0, trigger.pollS > 0 else { throw ConfigError.invalid("bad trigger timing") }
    }

    static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigError.invalid("top level is not an object")
        }
        return dict
    }

    static func deepMerge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
        var out = base
        for (key, value) in over {
            if let sub = value as? [String: Any], let baseSub = out[key] as? [String: Any] {
                out[key] = deepMerge(baseSub, sub)
            } else {
                out[key] = value
            }
        }
        return out
    }
}

public enum ConfigError: Error, Equatable {
    case invalid(String)
}

public enum CueColor: String, Decodable, Equatable, Sendable {
    case red
    case amber
}

public struct CaptureTarget: Decodable, Equatable, Sendable {
    public enum Kind: String, Decodable, Equatable, Sendable {
        case zoom
        case browser
        case app
    }

    public var name: String
    public var kind: Kind
    public var processName: String
    public var bundleId: String
    public var bundleIdStatus: String?

    public init(name: String, kind: Kind, processName: String, bundleId: String, bundleIdStatus: String? = nil) {
        self.name = name
        self.kind = kind
        self.processName = processName
        self.bundleId = bundleId
        self.bundleIdStatus = bundleIdStatus
    }
}
