import Foundation

/// What a host's key field shows: whether a key is stored, never the key. Pure, so the rule that
/// decides when the field is redrawn is tested without a window.
public enum KeyPlaceholder: Equatable, Sendable {
    /// Nothing stored: the field's hint for what to enter.
    case empty
    /// A key is stored: the field says so instead of looking blank.
    case saved

    public static func of(hasKey: Bool) -> KeyPlaceholder { hasKey ? .saved : .empty }

    /// The placeholder to set now, or nil when what is shown already matches the Keychain. A host
    /// calls this on every refresh (after a save, after a delete, whenever its window is shown), so
    /// the field cannot go stale; `shown` nil (never drawn) always yields one.
    public static func refresh(shown: KeyPlaceholder?, hasKey: Bool) -> KeyPlaceholder? {
        let wanted = of(hasKey: hasKey)
        return shown == wanted ? nil : wanted
    }
}

/// The line under the key field after a save or delete, beside the error lines for a rejected key.
public enum KeyNotice: Equatable, Sendable {
    /// The key is stored and the coach will use it (now, or as soon as capture next starts).
    case saved
    /// The key is stored, but this call's GPT layer was started without it: used from the next call.
    case savedForNextCall
    /// The key is removed and nothing is running on it.
    case removed
    /// The key is removed, but this call's GPT layer already holds it and keeps it until the call ends.
    case removedAfterThisCall

    /// The notice for the result of a key action, or nil when nothing changed (a rejected key is not
    /// saved, and its error line is the message). `callCapturing`: capture is running right now.
    /// The key is read only when capture starts (`CoachSession.startCapture`) and handed to the
    /// engine for that call, so while capture runs a change cannot reach it.
    public static func after(_ check: KeyCheck, callCapturing: Bool) -> KeyNotice? {
        switch check {
        case .rejected: nil
        case .empty: callCapturing ? .removedAfterThisCall : .removed
        case .ok, .unreachable: callCapturing ? .savedForNextCall : .saved
        }
    }
}

/// What the host knows about the stored key's standing with OpenAI. Only `rejected` withholds it.
public enum KeyGateState: String, Equatable, Sendable {
    /// Not asked yet, or the last check could not reach OpenAI: the key is used.
    case unchecked
    /// OpenAI accepted it.
    case accepted
    /// OpenAI refused it (401 or 403): GPT cues stay off until it is replaced.
    case rejected

    /// The state after a check result: a refusal withholds the key; an answer of "ok" clears it; no
    /// answer (unreachable) or no key leaves it unchecked.
    public static func after(_ check: KeyCheck) -> KeyGateState {
        switch check {
        case .ok: .accepted
        case .rejected: .rejected
        case .unreachable, .empty: .unchecked
        }
    }
}

/// A key provider that can say whether it is withholding the key for being rejected.
public protocol KeyGateStateProviding {
    var gateState: KeyGateState { get }
}

/// Whether a call's engine got a key, and if not, why.
public enum KeyAvailability: Equatable, Sendable {
    case present
    case absent
    case rejected
}

/// Whether a key is stored, kept by the host and updated only when the key is loaded, saved or
/// removed. A refresh tick reads this value, never the Keychain: reading the item returns the secret,
/// which is not something to do once a second.
public struct KeyPresence: Equatable, Sendable {
    public private(set) var stored = false
    /// The last load failed: the Keychain refused, which is not the same as having no key.
    public private(set) var unreadable = false

    public init() {}

    /// Reads the key once and records what was there: `stored` for a key, nothing stored for none, and
    /// `unreadable` for a Keychain failure (logged with its OSStatus). Returns the key, if any.
    public mutating func load(from provider: APIKeyProvider, at context: KeyReadContext = .stored) -> APIKey? {
        do {
            let key = try provider.readKey()
            stored = key != nil
            unreadable = false
            CoachLog.record(.keyRead(key == nil ? .absent : .present, status: nil, at: context))
            return key
        } catch {
            unreadable = true
            CoachLog.record(.keyRead(.unreadable, status: CoachLog.status(of: error), at: context))
            return nil
        }
    }

    public mutating func saved() {
        stored = true
        unreadable = false
    }

    public mutating func removed() {
        stored = false
        unreadable = false
    }

    /// The field placeholder to set now, or nil when it already matches. No Keychain access.
    public func placeholder(shown: KeyPlaceholder?) -> KeyPlaceholder? {
        KeyPlaceholder.refresh(shown: shown, hasKey: stored)
    }
}
