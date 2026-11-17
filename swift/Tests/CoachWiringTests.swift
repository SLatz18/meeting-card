import XCTest

/// The call coach is wired in as an opt-in: a local package (vendored, no remote dependency),
/// permission strings present, the opt-in a UserDefaults boolean (false until set).
final class CoachWiringTests: XCTestCase {
    static let swiftDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    func read(_ path: String) throws -> String {
        try String(contentsOf: Self.swiftDir.appendingPathComponent(path), encoding: .utf8)
    }

    func testKitIsALocalPackage() throws {
        let spec = try read("project.yml")
        XCTAssertTrue(spec.contains("path: Packages/ListenMoreKit"))
        XCTAssertFalse(spec.contains("url:"), "no remote package dependencies")
        XCTAssertTrue(spec.contains("product: ListenMoreMac"))
    }

    func testUsageStringsShip() throws {
        for f in ["project.yml", "App/Info.plist"] {
            let s = try read(f)
            XCTAssertTrue(s.contains("NSMicrophoneUsageDescription"), f)
            XCTAssertTrue(s.contains("NSAudioCaptureUsageDescription"), f)
        }
    }

    func testOptInIsOffByDefault() throws {
        let src = try read("App/CoachController.swift")
        XCTAssertTrue(src.contains("static let enabled = \"coach.enabled\""))
        XCTAssertTrue(src.contains("var enabled: Bool { defaults.bool(forKey: Keys.enabled) }"), "bool(forKey:) is false until set")
        XCTAssertFalse(src.contains("register(defaults"), "no default that turns it on")
        let controller = try read("App/Controller.swift")
        XCTAssertTrue(controller.contains("if args.fixture == nil {\n            do {\n                coach = try CoachController()"),
                      "fixture runs never create the coach")
        XCTAssertTrue(controller.contains("log(ListenMoreConfig.loadFailureMessage(error))"),
                      "a config failure logs its type only")
    }
}
