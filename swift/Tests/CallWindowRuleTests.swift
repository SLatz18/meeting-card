import XCTest
@testable import MeetingCardCore

/// The `callWindowBinding` flag: off (and unset) is main's largest-window rule, on is the call-window
/// binding, and the flag is read at one place only.
final class CallWindowRuleTests: XCTestCase {
    static let swiftDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    var suite = ""
    var defaults: UserDefaults!

    override func setUp() {
        suite = "call-window-rule-tests-\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suite)
    }

    override func tearDown() { defaults.removePersistentDomain(forName: suite) }

    /// All flags off, a fresh defaults domain, and flags stored on: the rule is main's with the first two
    /// and differs from it with the third (`assertAllOffMatchesMain`). The expected value is main's rule.
    func testAllOffIsMainsLargestWindowRule() {
        assertAllOffMatchesMain({ flags in CallWindowRule.resolve(flags) }, equals: .largestWindow)
    }

    func testFlagIsOffByDefaultAndNamedByItsKey() {
        XCTAssertFalse(FeatureFlag.callWindowBinding.defaultValue)
        XCTAssertEqual(FeatureFlag.callWindowBinding.defaultsKey, "flag.callWindowBinding")
        XCTAssertEqual(CallWindowRule.resolve(FeatureFlags(defaults: defaults)), .largestWindow, "nothing stored")
        XCTAssertEqual(CallWindowRule.resolve(.allOff), .largestWindow)
    }

    /// Flag on turns the call-window binding on, and a stored false turns it off again.
    func testFlagOnEnablesTheCallWindowBinding() {
        defaults.set(true, forKey: FeatureFlag.callWindowBinding.defaultsKey)
        XCTAssertEqual(CallWindowRule.resolve(FeatureFlags(defaults: defaults)), .boundWindow)
        XCTAssertEqual(CallWindowRule.resolve(.allOff), .largestWindow, "all-off ignores what is stored")
        defaults.set(false, forKey: FeatureFlag.callWindowBinding.defaultsKey)
        XCTAssertEqual(CallWindowRule.resolve(FeatureFlags(defaults: defaults)), .largestWindow)
    }

    /// The flag is read in `CallWindowRule.resolve` only, and the app builds the window tracker from the
    /// rule: with the rule off it has none, so the service and the call controls take main's paths.
    func testTheFlagIsReadAtOneEntryPoint() throws {
        let dirs = ["App", "Core", "Packages/ListenMoreKit/Sources"]
        var readers: [String] = []
        for dir in dirs {
            let root = Self.swiftDir.appendingPathComponent(dir)
            let files = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
            for case let url as URL in files where url.pathExtension == "swift" {
                let text = try String(contentsOf: url, encoding: .utf8)
                let code = text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
                if code.contains(".callWindowBinding") { readers.append(url.lastPathComponent) }
            }
        }
        XCTAssertEqual(readers.sorted(), ["CallWindowRule.swift", "FeatureFlags.swift"].sorted(),
                       "the flag is named in its registry case and in the one entry point")
        let controller = try String(contentsOf: Self.swiftDir.appendingPathComponent("App/CoachController.swift"), encoding: .utf8)
        XCTAssertEqual(controller.components(separatedBy: "CallWindowRule.resolve(").count - 1, 1, "asked once")
        XCTAssertTrue(controller.contains("case .largestWindow: callWindows = nil"))
        XCTAssertTrue(controller.contains("case .boundWindow: callWindows = CallWindowTracker(config: config)"))
        XCTAssertFalse(controller.contains("isEnabled("), "the controller never reads a flag itself")
    }
}
