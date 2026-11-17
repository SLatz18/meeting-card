import Security
import XCTest
import ListenMoreCore
@testable import ListenMoreMac

/// Uses a throwaway service name so the real key item is never touched.
final class KeychainStoreTests: XCTestCase {
    var store: KeychainStore!

    override func setUpWithError() throws {
        store = KeychainStore(service: "com.slatz.meetingcard.tests.\(UUID().uuidString)", account: "test")
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

    func testNames() {
        XCTAssertEqual(KeychainStore.defaultService, "com.slatz.meetingcard.swift.openai")
        XCTAssertEqual(KeychainStore.defaultAccount, "OPENAI_API_KEY")
        XCTAssertEqual(KeychainStore().service, KeychainStore.defaultService)
        XCTAssertNotEqual(store.service, KeychainStore.defaultService)
    }

    func testAddQueryIsThisDeviceOnlyAndNotSynchronizable() {
        let q = store.addQuery(Data("x".utf8))
        XCTAssertEqual(q[kSecAttrAccessible as String] as! CFString, kSecAttrAccessibleWhenUnlockedThisDeviceOnly)
        XCTAssertEqual(q[kSecAttrSynchronizable as String] as? Bool, false)
        XCTAssertEqual(q[kSecClass as String] as! CFString, kSecClassGenericPassword)
        XCTAssertEqual(q[kSecUseDataProtectionKeychain as String] as? Bool, true)
        let login = store.addQuery(Data("x".utf8), .login)
        XCTAssertNil(login[kSecUseDataProtectionKeychain as String])
        XCTAssertEqual(login[kSecAttrSynchronizable as String] as? Bool, false)
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
    }

    func testSaveReadUpdateDelete() throws {
        try requireKeychain()
        try store.save(APIKey("sk-test-first")!)
        XCTAssertEqual(try store.readKey()?.value, "sk-test-first")
        assertAccessibilityWhereEnforced()
        try store.save(APIKey("sk-test-second")!)
        XCTAssertEqual(try store.readKey()?.value, "sk-test-second")
        assertAccessibilityWhereEnforced()
        try store.delete()
        XCTAssertNil(try store.readKey())
        XCTAssertNil(store.location())
        XCTAssertNoThrow(try store.delete())
    }

    func testServicesAreIsolated() throws {
        try requireKeychain()
        let other = KeychainStore(service: store.service + ".other", account: "test")
        defer { try? other.delete() }
        try store.save(APIKey("sk-test-a")!)
        XCTAssertNil(try other.readKey())
    }

    func testErrorsCarryNoSecret() {
        let e = KeychainStore.KeychainError.unexpectedStatus(-25300)
        XCTAssertFalse(String(describing: e).contains("sk-"))
    }
}
