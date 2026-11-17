import XCTest

/// The coach's audio debug readout exists only in the `--test-id` build: its file and every
/// reference to it compile only under MEETINGCARD_TEST_ID, which only `build.sh --test-id` defines.
/// CI also checks the built binaries (the shipping app has no readout, the test build has it).
final class DebugReadoutTests: XCTestCase {
    static let swiftDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    static let flag = "MEETINGCARD_TEST_ID"

    func read(_ path: String) throws -> String {
        try String(contentsOf: Self.swiftDir.appendingPathComponent(path), encoding: .utf8)
    }

    func testReadoutFileCompilesOnlyUnderTheTestIdFlag() throws {
        let lines = try read("App/CoachDebugReadout.swift").components(separatedBy: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        XCTAssertEqual(lines.first, "#if \(Self.flag)")
        XCTAssertEqual(lines.last, "#endif")
        XCTAssertEqual(lines.filter { $0.hasPrefix("#if") }.count, 1)
        XCTAssertEqual(lines.filter { $0.hasPrefix("#endif") }.count, 1)
        XCTAssertFalse(lines.contains { $0.hasPrefix("#else") })
    }

    func testEveryOtherReferenceIsInsideTheFlag() throws {
        let app = Self.swiftDir.appendingPathComponent("App")
        let files = try FileManager.default.contentsOfDirectory(atPath: app.path).filter { $0.hasSuffix(".swift") }
        var references = 0
        for file in files where file != "CoachDebugReadout.swift" {
            var inside = false
            for line in try read("App/\(file)").components(separatedBy: "\n") {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t == "#if \(Self.flag)" { inside = true; continue }
                if inside && t.hasPrefix("#else") { XCTFail("\(file): no #else branch for the readout") }
                if t == "#endif" { inside = false; continue }
                if line.contains("CoachDebugReadout") {
                    references += 1
                    XCTAssertTrue(inside, "\(file): \(t)")
                }
            }
        }
        XCTAssertEqual(references, 2, "attached in makeService, offered in the coach menu")
    }

    func testOnlyTheTestIdBuildDefinesTheFlag() throws {
        XCTAssertFalse(try read("project.yml").contains(Self.flag), "the shipping build never defines it")
        let script = try read("scripts/build.sh")
        let code = script.components(separatedBy: "\n").filter { !$0.hasPrefix("#") }.joined(separator: "\n")
        let block = try XCTUnwrap(code.components(separatedBy: "if (( TEST_ID )); then").dropFirst().first?
            .components(separatedBy: "\nfi\n").first)
        XCTAssertTrue(block.contains("'SWIFT_ACTIVE_COMPILATION_CONDITIONS=$(inherited) \(Self.flag)'"))
        XCTAssertEqual(code.components(separatedBy: Self.flag).count - 1, 1, "defined in the --test-id block only")
    }

    /// Shows, keeps nothing.
    func testReadoutWritesNothing() throws {
        let src = try read("App/CoachDebugReadout.swift")
        for banned in ["write(to:", "FileManager", "UserDefaults", "Logger(", "Log.", "os_log", "NSLog", "print(",
                       "createFile", "FileHandle", "NSPasteboard"] {
            XCTAssertFalse(src.contains(banned), banned)
        }
    }
}
