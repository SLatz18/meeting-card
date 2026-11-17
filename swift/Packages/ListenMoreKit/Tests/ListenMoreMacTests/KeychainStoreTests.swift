import Security
import XCTest
import ListenMoreCore
@testable import ListenMoreMac

/// Uses a throwaway service name so a real key item is never touched.
final class KeychainStoreTests: XCTestCase {
    var store: KeychainStore!

    override func setUpWithError() throws {
        store = KeychainStore(service: "com.listenmore.tests.\(UUID().uuidString)", account: "test")
        try? store.delete()
    }

    override func tearDownWithError() throws {
        try? store?.delete()
    }

    /// CI keychains can be locked or absent; the query-shape tests below still run.
    func requireKeychain() throws {
        do {
            _ = try store.readKey()
        } catch KeychainStore.KeychainError.unexpectedStatus(let s) {
            throw XCTSkip("keychain unavailable on this runner (OSStatus \(s))")
        }
    }

    func testNamesAreGenericAndServiceIsInjectable() {
        XCTAssertEqual(KeychainStore.defaultService, "com.listenmore.mac.openai")
        XCTAssertEqual(KeychainStore.defaultAccount, "OPENAI_API_KEY")
        XCTAssertEqual(KeychainStore().service, KeychainStore.defaultService)
        XCTAssertNotEqual(store.service, KeychainStore.defaultService)
        let host = KeychainStore(service: "com.example.hostapp.openai")
        XCTAssertEqual(host.service, "com.example.hostapp.openai")
        XCTAssertEqual(host.baseQuery(.login)[kSecAttrService as String] as? String, "com.example.hostapp.openai")
        XCTAssertEqual(host.baseQuery(.dataProtection)[kSecAttrService as String] as? String, "com.example.hostapp.openai")
    }

    func testAddQueryIsThisDeviceOnlyAndNotSynchronizable() {
        let q = store.addQuery(Data("x".utf8))
        XCTAssertEqual(q[kSecAttrAccessible as String] as! CFString, kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
        XCTAssertEqual(q[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(q[kSecClass as String] as! CFString, kSecClassGenericPassword)
        XCTAssertEqual(q[kSecUseDataProtectionKeychain as String] as? Bool, true)
        let login = store.addQuery(Data("x".utf8), .login)
        XCTAssertNil(login[kSecUseDataProtectionKeychain as String])
        XCTAssertEqual(login[kSecAttrAccessible as String] as! CFString, kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
        XCTAssertEqual(login[kSecAttrSynchronizable as String] as? Bool, false)
    }

    func testAccessGroupOnlyOnTheDataProtectionQuery() {
        let grouped = KeychainStore(service: "com.listenmore.tests.group", account: "test", accessGroup: "ABCDE12345.com.example")
        XCTAssertEqual(grouped.baseQuery(.dataProtection)[kSecAttrAccessGroup as String] as? String, "ABCDE12345.com.example")
        XCTAssertNil(grouped.baseQuery(.login)[kSecAttrAccessGroup as String])
        XCTAssertNil(store.baseQuery(.dataProtection)[kSecAttrAccessGroup as String])
    }

    /// ThisDeviceOnly is enforced only in the data protection keychain (entitled, signed builds).
    func assertAccessibilityWhereEnforced() {
        if store.location() == .dataProtection {
            XCTAssertEqual(store.storedAccessibility(), kSecAttrAccessibleWhenUnlockedThisDeviceOnly as String)
        } else {
            XCTAssertEqual(store.location(), .login)
            XCTAssertNil(store.storedAccessibility())
        }
    }

    func testMissingKeyReadsNil() throws {
        try requireKeychain()
        XCTAssertNil(try store.readKey())
        XCTAssertFalse(store.hasKey)
    }

    func testSaveReadUpdateDelete() throws {
        try requireKeychain()
        try store.save(APIKey("sk-test-first")!)
        XCTAssertEqual(try store.readKey()?.value, "sk-test-first")
        XCTAssertTrue(store.hasKey)
        assertAccessibilityWhereEnforced()
        try store.save(APIKey("sk-test-second")!)
        XCTAssertEqual(try store.readKey()?.value, "sk-test-second")
        assertAccessibilityWhereEnforced()
        try store.delete()
        XCTAssertNil(try store.readKey())
        XCTAssertNil(store.location())
        XCTAssertNoThrow(try store.delete())
    }

    /// This test process is unsigned: the data protection keychain refuses it, and the key falls
    /// back to the login keychain instead of failing.
    func testUnsignedBuildFallsBackToLoginKeychain() throws {
        try requireKeychain()
        try store.save(APIKey("sk-test-fallback")!)
        XCTAssertEqual(store.location(), .login)
        XCTAssertEqual(try store.readKey()?.value, "sk-test-fallback")
    }

    func testServicesAreIsolated() throws {
        try requireKeychain()
        let other = KeychainStore(service: store.service + ".other", account: "test")
        defer { try? other.delete() }
        try store.save(APIKey("sk-test-a")!)
        XCTAssertNil(try other.readKey())
    }

    func testIsTheSessionKeyProvider() throws {
        try requireKeychain()
        try store.save(APIKey("sk-test-provider")!)
        let provider: APIKeyProvider = store
        XCTAssertEqual(try provider.readKey()?.value, "sk-test-provider")
    }

    func testErrorsCarryNoSecret() {
        let status = KeychainStore.KeychainError.unexpectedStatus(-25300)
        let data = KeychainStore.KeychainError.badData("value")
        XCTAssertFalse(String(describing: status).contains("sk-"))
        XCTAssertFalse(String(describing: data).contains("sk-"))
    }
}
