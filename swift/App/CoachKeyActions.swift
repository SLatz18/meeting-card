import Foundation
import ListenMoreCore
import ListenMoreMac

/// Key entry from Settings. Kept apart from the settings defaults: the key goes to the Keychain
/// only (see `KeychainStore`), is checked with GET /v1/models, and is never logged.
extension CoachController {
    /// Saves (or, for blank text, removes) the key. A key OpenAI rejects is not saved. Without a
    /// usable key the coach stays on with local cues only; a saved key is used from the next call.
    func saveKey(_ text: String, completion: @escaping (KeyCheck) -> Void) {
        guard let key = APIKey(text) else {
            try? keychain.delete()
            keyStored = hasKey
            keyGate.rejected = false
            keyProblem = nil
            refresh()
            completion(.empty)
            return
        }
        Task { @MainActor in
            let check = await KeyValidator.check(key.value)
            if check != .rejected {
                try? self.keychain.save(key)
                self.keyStored = self.hasKey
                self.keyGate.rejected = false
            }
            self.keyProblem = check == .ok ? nil : check
            self.refresh()
            completion(check)
        }
    }

}

/// The key as the coach service sees it: the Keychain item, withheld while OpenAI rejects it so
/// GPT cues stay off and local cues keep running.
final class KeyGate: APIKeyProvider {
    let store: KeychainStore
    var rejected = false

    init(_ store: KeychainStore) { self.store = store }

    func readKey() throws -> APIKey? { rejected ? nil : try store.readKey() }
}
