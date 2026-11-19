import Foundation

/// The feature-flag registry: one case per parked feature that ships switched off.
///
/// Adding a flag is three small edits and nothing else (see "Feature flags" in the README):
///   1. add a `case` below, with a one-line comment saying what it gates;
///   2. give it a default in `defaultValue` (always `false`: a flag lands OFF);
///   3. gate the behavior at ONE entry point with `FeatureFlags(defaults:).isEnabled(.yourFlag)`.
/// The raw value is the flag's id; its UserDefaults key is `flag.<id>`.
///
/// A flag is read the way the coach settings are, `defaults.bool(forKey:)` on the injected
/// `UserDefaults` (the app's own domain, `.standard`). Nothing writes it and there is no Settings
/// row; a missing key reads false. Because every flag defaults off, `defaultValue` is what the
/// registry documents and the tests pin, and the read agrees with it.
public enum FeatureFlag: String, CaseIterable, Sendable {
    /// Test-only placeholder so the registry has a case (the type, the default test and the all-off
    /// helper need one). Gates nothing. The first real flag must delete it.
    case testOnlyPlaceholder

    /// What the flag is when the key is absent. Every flag defaults OFF.
    public var defaultValue: Bool {
        switch self {
        case .testOnlyPlaceholder: return false
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

    /// Flags as stored in `defaults` (an absent key reads false, every flag's default).
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
            return defaults.bool(forKey: flag.defaultsKey)
        }
    }
}
