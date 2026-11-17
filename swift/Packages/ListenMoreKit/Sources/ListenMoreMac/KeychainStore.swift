import Foundation
import ListenMoreCore
import Security

/// The OpenAI key lives only in the Keychain as a generic password, never synced. It goes to the
/// data protection keychain when the build is entitled to it (a signed app with a team ID), where
/// `kSecAttrAccessibleWhenUnlockedThisDeviceOnly` is enforced: readable only while the Mac is
/// unlocked and never migrated to another device. Ad-hoc and self-signed builds get
/// `errSecMissingEntitlement` (-34018) there, so the key goes to the login keychain instead, which
/// ignores accessibility classes (see docs/SIGNING_PLAN.md). Values never appear in errors,
/// descriptions or logs; errors carry the OSStatus or an attribute name, never the key.
///
/// The service name is the host's: the Kit default is generic, and each app passes its own.
public struct KeychainStore: APIKeyProvider {
    public static let defaultService = "com.listenmore.mac.openai"
    public static let defaultAccount = "OPENAI_API_KEY"
    public static let accessibility = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

    public enum KeychainError: Error, Equatable {
        case unexpectedStatus(OSStatus)
        case badData(String)
    }

    public enum Location: Equatable {
        case dataProtection
        case login
    }

    public let service: String
    public let account: String
    /// Team-prefixed keychain access group for the data protection keychain (e.g. `ABCDE12345.com.example.app`);
    /// nil uses the app's default group.
    public let accessGroup: String?

    public init(service: String = KeychainStore.defaultService, account: String = KeychainStore.defaultAccount,
                accessGroup: String? = nil) {
        self.service = service
        self.account = account
        self.accessGroup = accessGroup
    }

    func baseQuery(_ location: Location) -> [String: Any] {
        var q: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
                                kSecAttrService as String: service,
                                kSecAttrAccount as String: account]
        if location == .dataProtection {
            q[kSecUseDataProtectionKeychain as String] = true
            if let accessGroup { q[kSecAttrAccessGroup as String] = accessGroup }
        }
        return q
    }

    /// The add query: value + ThisDeviceOnly accessibility, never synchronizable. Login-keychain items
    /// do not echo `kSecAttrAccessible` back, so tests assert this dictionary rather than a read-back.
    func addQuery(_ data: Data, _ location: Location = .dataProtection) -> [String: Any] {
        var add = baseQuery(location)
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = Self.accessibility
        add[kSecAttrSynchronizable as String] = kCFBooleanFalse
        return add
    }

    /// Where the stored key lives, or nil if there is none.
    public func location() -> Location? {
        for loc in [Location.dataProtection, .login] where (try? read(loc)) != nil { return loc }
        return nil
    }

    public func readKey() throws -> APIKey? {
        if let key = try read(.dataProtection) { return key }
        return try read(.login)
    }

    private func read(_ location: Location) throws -> APIKey? {
        var query = baseQuery(location)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let s = String(data: data, encoding: .utf8) else { throw KeychainError.badData("value") }
            return APIKey(s)
        case errSecItemNotFound:
            return nil
        case errSecMissingEntitlement where location == .dataProtection:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public var hasKey: Bool { (try? readKey()) != nil }

    /// Replaces any existing item in either keychain.
    public func save(_ key: APIKey) throws {
        try delete()
        let data = Data(key.value.utf8)
        var status = SecItemAdd(addQuery(data, .dataProtection) as CFDictionary, nil)
        if status == errSecMissingEntitlement {
            status = SecItemAdd(addQuery(data, .login) as CFDictionary, nil)
        }
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    /// Accessibility class of the key in the data protection keychain, or nil if it isn't there.
    public func storedAccessibility() -> String? {
        var query = baseQuery(.dataProtection)
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let attrs = item as? [String: Any] else { return nil }
        return attrs[kSecAttrAccessible as String] as? String
    }

    public func delete() throws {
        for loc in [Location.dataProtection, .login] {
            let status = SecItemDelete(baseQuery(loc) as CFDictionary)
            let ok = status == errSecSuccess || status == errSecItemNotFound
                || (status == errSecMissingEntitlement && loc == .dataProtection)
            guard ok else { throw KeychainError.unexpectedStatus(status) }
        }
    }
}
