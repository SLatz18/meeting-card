import XCTest

/// Static guard over the coach sources (the Kit's `Sources/` and the app's `App/Coach*.swift`):
/// audio and text stay in memory, nothing content-like is printed or persisted, the key is only
/// touched through KeychainStore, and public log arguments are counters, enums and booleans.
final class PrivacyGuardTests: XCTestCase {
    static let kitURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let sourcesURL = kitURL.appendingPathComponent("Sources")
    /// swift/Packages/ListenMoreKit -> swift/App
    static let appURL = kitURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App")

    func swiftFiles(in dir: URL, prefix: String = "") throws -> [(String, String)] {
        let e = try XCTUnwrap(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil))
        return try e.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent.hasPrefix(prefix) }
            .map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    func kitSources() throws -> [(String, String)] { try swiftFiles(in: Self.sourcesURL) }
    func appCoachSources() throws -> [(String, String)] { try swiftFiles(in: Self.appURL, prefix: "Coach") }
    func allSources() throws -> [(String, String)] { try kitSources() + appCoachSources() }

    func testFindsSources() throws {
        XCTAssertGreaterThan(try kitSources().count, 10)
        XCTAssertGreaterThan(try appCoachSources().count, 0)
    }

    func testNoDiskWritesOrPersistence() throws {
        let forbidden = ["write(to:", "createFile(", "FileHandle(forWriting", "NSKeyedArchiver",
                         "AVAudioFile(forWriting", "AVAssetWriter", "SCRecordingOutput", "fopen(", "SCScreenshotManager"]
        for (name, text) in try allSources() {
            for f in forbidden { XCTAssertFalse(text.contains(f), "\(name) contains \(f)") }
        }
        // The app stores two booleans for the opt-in; the Kit stores nothing.
        for (name, text) in try kitSources() { XCTAssertFalse(text.contains("UserDefaults"), name) }
    }

    func testNoPrintOrNSLog() throws {
        for (name, text) in try allSources() {
            XCTAssertNil(text.range(of: #"(^|[^A-Za-z.])(print|NSLog|debugPrint|dump)\("#, options: .regularExpression), name)
        }
    }

    func testCoachNeverUsesTheAppFileLog() throws {
        for (name, text) in try appCoachSources() {
            XCTAssertNil(text.range(of: #"\blog\("#, options: .regularExpression), "\(name) writes to the file log")
        }
    }

    func testKeyOnlyFromKeychain() throws {
        for (name, text) in try allSources() where text.contains("OPENAI_API_KEY") {
            XCTAssertEqual(name, "KeychainStore.swift", "\(name) mentions OPENAI_API_KEY")
        }
        for (name, text) in try allSources() {
            XCTAssertFalse(text.contains("environment[\"OPENAI"), name)
            XCTAssertFalse(text.contains("UserDefaults") && text.lowercased().contains("apikey") && text.contains(".set("),
                           "\(name) may store the key in defaults")
        }
    }

    func testPublicLogArgumentsAreNotContent() throws {
        let allowed = ["stage", "count", "active", "kind", "code", "isVoiceProcessingEnabled", "reason", "paused",
                       "frames", "cues", "status", "enabled"]
        let re = try NSRegularExpression(pattern: #"\\\(([^)]*)\)?[^)]*, privacy: \.public\)"#)
        for (name, text) in try allSources() {
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let arg = (text as NSString).substring(with: m.range(at: 1))
                XCTAssertTrue(allowed.contains { arg.lowercased().contains($0.lowercased()) }, "\(name): public log of \(arg)")
            }
        }
    }

    func testNoSecretsOrEmployerReferences() throws {
        let banned = [#"sk-[A-Za-z0-9]{20,}"#, #"(?i)\bscott\b"#, #"(?i)\bCTO\b"#, #"(?i)VP Comms"#]
        for (name, text) in try allSources() {
            for b in banned { XCTAssertNil(text.range(of: b, options: .regularExpression), "\(name) matches \(b)") }
        }
    }
}
