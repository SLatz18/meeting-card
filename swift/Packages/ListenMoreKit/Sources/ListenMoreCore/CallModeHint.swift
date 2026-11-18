import Foundation

/// "Headphones in call mode": a Bluetooth output that is doing two-way (hands-free) audio, which
/// lowers its quality and volume. Decided from Core Audio state alone (no permission), and only when
/// that state is readable and agrees: the output's own input stream is active and its sample rate
/// has dropped to a hands-free rate, while the coach isn't the one using its mic. Anything it can't
/// decide (an unreadable property, a headset whose mic is a separate device it can't attribute, an
/// active input at full rate) stays silent: no false tips. Which app chose that mic isn't knowable,
/// so the copy never says.
public enum CallModeHint {
    /// At or below this, a Bluetooth output is in its hands-free profile (high-quality playback runs
    /// at 44.1 or 48 kHz).
    public static let handsFreeMaxSampleRate: Double = 24000

    /// - Parameter outputInputStreamActive: nil when the output has no input streams of its own (its
    ///   mic, if any, is another device) or their state can't be read.
    public static func isCallMode(outputTransport: AudioDeviceInfo.Transport?, outputInputStreamActive: Bool?,
                                  outputSampleRate: Double?, outputDevice: UInt32?, ourMicDevice: UInt32?) -> Bool {
        guard outputTransport == .bluetooth, let output = outputDevice, ourMicDevice != output,
              let inputActive = outputInputStreamActive, let rate = outputSampleRate, rate > 0 else { return false }
        return inputActive && rate <= handsFreeMaxSampleRate
    }
}

/// "Mic-based cues are off": Bluetooth headphones on a Mac with no built-in mic, where the coach
/// opens no mic (it never opens a headset's) and runs on call audio only.
public enum NoMicNotice {
    /// The once-per-call status line, for the current plan.
    public static func showsStatus(route: OutputRoute?, micSource: MicSourceKind?, builtInMicPresent: Bool) -> Bool {
        route == .bluetooth && micSource == MicSourceKind.none && !builtInMicPresent
    }

    /// The Settings note: this Mac has no built-in mic.
    public static func showsSettingsNote(builtInMicPresent: Bool) -> Bool { !builtInMicPresent }
}

public typealias CallModeHintTracker = OncePerCallNotice

/// Shows a notice at most once per call: from the first poll that sees its condition during a
/// listening session until it's dismissed, the condition ends, or the call ends.
public struct OncePerCallNotice: Equatable, Sendable {
    public private(set) var visible = false
    private var call: Double?
    private var used = false

    public init() {}

    /// `call` identifies the session (its start time); nil without one.
    public mutating func update(call: Double?, callMode: Bool) {
        if call != self.call {
            self.call = call
            used = false
            visible = false
        }
        guard call != nil else { return }
        if visible {
            if !callMode { visible = false }
        } else if callMode && !used {
            visible = true
            used = true
        }
    }

    public mutating func dismiss() {
        visible = false
    }
}
