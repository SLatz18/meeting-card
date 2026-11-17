import Foundation
import ListenMoreCore
import Security

/// The OpenAI key lives only in the login Keychain as a generic password, readable only while the
/// Mac is unlocked and never synced or migrated to another device
/// (`kSecAttrAccessibleWhenUnlockedThisDeviceOnly`). Values never appear in errors, descriptions or
/// logs; errors carry the OSStatus only.
public struct KeychainStore {
    public static let defaultService = "com.slatz.meetingcard.swift.openai"
    public static let defaultAccount = "OPENAI_API_KEY"
    public static let accessibility = kSecAttrAccessibleWhenUnlockedThisDeviceOnly

    public enum KeychainError: Error, Equatable {
        case unexpectedStatus(OSStatus)
        case badData
    }

    public let service: String
    public let account: String

    public init(service: String = KeychainStore.defaultService, account: String = KeychainStore.defaultAccount) {
        self.service = service
        self.account = account
    }

    var baseQuery: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: account]
    }

    /// The add query (exposed for tests): value + ThisDeviceOnly accessibility, never synchronizable.
    func addQuery(_ data: Data) -> [String: Any] {
        var add = baseQuery
        add[kSecValueData as String] = data
        add[kSecAttrAccessible as String] = Self.accessibility
        add[kSecAttrSynchronizable as String] = kCFBooleanFalse
        return add
    }

    public func readKey() throws -> APIKey? {
        var query = baseQuery
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            guard let data = item as? Data, let s = String(data: data, encoding: .utf8) else { throw KeychainError.badData }
            return APIKey(s)
        case errSecItemNotFound:
            return nil
        default:
            throw KeychainError.unexpectedStatus(status)
        }
    }

    public var hasKey: Bool { (try? readKey()) != nil }

    /// Replaces any existing item, so the accessibility class is always ThisDeviceOnly even if an
    /// older item was created with a weaker one.
    public func save(_ key: APIKey) throws {
        try delete()
        let status = SecItemAdd(addQuery(Data(key.value.utf8)) as CFDictionary, nil)
        guard status == errSecSuccess else { throw KeychainError.unexpectedStatus(status) }
    }

    /// Accessibility class of the stored item (tests and the IT checklist), or nil if none.
    public func storedAccessibility() -> String? {
        var query = baseQuery
        query[kSecReturnAttributes as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let attrs = item as? [String: Any] else { return nil }
        return attrs[kSecAttrAccessible as String] as? String
    }

    public func delete() throws {
        let status = SecItemDelete(baseQuery as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else { throw KeychainError.unexpectedStatus(status) }
    }
}
