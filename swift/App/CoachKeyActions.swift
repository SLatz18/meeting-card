import Foundation
import ListenMoreCore
import ListenMoreMac

/// Key entry from Settings. Kept apart from the settings defaults: the key goes to the Keychain
/// only (ThisDeviceOnly), is checked with GET /v1/models, and is never logged.
extension CoachController {
    /// Saves (or, for blank text, removes) the key. A key OpenAI rejects is not saved.
    func saveKey(_ text: String, completion: @escaping (KeyCheck) -> Void) {
        guard let key = APIKey(text) else {
            try? keychain.delete()
            keyProblem = .empty
            if enabled { setEnabled(false) { _ in } }
            completion(.empty)
            return
        }
        Task { @MainActor in
            let check = await KeyValidator.check(key.value)
            if check != .rejected { try? self.keychain.save(key) }
            self.keyProblem = check == .ok ? nil : check
            completion(check)
        }
    }

}
