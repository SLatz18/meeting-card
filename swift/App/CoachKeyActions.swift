import Foundation
import ListenMoreCore
import ListenMoreMac

/// Key entry from Settings. Kept apart from the settings defaults: the keys go to the Keychain
/// only (see `KeychainStore`) and are never logged. The OpenAI key is checked with GET /v1/models.
extension CoachController {
    /// Saves (or, for blank text, removes) the key. A key OpenAI rejects is not saved. Without a
    /// usable key the coach stays on with local cues only; a saved key is used from the next call.
    func saveKey(_ text: String, completion: @escaping (KeyCheck) -> Void) {
        guard let key = APIKey(text) else {
            removeKey()
            keyGate.record(.empty)
            keyProblem = nil
            CoachLog.record(.keyCheck(.empty, source: .save, httpStatus: nil))
            refresh()
            completion(.empty)
            return
        }
        Task { @MainActor in
            let outcome = await KeyValidator.checkWithStatus(key.value)
            let check = outcome.check
            CoachLog.record(.keyCheck(check, source: .save, httpStatus: outcome.httpStatus))
            if check != .rejected {
                self.storeKey(key)
                self.keyGate.record(check)
            }
            self.keyProblem = check == .ok ? nil : check
            self.refresh()
            completion(check)
        }
    }

    /// Saves the key and records it as stored; a failed save is logged with its OSStatus and the presence
    /// is read back once, so it never claims a key that is not there.
    private func storeKey(_ key: APIKey) {
        do {
            try keychain.save(key)
            keyPresence.saved()
            CoachLog.record(.keyStore(.save, ok: true, status: nil))
        } catch {
            CoachLog.record(.keyStore(.save, ok: false, status: CoachLog.status(of: error)))
            _ = keyPresence.load(from: keychain)
        }
    }

    private func removeKey() {
        do {
            try keychain.delete()
            keyPresence.removed()
            CoachLog.record(.keyStore(.remove, ok: true, status: nil))
        } catch {
            CoachLog.record(.keyStore(.remove, ok: false, status: CoachLog.status(of: error)))
            _ = keyPresence.load(from: keychain)
        }
    }

    /// Saves (or, for blank text, removes) the TypeSafe key, in its own Keychain account. Nothing is
    /// sent to check it, so no call is made before the user's next coached call; it is used from then.
    func saveTypeSafeKey(_ text: String) {
        if let key = APIKey(text) {
            try? typeSafeKeychain.save(key)
        } else {
            try? typeSafeKeychain.delete()
        }
        typeSafeKeyStored = typeSafeKeychain.hasKey
        refresh()
    }
}

/// The key as the coach service sees it: the Keychain item, withheld while OpenAI rejects it so
/// GPT cues stay off and local cues keep running.
final class CoachKeyGate: APIKeyProvider, KeyGateStateProviding {
    let store: KeychainStore
    private(set) var state: KeyGateState = .unchecked

    init(_ store: KeychainStore) { self.store = store }

    var gateState: KeyGateState { state }
    var rejected: Bool { state == .rejected }

    /// Moves the gate to what a check result means (see `KeyGateState.after`) and logs a change.
    func record(_ check: KeyCheck) {
        let next = KeyGateState.after(check)
        guard next != state else { return }
        state = next
        CoachLog.record(.keyGate(next))
    }

    func readKey() throws -> APIKey? { rejected ? nil : try store.readKey() }
}
