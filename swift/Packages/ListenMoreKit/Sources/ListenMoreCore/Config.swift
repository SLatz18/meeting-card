import Foundation

/// Coach config: the built-in generic defaults (`DefaultConfig.json`), optionally deep-merged with
/// host overrides. Keys mirror the Python reference engine's `config/default.json`; keys the Swift
/// side does not use are ignored. No secrets live here.
public struct ListenMoreConfig: Decodable, Equatable, Sendable {
    public struct Audio: Decodable, Equatable, Sendable {
        public var sampleRate: Int
        public var frameMs: Int
        public var vadRate: Int
        public var vadAggressiveness: Int
    }

    public struct Vad: Decodable, Equatable, Sendable {
        public var onsetFrames: Int
        public var onsetWindow: Int
        public var hangoverMs: Int
        public var minRmsDbfs: Double
    }

    public struct Local: Decodable, Equatable, Sendable {
        /// Cut-in: the overlap from the user's onset, how long the other side keeps going, the
        /// backchannel guard, the pause that ends the user's utterance, and the pause in their speech
        /// that still counts as mid-speech.
        public var cutInMinOverlapMs: Double
        public var cutInOthersContinueMs: Double
        public var cutInBackchannelMaxMs: Double
        public var cutInUtteranceGapMs: Double
        public var cutInOthersPauseMs: Double
        /// How long a cut-in waits for the other side's last words to be transcribed.
        public var cutInTextWaitMs: Double
        /// A question from the other side this recently makes the user's start an answer, not a cut-in.
        public var cutInQuestionLookbackS: Double
        /// No cut-in within this long after a talk-over.
        public var cutInAfterTalkOverS: Double
        /// Trailing cut-in: a shorter overlap, the other side stopping within the window of the user's
        /// start, and the floor left to the user this long.
        public var cutInTrailingMinOverlapMs: Double
        public var cutInTrailingWindowS: Double
        public var cutInTrailingYieldS: Double
        /// After the coach's Mute ends, the user's onsets this soon neither open a cut-in nor count as a
        /// talk-over switch: the host's echo canceller restarts with the mic and can let call audio
        /// through while it settles, which would read as the user talking over the other side.
        public var unmuteGraceS: Double
        public var talkOverSwitches: Int
        public var talkOverWindowS: Double
        public var talkOverMinOverlapMs: Double
        public var talkOverHoldFloorMs: Double
        public var talkOverReadbackMaxTurnS: Double
        public var monologueSoftS: Double
        public var monologueStrongS: Double
        /// Soft earlier when a run passes `factor` x the user's median run (and `min_s`), once
        /// `min_runs` runs of at least `min_run_s` are known.
        public var monologueRelativeFactor: Double
        public var monologueRelativeMinS: Double
        public var monologueRelativeMinRuns: Int
        public var monologueRelativeMinRunS: Double
        /// Both thresholds x this right after the other side asked how/why.
        public var monologueHowWhyRaise: Double
        public var monologueOthersFloorMs: Double
        public var monologueMeGapResetS: Double
        public var talkShareWindowS: Double
        public var talkShareMaxGroup: Double
        public var talkShareMaxOneOnOne: Double
        public var talkShareMinSpeechS: Double
        public var prosodyEnabled: Bool
        public var prosodyBaselineMinS: Double
        public var prosodyBaselineMaxS: Double
        public var prosodyLoudnessJumpDb: Double
        public var prosodyRateJumpPct: Double
    }

    /// Deterministic rules on the live transcript. Word lists match lower-case on word boundaries.
    public struct Text: Decodable, Equatable, Sendable {
        /// Names that make a group question the user's.
        public var userNames: [String]
        public var questionClearMinSharedWords: Int
        public var questionDecideWords: Int
        public var questionEscalateUserS: Double
        public var questionTimeoutUserTurns: Int
        public var questionOthersAnsweredS: Double
        public var questionTimeoutAfterOthersS: Double
        public var questionOpenInvites: [String]
        public var questionCheckInOpeners: [String]
        public var questionAboutHimOpeners: [String]
        public var questionOpenMinSharedWords: Int
        public var cutInTrailingWords: [String]
        public var updateHandoffPhrases: [String]
        public var updateHandoffLookbackS: Double
        public var updateMinParticipants: Int
        public var directAnswerOpeners: [String]
        public var howWhyWords: [String]
        public var howWhyLookbackS: Double
        public var heatWindowS: Double
        public var heatFireScore: Int
        public var heatSustainScore: Int
        public var heatRepeatWindowS: Double
        public var heatRepeatMinWords: Int
        public var heatRepeatOverlap: Double
        public var heatSpikeWords: Int
        public var heatSpikeWindowS: Double
        public var heatProsodyMinRisePct: Double
        public var heatSuppressFirstS: Double
        public var heatAbsolutes: [String]
        public var heatFrustration: [String]
        public var heatProfanity: [String]
        public var heatContradictionOpeners: [String]
        public var heatApology: [String]
        public var heatPersonal: [String]
        public var closingPhrases: [String]
        public var closingQuietS: Double
        /// Self-pivot gate (`PivotGate`, shadow counters only). Their turn shares something personal: at
        /// least `pivot_share_min_words`, a share marker, and a share word (a feeling, a life event or a
        /// personal topic; not `heat_personal`, whose small talk such as the weather isn't a share),
        /// with no invitation for the user to share and no question at its end. Across their lines, only
        /// sentences shorter than `pivot_share_min_words` may follow the share, and no `pivot_move_on`
        /// or `update_handoff_phrases` phrase from the share on: moving on to the agenda ends it.
        public var pivotShareMinWords: Int
        public var pivotShareMarkers: [String]
        public var pivotShareWords: [String]
        public var pivotMoveOn: [String]
        /// Phrases that hand the floor to the other person, anywhere in a turn (with `question_open_invites`):
        /// in their turn an invitation to share, in the user's reply a question back.
        public var pivotInvites: [String]
        /// An invitation the user answered with less than `pivot_reply_min_words` still holds for
        /// their turns ending within this long of it.
        public var pivotInviteHoldS: Double
        /// The user's reply starts within this long of their last speech, runs at least
        /// `pivot_reply_min_words`, and is about the user: first-person words are at least
        /// `pivot_first_person_share` of first-person plus `pivot_other_person` words, and a sentence
        /// opens with a pivot opener or there are at least `pivot_first_person_min_words` first-person
        /// words. A reply opening with a `pivot_sympathy` phrase is judged on the text after it, where
        /// `pivot_first_person_plural` ("we", "our", "us") counts as first person too when that text
        /// also has a singular first-person word or a share marker. A reply with a `pivot_help_offers`
        /// phrase (help, accommodation such as "no stress", or well-wishes such as "in my thoughts")
        /// is about them.
        public var pivotReplyMaxStartS: Double
        public var pivotReplyMinWords: Int
        public var pivotOpeners: [String]
        public var pivotFirstPerson: [String]
        public var pivotOtherPerson: [String]
        /// Reactions to their news ("that sounds", "love that"); each counts as one `pivot_other_person` word.
        public var pivotAboutThem: [String]
        public var pivotFirstPersonMinWords: Int
        /// With a pivot opener, this many first-person words are enough.
        public var pivotOpenerMinFirstPerson: Int
        public var pivotFirstPersonShare: Double
        public var pivotSympathy: [String]
        public var pivotFirstPersonPlural: [String]
        public var pivotHelpOffers: [String]
        /// A sentence or clause starting with one of these (after any lead-in word) asks a question.
        public var pivotQuestionOpeners: [String]
        /// A sentence ending with one of these words ("…, right", "…, you know") asks a question.
        public var pivotTagQuestions: [String]
        /// Words skipped at the start of a sentence or clause before an opener is matched ("oh nice,").
        public var pivotLeadIns: [String]
        /// The turn ends when they start talking or the user is quiet this long; the user's last
        /// transcript gets `pivot_transcript_wait_s` past the turn end to arrive.
        public var pivotTurnEndGapS: Double
        public var pivotTranscriptWaitS: Double
        /// No candidate within `pivot_rearm_s` of the last one, and at most `pivot_max_per_call` per call.
        public var pivotRearmS: Double
        public var pivotMaxPerCall: Int
        public var confirmWords: [String]
        public var numberWords: [String]
        public var stopwords: [String]
    }

    public struct Cues: Decodable, Equatable, Sendable {
        /// Per cue type.
        public var cooldownS: Double
        /// After any cue.
        public var globalCooldownS: Double
        /// Candidates raised at the same moment are tried in this order (cue type raw values).
        public var priority: [String]
        public var fadeS: Double
        public var gptMinConfidence: Double
        public var colors: [String: CueColor]
        /// Cue types that never show (cue type raw values): a host's choice, none in the generic config.
        public var disabled: [String]?

        public var disabledTypes: Set<CueType> { Set((disabled ?? []).compactMap(CueType.init(rawValue:))) }
    }

    public struct Gpt: Decodable, Equatable, Sendable {
        public struct Prices: Decodable, Equatable, Sendable {
            public var transcribePerMinute: Double
            public var judgeInputPerMtok: Double
            public var judgeCachedInputPerMtok: Double
            public var judgeOutputPerMtok: Double
        }

        public var realtimeUrl: String
        public var transcribeModel: String
        public var transcribeDelay: String?
        public var transcribePrerollMs: Int
        /// Utterances closer than this share one commit (each commit is billed rounded up to a second).
        public var transcribeCommitGapMs: Double
        /// A segment this long commits at its next pause.
        public var transcribeMaxSegmentS: Double
        public var responsesUrl: String
        public var judgeModel: String
        public var judgeReasoningEffort: String?
        public var judgeWindowS: Double
        public var judgeMinIntervalS: Double
        public var judgeTimeoutS: Double
        /// An OTHERS line needs this many words to make the user's next line worth judging.
        public var judgeMinOthersWords: Int
        /// No judge call while the user's run is at least this long.
        public var judgeSkipRunS: Double
        public var notListeningMinConfidence: Double
        /// Transient judge errors (429, 5xx, network) tolerated before the layer stops.
        public var judgeMaxTransientErrors: Int
        public var store: Bool
        public var pricesUsd: Prices
        public var budgetUsdPerCall: Double?
    }

    /// Which judge decides the judged cues (`CueType.judged`). `gpt` is the Responses judge above and
    /// the default; `typesafe` asks a TypeSafe System One endpoint. Transcription is OpenAI's either way.
    public struct Judge: Decodable, Equatable, Sendable {
        public struct TypeSafe: Decodable, Equatable, Sendable {
            /// One choice question: `fire` / `no_fire`, each described by its criteria text.
            public struct Question: Decodable, Equatable, Sendable {
                public var instructions: String
                public var fire: String
                public var noFire: String
            }

            /// One question per judged cue; null leaves that cue out of the request.
            public struct Questions: Decodable, Equatable, Sendable {
                public var aggressive: Question?
                public var notListening: Question?
                public var missedQuestion: Question?

                /// The questions asked, keyed by cue type, in `CueType.judged` order.
                public var asked: [(type: CueType, question: Question)] {
                    CueType.judged.compactMap { type in question(for: type).map { (type, $0) } }
                }

                public func question(for type: CueType) -> Question? {
                    switch type {
                    case .aggressive: aggressive
                    case .notListening: notListening
                    case .missedQuestion: missedQuestion
                    case .interrupt, .talkOver, .monologue, .talkShare: nil
                    }
                }
            }

            public var url: String
            public var model: String
            /// A `fire` answer below this confidence gives no cue.
            public var minConfidence: Double
            public var timeoutS: Double
            /// The state holds at most `max_lines` transcript lines from the last `window_s` seconds.
            public var windowS: Double
            public var maxLines: Int
            /// Failed calls in a row (HTTP error, timeout, transport, bad reply) before judging stops for
            /// the session; transcription and the transcript rules keep running.
            public var maxConsecutiveErrors: Int
            /// Price of one call in USD, counted toward the per-call budget. Null: no price is known,
            /// and the call is metered at nothing.
            public var costUsdPerCall: Double?
            /// Shared preamble for every question (what `transcript` and the speaker labels mean).
            public var context: String
            public var questions: Questions
        }

        public var provider: JudgeProviderKind
        public var typesafe: TypeSafe
    }

    /// Auto-on from Core Audio running state (`CoachTrigger`).
    public struct Trigger: Decodable, Equatable, Sendable {
        public var pollS: Double
        public var startAfterS: Double
        public var stopAfterS: Double
        /// Stop delay once an app-level call-state provider reports the call ended.
        public var endedStopAfterS: Double
        /// Never trigger on these, in any mode (the host adds its own bundle ID).
        public var excludeBundleIds: [String]
    }

    public var audio: Audio
    public var vad: Vad
    public var local: Local
    public var text: Text
    public var cues: Cues
    public var gpt: Gpt
    public var judge: Judge
    public var trigger: Trigger
    public var captureTargets: [CaptureTarget]
    public var meetTitleRegex: String

    public var frameS: Double { Double(audio.frameMs) / 1000 }
    public var frameSamples: Int { audio.sampleRate * audio.frameMs / 1000 }

    public static func decode(_ data: Data) throws -> ListenMoreConfig {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(ListenMoreConfig.self, from: data)
    }

    /// The built-in generic config, validated.
    public static func builtIn() throws -> ListenMoreConfig {
        try load(overrides: [:])
    }

    /// The built-in config deep-merged with an override file (nested objects merge, everything else
    /// replaces; same semantics as the Python `load_config`).
    public static func load(overrideURL: URL?) throws -> ListenMoreConfig {
        try load(overrides: overrideURL.map { try jsonObject(Data(contentsOf: $0)) } ?? [:])
    }

    /// The built-in config deep-merged with `overrides` (a host's tuning, already parsed).
    public static func load(overrides: [String: Any]) throws -> ListenMoreConfig {
        let config = try decode(JSONSerialization.data(withJSONObject: merged(overrides: overrides)))
        try config.validate()
        return config
    }

    /// The merged JSON object for sections the typed config does not model.
    public static func merged(overrides: [String: Any]) throws -> [String: Any] {
        deepMerge(try jsonObject(Data(DefaultConfig.json.utf8)), overrides)
    }

    public func validate() throws {
        guard captureTargets.contains(where: { $0.kind == .zoom }) else { throw ConfigError.invalid("no zoom capture target") }
        guard captureTargets.contains(where: { $0.kind == .browser }) else { throw ConfigError.invalid("no browser capture target") }
        for type in CueType.allCases where cues.colors[type.rawValue] == nil {
            throw ConfigError.invalid("no color for cue type \(type.rawValue)")
        }
        guard cues.priority.allSatisfy({ CueType(rawValue: $0) != nil }) else { throw ConfigError.invalid("unknown cue type in priority") }
        guard (cues.disabled ?? []).allSatisfy({ CueType(rawValue: $0) != nil }) else { throw ConfigError.invalid("unknown cue type in disabled") }
        guard (try? NSRegularExpression(pattern: meetTitleRegex)) != nil else { throw ConfigError.invalid("bad meet_title_regex") }
        guard (0...3).contains(audio.vadAggressiveness) else { throw ConfigError.invalid("vad_aggressiveness out of range") }
        let hop = audio.vadRate * audio.frameMs / 1000
        guard WebRTCVad.isValid(sampleRate: audio.vadRate, frameLength: hop) else {
            throw ConfigError.invalid("vad_rate/frame_ms not accepted by WebRTC VAD")
        }
        guard audio.sampleRate * audio.frameMs % 1000 == 0 else { throw ConfigError.invalid("frame_ms must divide sample_rate") }
        guard gpt.store == false else { throw ConfigError.invalid("gpt.store must be false") }
        try judge.typesafe.validate()
        guard text.pivotShareMinWords > 0, text.pivotReplyMinWords > 0, text.pivotReplyMaxStartS >= 0,
              text.pivotFirstPersonMinWords > 0, text.pivotOpenerMinFirstPerson > 0, (0...1).contains(text.pivotFirstPersonShare),
              text.pivotTurnEndGapS > 0, text.pivotTranscriptWaitS >= 0, text.pivotRearmS >= 0, text.pivotInviteHoldS >= 0,
              text.pivotMaxPerCall >= 0 else { throw ConfigError.invalid("bad text.pivot limits") }
        guard trigger.startAfterS >= 0, trigger.stopAfterS > 0, trigger.pollS > 0,
              trigger.endedStopAfterS > 0, trigger.endedStopAfterS <= trigger.stopAfterS else { throw ConfigError.invalid("bad trigger timing") }
    }

    public static func jsonObject(_ data: Data) throws -> [String: Any] {
        guard let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ConfigError.invalid("top level is not an object")
        }
        return dict
    }

    public static func deepMerge(_ base: [String: Any], _ over: [String: Any]) -> [String: Any] {
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

    /// Case name only. The associated string can quote a path or a JSON snippet, so it is never printed.
    public var publicName: String {
        switch self {
        case .invalid: "invalid"
        }
    }
}

extension ListenMoreConfig {
    /// Log line for a failed config load: the error's type, never its payload. `ConfigError`
    /// contributes its case name; anything else its Swift type name (`NSError`'s description
    /// includes the file path).
    public static func loadFailureMessage(_ error: Error) -> String {
        let name = (error as? ConfigError)?.publicName ?? String(describing: type(of: error))
        return "ListenMoreKit: could not load the coach config (\(name))"
    }
}

extension ListenMoreConfig.Judge.TypeSafe {
    /// Checked whichever provider is selected, so switching to it never meets a bad section.
    public func validate() throws {
        guard let u = URL(string: url), u.scheme == "https", u.host?.isEmpty == false else {
            throw ConfigError.invalid("judge.typesafe.url must be an https URL")
        }
        guard !model.isEmpty else { throw ConfigError.invalid("judge.typesafe.model is empty") }
        guard (0...1).contains(minConfidence) else { throw ConfigError.invalid("judge.typesafe.min_confidence out of range") }
        guard timeoutS > 0, windowS > 0, maxLines > 0, maxConsecutiveErrors > 0 else {
            throw ConfigError.invalid("bad judge.typesafe limits")
        }
        guard (costUsdPerCall ?? 0) >= 0 else { throw ConfigError.invalid("judge.typesafe.cost_usd_per_call is negative") }
        guard !questions.asked.isEmpty else { throw ConfigError.invalid("judge.typesafe asks no questions") }
    }
}

public enum CueColor: String, Decodable, Equatable, Sendable {
    case red
    case amber
}

public struct CaptureTarget: Decodable, Equatable, Sendable {
    /// zoom: Zoom desktop. native: any other desktop call app (Teams, Webex, FaceTime, Slack).
    /// browser: a Chromium browser. Window-title detection uses `meeting_title_patterns` for zoom and
    /// native targets and the Meet title rule for browsers; the Core Audio trigger needs neither.
    public enum Kind: String, Decodable, Equatable, Sendable {
        case zoom
        case native
        case browser
    }

    public var name: String
    public var kind: Kind
    public var processName: String
    public var bundleId: String
    public var bundleIdStatus: String?
    public var meetingTitlePatterns: [String]?
    /// Other processes that render this app's call audio (e.g. FaceTime plays calls through avconferenced).
    public var audioBundleIds: [String]?

    public init(name: String, kind: Kind, processName: String, bundleId: String,
                bundleIdStatus: String? = nil, meetingTitlePatterns: [String]? = nil, audioBundleIds: [String]? = nil) {
        self.name = name
        self.kind = kind
        self.processName = processName
        self.bundleId = bundleId
        self.bundleIdStatus = bundleIdStatus
        self.meetingTitlePatterns = meetingTitlePatterns
        self.audioBundleIds = audioBundleIds
    }

    /// Bundle IDs whose audio belongs to this target: the app itself plus `audio_bundle_ids`.
    public var ownedBundleIds: [String] {
        [bundleId] + (audioBundleIds ?? [])
    }
}
