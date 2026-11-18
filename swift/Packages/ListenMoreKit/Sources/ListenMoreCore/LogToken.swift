import Foundation

/// A short label that is safe to write to the coach diagnostics file. There is no public initializer
/// from a string: a token is made by a constructor named for what it holds, and each checks its input
/// against what that thing looks like.
///
/// - `bundleId`, `model`, `version`, `errorDomain`: must have the shape of one (a reverse-DNS ID, a model
///   name, a version number, a dotted domain); anything else becomes `invalid`. A sentence is not a bundle ID.
/// - `serverCode`: an error type or code from a server, reduced to `A-Z a-z 0-9 . _ : / -`.
/// - `device`: an audio device name, which is free text by nature, so spaces and punctuation become `_`.
/// - `route`, `micSource`: from the typed enums.
/// - `constant`: only a string literal (`StaticString`), so a variable cannot be passed.
///
/// Anything shaped like a key (`sk-` starting a token, a long unbroken run of letters and digits, the words
/// Bearer or Authorization) becomes `redacted` in every role. Names that merely contain "sk-" (a "Desk-Mic")
/// and long model names with separators are kept.
public struct LogToken: Equatable, Sendable, CustomStringConvertible {
    public static let maxLength = 64
    /// A run of this many letters and digits with no separator is not a name.
    static let longestRun = 32

    public let value: String
    public var description: String { value }

    private init(_ value: String) { self.value = value }

    // MARK: constructors

    public static func constant(_ literal: StaticString) -> LogToken { LogToken("\(literal)") }

    /// A reverse-DNS bundle identifier (`com.example.app`, lowercased or not).
    public static func bundleId(_ raw: String) -> LogToken {
        shaped(raw, pattern: #"^[A-Za-z0-9][A-Za-z0-9_-]*(\.[A-Za-z0-9_-]+)+$"#)
    }

    public static func bundleIdOrNil(_ raw: String?) -> LogToken? { raw.map { bundleId($0) } }

    /// A model name such as `gpt-live-transcribe` or one with a date suffix.
    public static func model(_ raw: String) -> LogToken {
        shaped(raw, pattern: #"^[A-Za-z0-9][A-Za-z0-9._:-]*$"#)
    }

    /// A version or build number (`2.0`, `15.1.0`, `47`).
    public static func version(_ raw: String?) -> LogToken? {
        guard let raw else { return nil }
        return shaped(raw, pattern: #"^[0-9A-Za-z][0-9A-Za-z.+-]*$"#)
    }

    /// An error domain (`NSOSStatusErrorDomain`, `com.apple.ScreenCaptureKit.SCStreamErrorDomain`).
    public static func errorDomain(_ raw: String) -> LogToken {
        shaped(raw, pattern: #"^[A-Za-z0-9][A-Za-z0-9._-]*$"#)
    }

    /// An error type and code a server sent, reduced to plain characters.
    public static func serverCode(_ raw: String) -> LogToken { sanitized(raw, allowing: ".:/_-") }

    /// An audio device name: free text by nature, so only plain characters survive.
    public static func device(_ raw: String) -> LogToken { sanitized(raw, allowing: ".:/_()+-") }

    public static func route(_ route: OutputRoute) -> LogToken { LogToken(route.rawValue) }
    public static func micSource(_ source: MicSourceKind) -> LogToken { LogToken(source.rawValue) }

    // MARK: checks

    /// Redacted if key-shaped, `invalid` if it doesn't have the shape, else the value (cut to `maxLength`).
    private static func shaped(_ raw: String, pattern: String) -> LogToken {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if isKeyShaped(trimmed) { return LogToken("redacted") }
        guard trimmed.range(of: pattern, options: .regularExpression) != nil else { return LogToken("invalid") }
        return LogToken(String(trimmed.prefix(maxLength)))
    }

    private static func sanitized(_ raw: String, allowing extra: String) -> LogToken {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if isKeyShaped(trimmed) { return LogToken("redacted") }
        var out = ""
        for scalar in trimmed.unicodeScalars {
            switch scalar {
            case "A"..."Z", "a"..."z", "0"..."9": out.unicodeScalars.append(scalar)
            default:
                if extra.unicodeScalars.contains(scalar) {
                    out.unicodeScalars.append(scalar)
                } else if !out.hasSuffix("_") {
                    out.append("_")
                }
            }
        }
        return LogToken(out.isEmpty ? "none" : String(out.prefix(maxLength)))
    }

    /// A key, a credential header, or a long unbroken run of letters and digits (a key without its prefix, an ID).
    static func isKeyShaped(_ s: String) -> Bool {
        if s.range(of: #"(^|[^A-Za-z0-9])sk-[A-Za-z0-9_-]{8,}"#, options: [.regularExpression, .caseInsensitive]) != nil { return true }
        if s.range(of: #"(?i)\b(bearer|authorization)\b"#, options: .regularExpression) != nil { return true }
        return s.range(of: "[A-Za-z0-9]{\(longestRun),}", options: .regularExpression) != nil
    }
}
