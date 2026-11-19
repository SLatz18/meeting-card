import XCTest
@testable import MeetingCardCore

/// The extension point. A PR that gates a behavior calls this from any test file with the gated entry
/// point and what main produced for the same input:
///
///     assertAllOffMatchesMain({ flags in entryPoint(input, flags: flags) }, equals: mainResult)
///
/// `main` must be a literal, a fixture captured from main, or the expected value of an existing test,
/// never a value computed by calling the entry point or any code the gating PR added. The gating PR
/// must also leave the existing tests of that entry point unchanged: they run with every flag off and
/// are the real proof that off behaves like main. This helper adds the wiring check on top.
///
/// It runs the entry point three ways:
///   1. every flag forced off: must equal `main`;
///   2. a fresh defaults domain (a user who never touched a flag): must equal `main`;
///   3. every flag stored ON: must differ from `main`. This shows the entry point reads the flags it
///      was handed, so the two equalities above mean something. Pick an input where the new behavior
///      differs from main's.
func assertAllOffMatchesMain<T: Equatable>(_ behavior: (FeatureFlags) -> T, equals main: T,
                                           file: StaticString = #filePath, line: UInt = #line) {
    let offSuite = "all-off-\(UUID().uuidString)", onSuite = "all-on-\(UUID().uuidString)"
    guard let fresh = UserDefaults(suiteName: offSuite), let on = UserDefaults(suiteName: onSuite) else {
        return XCTFail("no defaults suite", file: file, line: line)
    }
    defer {
        fresh.removePersistentDomain(forName: offSuite)
        on.removePersistentDomain(forName: onSuite)
    }
    for flag in FeatureFlag.allCases { on.set(true, forKey: flag.defaultsKey) }
    XCTAssertEqual(behavior(.allOff), main, "all flags off differs from main", file: file, line: line)
    XCTAssertEqual(behavior(FeatureFlags(defaults: fresh)), main, "default flags differ from main", file: file, line: line)
    XCTAssertNotEqual(behavior(FeatureFlags(defaults: on)), main,
                      "flags on still gives main: the entry point does not read the flags it was passed", file: file, line: line)
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

    /// The helper passes for a gate that reads its flags and is inert while every flag is off.
    func testAllOffHelperAcceptsAnInertGate() {
        assertAllOffMatchesMain({ flags in
            FeatureFlag.allCases.contains(where: flags.isEnabled) ? "new behavior" : "main behavior"
        }, equals: "main behavior")
    }

    /// The helper rejects a gate that never reads the flags it is given (it would pass the off checks
    /// whatever the flags say).
    func testAllOffHelperRejectsAGateThatIgnoresItsFlags() {
        XCTExpectFailure("a gate that ignores its flags must fail the flags-on check") {
            assertAllOffMatchesMain({ _ in "main behavior" }, equals: "main behavior")
        }
    }
}
