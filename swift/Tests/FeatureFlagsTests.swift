import XCTest
@testable import MeetingCardCore

/// The extension point. A PR that gates a behavior calls this from any test file with the gated entry
/// point and what main produced for the same input, written down before the gate existed:
///
///     assertAllOffMatchesMain({ flags in entryPoint(input, flags: flags) }, equals: mainResult)
///
/// It runs the entry point with every flag forced off and again with a fresh defaults domain (what a
/// user who never touched a flag has); both must equal `main`. Flags stored ON are not covered here:
/// that is the new behavior and gets its own tests.
func assertAllOffMatchesMain<T: Equatable>(_ behavior: (FeatureFlags) -> T, equals main: T,
                                           file: StaticString = #filePath, line: UInt = #line) {
    let suite = "all-off-\(UUID().uuidString)"
    guard let fresh = UserDefaults(suiteName: suite) else { return XCTFail("no defaults suite", file: file, line: line) }
    defer { fresh.removePersistentDomain(forName: suite) }
    XCTAssertEqual(behavior(.allOff), main, "all flags off differs from main", file: file, line: line)
    XCTAssertEqual(behavior(FeatureFlags(defaults: fresh)), main, "default flags differ from main", file: file, line: line)
}

/// The feature-flag registry (Core/FeatureFlags.swift): every registered flag defaults off, and
/// `assertAllOffMatchesMain` (above) is the check a later PR uses to prove its gate changes nothing while off.
final class FeatureFlagsTests: XCTestCase {
    var suite = ""
    var defaults: UserDefaults!

    override func setUp() {
        suite = "feature-flags-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    /// Every registered flag is off with nothing stored, and its static default is off.
    func testEveryRegisteredFlagDefaultsOff() {
        let flags = FeatureFlags(defaults: defaults)
        for flag in FeatureFlag.allCases {
            XCTAssertFalse(flag.defaultValue, "\(flag.rawValue) must default off")
            XCTAssertFalse(flags.isEnabled(flag), "\(flag.rawValue) reads on with nothing stored")
            XCTAssertFalse(FeatureFlags.allOff.isEnabled(flag), "\(flag.rawValue) is on in allOff")
        }
        XCTAssertEqual(Set(FeatureFlag.allCases.map(\.defaultsKey)).count, FeatureFlag.allCases.count, "flag keys must be unique")
        for flag in FeatureFlag.allCases { XCTAssertTrue(flag.defaultsKey.hasPrefix("flag.")) }
    }

    /// A stored Bool is read like the coach settings; allOff ignores it.
    func testStoredValueIsReadAndAllOffIgnoresIt() {
        for flag in FeatureFlag.allCases {
            defaults.set(true, forKey: flag.defaultsKey)
            XCTAssertTrue(FeatureFlags(defaults: defaults).isEnabled(flag))
            XCTAssertFalse(FeatureFlags.allOff.isEnabled(flag))
            defaults.removeObject(forKey: flag.defaultsKey)
            XCTAssertFalse(FeatureFlags(defaults: defaults).isEnabled(flag))
        }
    }

    /// The helper passes for a gate that is inert while every flag is off.
    func testAllOffHelperAcceptsAnInertGate() {
        assertAllOffMatchesMain({ flags in
            FeatureFlag.allCases.contains(where: flags.isEnabled) ? "new behavior" : "main behavior"
        }, equals: "main behavior")
    }
}
