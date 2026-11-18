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
