import Foundation

/// The feature-flag registry: one case per parked feature that ships switched off.
///
/// Adding a flag is three small edits and nothing else (see "Feature flags" in the README):
///   1. add a `case` below, with a one-line comment saying what it gates;
///   2. give it a default in `defaultValue` (a flag lands OFF, so `false`);
///   3. gate the behavior at ONE entry point with `FeatureFlags(defaults:).isEnabled(.yourFlag)`.
///
/// The raw value is the flag's id; its UserDefaults key is `flag.<id>`.
///
/// A flag is read from the injected `UserDefaults` (the app's own domain, `.standard`): a stored boolean
/// (or a 0/1 number) wins, and anything else, a missing key or any other stored value (including the
/// string YES), reads the flag's `defaultValue`. Set it with `defaults write ... -bool`. Nothing writes
/// it and there is no Settings row.
public enum FeatureFlag: String, CaseIterable, Sendable {
    /// Ties the call coach to the call's own window instead of the call app's largest window (the glow's
    /// display, and Zoom staying in a meeting while its home window is in front). Off: the largest-window rule.
    case callWindowBinding

    /// Labels speakers in the Them stream using on-device diarization.
    case speakerId

    /// Gates saved voice profiles and their Settings controls; requires `speakerId`.
    case speakerProfiles

    /// What the flag is when the key is absent. A flag lands OFF.
    public var defaultValue: Bool {
        switch self {
        case .callWindowBinding, .speakerId, .speakerProfiles: return false
        }
    }

    /// The UserDefaults key, `flag.<id>`.
    public var defaultsKey: String { "flag.\(rawValue)" }
}

/// Reads flags. Create one where the gated code already holds its `UserDefaults` and ask it once, at
/// the single entry point of the behavior.
public struct FeatureFlags {
    private enum Source {
        case defaults(UserDefaults)
        case allOff
    }

    private let source: Source

    /// Flags as stored in `defaults` (an absent key reads the flag's `defaultValue`).
    public init(defaults: UserDefaults) { source = .defaults(defaults) }

    /// Every flag off, whatever is stored: the configuration that must behave exactly like main.
    /// Internal: reached only through `@testable` by tests; the app cannot name it.
    static var allOff: FeatureFlags { FeatureFlags(source: .allOff) }

    private init(source: Source) { self.source = source }

    public func isEnabled(_ flag: FeatureFlag) -> Bool {
        switch source {
        case .allOff:
            return false
        case .defaults(let defaults):
            return Self.read(defaults, key: flag.defaultsKey, defaultValue: flag.defaultValue)
        }
    }

    /// A stored boolean (or 0/1 number), else `defaultValue`. `bool(forKey:)` would read a missing key as
    /// false, and the string YES as true, so it could neither express a default-true flag nor ignore YES. Internal so a test can exercise a default-true key
    /// without a default-true flag in the registry.
    static func read(_ defaults: UserDefaults, key: String, defaultValue: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }
}

public enum CoachSpeakerRule {
    public static func diarization<T>(_ flags: FeatureFlags, make: () -> T) -> T? {
        flags.isEnabled(.speakerId) ? make() : nil
    }

    public static func profiles<T>(_ flags: FeatureFlags, diarizationAvailable: Bool, make: () -> T) -> T? {
        guard diarizationAvailable, flags.isEnabled(.speakerProfiles) else { return nil }
        return make()
    }
}
