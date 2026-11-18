import Foundation

/// How the coach's mic is processed on a given macOS. Apple voice processing cancels call audio
/// from the speakers out of the user's stream, but while it runs macOS ducks all other audio, call
/// audio and music included. From macOS 14 that ducking can be set to its minimum with advanced
/// (voice-activity) ducking off; it never goes to zero. Before 14 it can't be lowered, so the mic runs
/// without voice processing there. The Kit targets macOS 14 and MeetingCard macOS 15, so that branch
/// is unreachable in shipped builds.
public struct MicProcessing: Equatable, Sendable {
    /// Raw values match `AVAudioVoiceProcessingOtherAudioDuckingConfiguration.Level`.
    public enum DuckingLevel: Int, Equatable, Sendable {
        case `default` = 0
        case min = 10
        case mid = 20
        case max = 30
    }

    public struct Ducking: Equatable, Sendable {
        public var advanced: Bool
        public var level: DuckingLevel

        public init(advanced: Bool, level: DuckingLevel) {
            self.advanced = advanced
            self.level = level
        }
    }

    public var voiceProcessing: Bool
    /// Other-audio ducking set with voice processing; nil without voice processing.
    public var ducking: Ducking?

    public init(voiceProcessing: Bool, ducking: Ducking?) {
        self.voiceProcessing = voiceProcessing
        self.ducking = ducking
    }

    public static let minimumDucking = Ducking(advanced: false, level: .min)

    public static func plan(macOS version: OperatingSystemVersion) -> MicProcessing {
        guard version.majorVersion >= 14 else { return MicProcessing(voiceProcessing: false, ducking: nil) }
        return MicProcessing(voiceProcessing: true, ducking: minimumDucking)
    }
}
