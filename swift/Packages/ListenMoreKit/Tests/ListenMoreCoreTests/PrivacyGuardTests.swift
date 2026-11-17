import XCTest

/// Static guard over the coach sources: the package's library targets plus MeetingCard's
/// `App/Coach*.swift`. Audio and text stay in memory, nothing content-like is printed or persisted,
/// the key is only touched through KeychainStore, public log arguments are counters, enums and
/// booleans, and nothing reads window titles.
final class PrivacyGuardTests: XCTestCase {
    static let packageURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let sourcesURL = packageURL.appendingPathComponent("Sources")
    static let testsURL = packageURL.appendingPathComponent("Tests")
    static let libraryTargets = ["CWebRTCVAD", "ListenMoreCore", "ListenMoreMac"]
    /// MeetingCard's app sources (`swift/App` for the package at `swift/Packages/ListenMoreKit`).
    static let hostAppURL = packageURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App")

    static func exists(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    func swiftFiles(in dir: URL, prefix: String = "") throws -> [(String, String)] {
        guard Self.exists(dir) else { return [] }
        let e = try XCTUnwrap(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil))
        return try e.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent.hasPrefix(prefix) }
            .map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    func librarySources() throws -> [(String, String)] {
        try Self.libraryTargets.flatMap { try swiftFiles(in: Self.sourcesURL.appendingPathComponent($0)) }
    }

    func appSources() throws -> [(String, String)] {
        try swiftFiles(in: Self.hostAppURL, prefix: "Coach")
    }

    func allSources() throws -> [(String, String)] { try librarySources() + appSources() }

    func testFindsSources() throws {
        XCTAssertGreaterThan(try librarySources().count, 10)
        XCTAssertTrue(Self.exists(Self.hostAppURL), "the app's coach sources must be covered")
        XCTAssertGreaterThan(try appSources().count, 0)
    }

    func testNoDiskWritesOrPersistence() throws {
        let forbidden = ["write(to:", "createFile(", "FileHandle(forWriting", "NSKeyedArchiver",
                         "AVAudioFile(forWriting", "AVAssetWriter", "SCRecordingOutput", "fopen(", "SCScreenshotManager"]
        for (name, text) in try allSources() {
            for f in forbidden { XCTAssertFalse(text.contains(f), "\(name) contains \(f)") }
        }
        // A host app may store coach settings (see testHostDefaultsAreSettingsOnly); the libraries store nothing.
        for (name, text) in try librarySources() { XCTAssertFalse(text.contains("UserDefaults"), name) }
    }

    func testNoPrintOrNSLog() throws {
        for (name, text) in try allSources() {
            XCTAssertNil(text.range(of: #"(^|[^A-Za-z.])(print|NSLog|debugPrint|dump)\("#, options: .regularExpression), name)
        }
    }

    func testCoachNeverUsesTheHostFileLog() throws {
        for (name, text) in try swiftFiles(in: Self.hostAppURL, prefix: "Coach") {
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
                       "frames", "cues", "status", "enabled", "indicator"]
        let re = try NSRegularExpression(pattern: #"\\\(([^)]*)\)?[^)]*, privacy: \.public\)"#)
        for (name, text) in try allSources() {
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let arg = (text as NSString).substring(with: m.range(at: 1))
                XCTAssertTrue(allowed.contains { arg.lowercased().contains($0.lowercased()) }, "\(name): public log of \(arg)")
            }
        }
    }

    /// The coach keeps nothing: no daily summary, history, recap or stats, in memory or on disk.
    func testNoSummaryOrHistory() throws {
        let re = #"(?i)\b(summary|summaries|history|recap|recaps|daily|stats|statistics|journal|archive)\b"#
        for (name, text) in try allSources() {
            // Code and comments only: user-facing copy may promise "no stats, no recaps".
            let code = text.replacingOccurrences(of: #""(?:[^"\\\n]|\\.)*""#, with: "\"\"", options: .regularExpression)
            XCTAssertNil(code.range(of: re, options: .regularExpression), "\(name) mentions a stored-history concept")
        }
    }

    /// A host's only defaults are coach settings, never call data.
    func testHostDefaultsAreSettingsOnly() throws {
        let allowed: Set<String> = ["coach.enabled", "coach.anyApp", "coach.allowlist", "coach.onboarded"]
        let re = try NSRegularExpression(pattern: #""(coach\.[A-Za-z.]+)""#)
        for (name, text) in try swiftFiles(in: Self.hostAppURL, prefix: "Coach") {
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let key = (text as NSString).substring(with: m.range(at: 1))
                XCTAssertTrue(allowed.contains(key), "\(name) uses defaults key \(key)")
            }
            XCTAssertFalse(text.contains("overrideURL"), "\(name): the app ships the built-in generic config only")
        }
    }

    /// No eval fixtures, recordings or example transcripts in the package sources or tests: tests
    /// generate their audio (Synthetic.swift) and use content-free tokens for text.
    func testNoDataFixtures() throws {
        let okNames: Set<String> = ["README.md", ".gitignore", "LICENSE"]
        for dir in [Self.sourcesURL, Self.testsURL] {
            let e = try XCTUnwrap(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil))
            for case let url as URL in e {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                let ok = ["swift", "c", "h"].contains(url.pathExtension) || okNames.contains(url.lastPathComponent)
                XCTAssertTrue(ok, "unexpected data file \(url.lastPathComponent)")
            }
        }
    }

    /// The call trigger reads Core Audio running state only: nothing reads window titles (which would
    /// also need Screen Recording permission), and the coach service drives the trigger from audio.
    func testTriggerNeverUsesWindowTitles() throws {
        for (name, text) in try allSources() {
            XCTAssertFalse(text.contains("kCGWindowName"), "\(name) reads window titles")
            XCTAssertNil(text.range(of: #"\.windows\b.*\.title|\.title\b.*\.windows"#, options: .regularExpression),
                         "\(name) reads window titles")
        }
        let service = try librarySources().first { $0.0 == "CoachService.swift" }
        let text = try XCTUnwrap(service).1
        XCTAssertTrue(text.contains("AudioActivitySignal("), "CoachService must drive the trigger from Core Audio")
        XCTAssertFalse(text.contains("WindowTitleSignal"), "CoachService must not use window titles")
    }

    /// Library sources and tests are generic: this is a public repository.
    func testNoSecretsOrPersonalReferences() throws {
        let banned = [#"sk-[A-Za-z0-9]{20,}"#, #"(?i)\bscott\b"#, #"(?i)\bCTO\b"#, #"(?i)VP Comms"#, #"(?i)plaud"#]
        let tests = try ["ListenMoreCoreTests", "ListenMoreMacTests", "ListenMoreLiveTests"]
            .flatMap { try swiftFiles(in: Self.testsURL.appendingPathComponent($0)) }
        for (name, text) in try librarySources() + tests where name != "PrivacyGuardTests.swift" {
            for b in banned { XCTAssertNil(text.range(of: b, options: .regularExpression), "\(name) matches \(b)") }
        }
        for (name, text) in try appSources() {
            XCTAssertNil(text.range(of: banned[0], options: .regularExpression), "\(name) matches a key pattern")
        }
    }
}
