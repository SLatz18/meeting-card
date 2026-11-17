import Foundation

/// What a host's coach menu offers in each state, so there is always a visible way in: Enable while
/// off, Pause or Resume during a session (Pause while held by the call app's mute), Stop for this
/// call while pre-warmed or in a session, Start now while waiting.
/// The host maps items to its own copy and actions.
public enum CoachMenuItem: Equatable, Sendable {
    /// A disabled header line.
    case status(CoachMenuStatus)
    /// A disabled note: GPT cues are off because there is no usable key; local cues still run.
    case gptOff
    case enable
    case startNow
    /// Off for the rest of this call (`CoachSession.stopForThisCall`).
    case stopForCall
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
    /// Held while the call app reports the mic muted.
    case muted
}

public enum CoachMenu {
    /// - Parameter gptAvailable: a key is stored and OpenAI hasn't rejected it.
    public static func items(enabled: Bool, indicator: CoachIndicator, gptAvailable: Bool) -> [CoachMenuItem] {
        guard enabled else { return [.status(.off), .enable, .separator, .settings] }
        var out: [CoachMenuItem]
        switch indicator {
        case .hidden: out = [.status(.waiting), .startNow]
        case .on: out = [.status(.on), .stopForCall]
        case .listening: out = [.status(.listening), .pause, .stopForCall]
        case .paused: out = [.status(.paused), .resume, .stopForCall]
        case .muted: out = [.status(.muted), .pause, .stopForCall]
        }
        if !gptAvailable { out.insert(.gptOff, at: 1) }
        return out + [.turnOff, .separator, .settings]
    }
}
