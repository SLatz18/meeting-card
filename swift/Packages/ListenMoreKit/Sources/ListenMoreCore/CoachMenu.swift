import Foundation

/// What a host's coach menu offers in each state, so there is always a visible way in: Enable while
/// off, Skip this call while pre-warmed, Pause or Resume during a session, Start now while waiting.
/// The host maps items to its own copy and actions.
public enum CoachMenuItem: Equatable, Sendable {
    /// A disabled header line.
    case status(CoachMenuStatus)
    /// A disabled note: GPT cues are off because there is no usable key; local cues still run.
    case gptOff
    case enable
    case startNow
    case skipThisCall
    case pause
    case resume
    case turnOff
    case separator
    case settings
}

public enum CoachMenuStatus: Equatable, Sendable {
    case off
    /// Enabled, no call yet.
    case waiting
    case on
    case listening
    case paused
}

public enum CoachMenu {
    /// - Parameter gptAvailable: a key is stored and OpenAI hasn't rejected it.
    public static func items(enabled: Bool, indicator: CoachIndicator, gptAvailable: Bool) -> [CoachMenuItem] {
        guard enabled else { return [.status(.off), .enable, .separator, .settings] }
        var out: [CoachMenuItem]
        switch indicator {
        case .hidden: out = [.status(.waiting), .startNow]
        case .on: out = [.status(.on), .skipThisCall]
        case .listening: out = [.status(.listening), .pause]
        case .paused: out = [.status(.paused), .resume]
        }
        if !gptAvailable { out.insert(.gptOff, at: 1) }
        return out + [.turnOff, .separator, .settings]
    }
}
