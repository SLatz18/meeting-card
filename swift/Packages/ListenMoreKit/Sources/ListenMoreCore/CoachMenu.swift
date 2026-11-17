import Foundation

/// What a host's coach menu offers in each state, controls first: one Start/Stop toggle (Start while
/// the coach is off or waiting for a call, Stop while it's pre-warmed or in a session), then Pause or
/// Resume and Mute or Unmute (the coach's own, mic only) during a session; then the status lines;
/// then Settings, always last here. Switching the coach off is a Settings choice, not a menu item.
/// The host maps items to its own copy and actions.
public enum CoachMenuItem: Equatable, Sendable {
    /// A disabled header line.
    case status(CoachMenuStatus)
    /// A disabled note: GPT cues are off because there is no usable key; local cues still run.
    case gptOff
    /// While off: switch the coach on. While waiting for a call: start listening now (`CoachSession.startManual`).
    case startCoach
    /// Off for the rest of this call (`CoachSession.stopForThisCall`); the next call starts normally.
    case stopCoach
    case pause
    case resume
    /// The coach stops listening to the user's mic (`CoachSession.setMicMuted(true)`); never the call app's mute.
    case muteMic
    /// The coach listens to the user's mic again.
    case unmuteMic
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
    /// Listening to the call with the user's mic off (the coach's own Mute).
    case micOff
}

public enum CoachMenu {
    /// - Parameters:
    ///   - gptAvailable: a key is stored and OpenAI hasn't rejected it.
    ///   - micMuted: the coach's own Mute is on (`CoachSession.micMuted`); it stays on through Pause
    ///     and the call app's mute, so those states offer Unmute too.
    public static func items(enabled: Bool, indicator: CoachIndicator, gptAvailable: Bool, micMuted: Bool = false) -> [CoachMenuItem] {
        guard enabled else { return [.startCoach, .separator, .status(.off), .separator, .settings] }
        let mic: CoachMenuItem = micMuted || indicator == .micOff ? .unmuteMic : .muteMic
        func layout(_ controls: [CoachMenuItem], _ status: CoachMenuStatus) -> [CoachMenuItem] {
            controls + [.separator, .status(status)] + (gptAvailable ? [] : [.gptOff]) + [.separator, .settings]
        }
        switch indicator {
        case .hidden: return layout([.startCoach], .waiting)
        case .on: return layout([.stopCoach], .on)
        case .listening: return layout([.stopCoach, .pause, mic], .listening)
        case .micOff: return layout([.stopCoach, .pause, mic], .micOff)
        case .paused: return layout([.stopCoach, .resume, mic], .paused)
        case .muted: return layout([.stopCoach, .pause, mic], .muted)
        }
    }
}
