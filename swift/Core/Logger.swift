import Foundation

/// Where the app writes. Injected everywhere: tests ALWAYS pass a temp dir (the Python
/// suite once wrote fixture lines into the live log; this port makes that impossible).
public struct AppPaths: Sendable, Equatable {
    public let logFile: URL
    public let stateDir: URL
    public init(logFile: URL, stateDir: URL) { self.logFile = logFile; self.stateDir = stateDir }

    /// The live log and state, named by the identity's `fileStem`: `~/Library/Logs/MeetingCardSwift.log`
    /// and `~/Library/Application Support/MeetingCardSwift` for the shipping app.
    public static func production(for id: AppIdentity) -> AppPaths { named(id.fileStem) }

    /// `--fixture` runs (renders, eyeball checks): own log + state, never the live ones.
    public static func fixture(for id: AppIdentity) -> AppPaths { named(id.fileStem + "-fixture") }

    /// The default folder for saved transcripts (Save transcripts, off by default; the user can pick
    /// another): `~/Library/Application Support/MeetingCard/Transcripts` for the shipping app.
    public static func transcripts(for id: AppIdentity) -> URL {
        URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/\(id.transcriptsDirName)/Transcripts", isDirectory: true)
    }

    public static func speakerProfiles(for id: AppIdentity) -> URL {
        transcripts(for: id).deletingLastPathComponent().appendingPathComponent("VoiceProfiles", isDirectory: true)
    }

    public static func forRun(fixture: Bool, identity: AppIdentity) -> AppPaths {
        fixture ? AppPaths.fixture(for: identity) : AppPaths.production(for: identity)
    }

    static func named(_ name: String) -> AppPaths {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        return AppPaths(logFile: home.appendingPathComponent("Library/Logs/\(name).log"),
                        stateDir: home.appendingPathComponent("Library/Application Support/\(name)"))
    }

    public static func temporary() -> AppPaths {
        let d = FileManager.default.temporaryDirectory.appendingPathComponent("mcs-\(UUID().uuidString)")
        return AppPaths(logFile: d.appendingPathComponent("MeetingCardSwift.log"),
                        stateDir: d.appendingPathComponent("state"))
    }

    /// True when running inside an XCTest bundle.
    static var underTest: Bool { NSClassFromString("XCTestCase") != nil }

    /// Hygiene guard: a test process may never write any identity's production log/state paths.
    func allowed() -> Bool {
        guard AppPaths.underTest else { return true }
        return ![AppIdentity.release, .test, .current].map { AppPaths.production(for: $0) }
            .contains { logFile == $0.logFile || stateDir == $0.stateDir }
    }
}

/// 12-hour timestamped lines, explicit UTF-8, appended; mirrored to stderr.
public final class Logger: @unchecked Sendable {
    public let paths: AppPaths
    private let lock = NSLock()
    private let fmt: DateFormatter
    public let mirrorToStderr: Bool
    public private(set) var refused = 0

    public init(paths: AppPaths, mirrorToStderr: Bool = true) {
        self.paths = paths
        self.mirrorToStderr = mirrorToStderr
        fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd hh:mm:ss a"
    }

    public func callAsFunction(_ msg: String) { log(msg) }

    public func log(_ msg: String) {
        lock.lock(); defer { lock.unlock() }
        let line = "\(fmt.string(from: Date())) \(msg)\n"
        let data = Data(line.utf8)
        if mirrorToStderr { FileHandle.standardError.write(data) }
        guard paths.allowed() else { refused += 1; return }
        let fm = FileManager.default
        try? fm.createDirectory(at: paths.logFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let h = try? FileHandle(forWritingTo: paths.logFile) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: paths.logFile)
        }
    }
}

/// last-card.json: {windowNumber, eventId, start, pid} for the selftest / live-test tooling.
public struct StateWriter: Sendable {
    public let paths: AppPaths
    public init(paths: AppPaths) { self.paths = paths }

    @discardableResult
    public func write(windowNumber: Int, ev: Event, pid: Int32 = ProcessInfo.processInfo.processIdentifier) -> Bool {
        guard paths.allowed() else { return false }
        let obj: [String: Any] = ["windowNumber": windowNumber, "eventId": ev.id ?? NSNull(),
                                  "start": ev.start?.dateTime ?? NSNull(), "pid": Int(pid)]
        do {
            try FileManager.default.createDirectory(at: paths.stateDir, withIntermediateDirectories: true)
            let d = try JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
            try d.write(to: paths.stateDir.appendingPathComponent("last-card.json"), options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
