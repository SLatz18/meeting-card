import Foundation

/// Outcome of one subprocess run. stdout/stderr are raw bytes; decoding is explicit UTF-8.
public enum RunResult: Sendable {
    case exited(status: Int32, stdout: Data, stderr: Data)
    case timedOut
    case launchFailed(String)
}

public protocol GwsRunner: Sendable {
    func run(executable: String, args: [String], env: [String: String], timeout: TimeInterval) -> RunResult
}

/// gws reported it deleted credentials; caller must stop ALL gws calls.
public struct GwsFatal: Error, Sendable { public let stderr: String }

/// Port of gws.py: stdout-only JSON, explicit UTF-8, forced HOME/USER/LOGNAME/PATH, never
/// a stripped env, ids/counts/reasons only in logs (never event JSON).
public struct Gws: Sendable {
    public static let destructive = "removing undecryptable credentials"
    /// Where gws is looked for, in order: `$MEETING_CARD_GWS`, then the usual install spots
    /// (`~/.local/bin`, Homebrew on Apple Silicon and Intel, `cargo install`). An app launched from
    /// Finder gets a minimal env, so the candidate list is what normally resolves it.
    public static func candidatePaths(env: [String: String], home: String) -> [String] {
        var c: [String] = []
        if let o = env["MEETING_CARD_GWS"], o.hasPrefix("/") { c.append(o) }   // absolute only: never a cwd lookup
        c += [home + "/.local/bin/gws", "/opt/homebrew/bin/gws", "/usr/local/bin/gws", home + "/.cargo/bin/gws"]
        return c
    }

    /// First executable candidate; none found = `~/.local/bin/gws` (each poll then logs a launch failure).
    public static func resolvePath(env: [String: String] = ProcessInfo.processInfo.environment,
                                   home: String = homeDir(),
                                   isExecutable: (String) -> Bool = Gws.isExecutableFile) -> String {
        candidatePaths(env: env, home: home).first(where: isExecutable) ?? home + "/.local/bin/gws"
    }

    /// An executable regular file (a directory is "executable" to FileManager, and would mask later candidates).
    public static func isExecutableFile(_ p: String) -> Bool {
        var dir: ObjCBool = false
        return FileManager.default.fileExists(atPath: p, isDirectory: &dir) && !dir.boolValue
            && FileManager.default.isExecutableFile(atPath: p)
    }

    public static var defaultPath: String { resolvePath() }

    public let path: String
    public let runner: GwsRunner
    public let log: @Sendable (String) -> Void

    public init(path: String = Gws.defaultPath, runner: GwsRunner = ProcessGwsRunner(),
                log: @escaping @Sendable (String) -> Void) {
        self.path = path; self.runner = runner; self.log = log
    }

    static func passwd() -> (dir: String, name: String) {
        guard let pw = getpwuid(getuid()) else { return (NSHomeDirectory(), NSUserName()) }
        return (String(cString: pw.pointee.pw_dir), String(cString: pw.pointee.pw_name))
    }
    public static func homeDir() -> String { passwd().dir }

    /// The user's env PLUS forced HOME/USER/LOGNAME (getpwuid) and PATH. A stripped env
    /// made gws wipe its credentials once (2026-10-06); never call gws without this.
    public static func buildEnv(_ base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        let pw = passwd()
        env["HOME"] = pw.dir
        env["USER"] = pw.name
        env["LOGNAME"] = pw.name
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:\(pw.dir)/.local/bin"
        return env
    }

    static func utc(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return f.string(from: d)
    }

    static func json(_ obj: [String: Any]) -> String {
        let d = try! JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys])
        return String(decoding: d, as: UTF8.self)
    }

    /// Events in now-10min .. now+2h, or nil on any failure. Throws GwsFatal on the
    /// credential-deletion message. A malformed item is skipped (id logged), not a poll failure.
    public func fetch(now: Date = Date()) throws -> [Event]? {
        let params: [String: Any] = [
            "calendarId": "primary",
            "timeMin": Gws.utc(now.addingTimeInterval(-10 * 60)),
            "timeMax": Gws.utc(now.addingTimeInterval(2 * 3600)),
            "singleEvents": true,
            "orderBy": "startTime",
        ]
        guard let (obj, _) = try run(["calendar", "events", "list", "--params", Gws.json(params)], timeout: 45) else {
            return nil
        }
        guard let dict = obj as? [String: Any], let items = dict["items"] as? [Any] else {
            log("ERROR gws response has no items list")
            return nil
        }
        var out: [Event] = []
        for (i, item) in items.enumerated() {
            guard JSONSerialization.isValidJSONObject(item),
                  let d = try? JSONSerialization.data(withJSONObject: item),
                  let ev = try? Event.decode(d) else {
                let id = (item as? [String: Any])?["id"] as? String ?? "#\(i)"
                log("ERROR skipping malformed event \(id)")
                continue
            }
            out.append(ev)
        }
        return out
    }

    /// Fresh copy of ONE event, or nil on any failure (incl. 404/410/timeout). READ-ONLY.
    public func getEvent(_ eventId: String?, timeout: TimeInterval = 8) throws -> Event? {
        guard let eventId, !eventId.isEmpty else {
            log("ERROR get_event: empty event id")
            return nil
        }
        let params: [String: Any] = ["calendarId": "primary", "eventId": eventId]
        guard let (obj, data) = try run(["calendar", "events", "get", "--params", Gws.json(params)], timeout: timeout) else {
            return nil
        }
        // An empty/odd eventId silently returns a LIST response; accept only the exact event.
        guard let dict = obj as? [String: Any], dict["kind"] as? String == "calendar#event",
              dict["id"] as? String == eventId, let ev = try? Event.decode(data) else {
            log("ERROR get_event \(eventId): unexpected response shape")
            return nil
        }
        return ev
    }

    /// The one gws subprocess path. Parsed stdout JSON (+ raw bytes) or nil.
    func run(_ args: [String], timeout: TimeInterval) throws -> (Any, Data)? {
        let r = runner.run(executable: path, args: args, env: Gws.buildEnv(), timeout: timeout)
        switch r {
        case .launchFailed(let msg):
            log("ERROR gws exec failed: \(String(msg.prefix(200)))")
            return nil
        case .timedOut:
            log("ERROR gws timed out after \(Int(timeout))s")
            return nil
        case let .exited(status, rawStdout, stderrData):
            // Python decodes with errors="replace": one bad byte must not fail the whole poll.
            let stdout = Data(String(decoding: rawStdout, as: UTF8.self).utf8)
            let stderr = String(decoding: stderrData, as: UTF8.self)
            if stderr.contains(Gws.destructive) {
                log("ERROR gws reported credential deletion; stopping polling: "
                    + String(stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)))
                throw GwsFatal(stderr: stderr)
            }
            if status != 0 {
                log("ERROR gws rc=\(status) stderr="
                    + String(stderr.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500)))
                return nil
            }
            guard let obj = try? JSONSerialization.jsonObject(with: stdout, options: [.fragmentsAllowed]) else {
                // Never echo stdout: it carries attendee emails and descriptions.
                log("ERROR gws stdout not JSON (\(stdout.count) bytes)")
                return nil
            }
            return (obj, stdout)
        }
    }
}

/// Production runner: Process with both pipes drained concurrently (no 64 KB pipe
/// deadlock), killed on timeout.
public struct ProcessGwsRunner: GwsRunner {
    public init() {}

    public func run(executable: String, args: [String], env: [String: String], timeout: TimeInterval) -> RunResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = args
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        do { try p.run() } catch {
            return .launchFailed("\(type(of: error)): \(error.localizedDescription)")
        }
        let deadline = DispatchTime.now() + timeout
        let box = Box()
        let group = DispatchGroup()
        // Incremental reads: whatever arrives is kept even if a descendant holds the pipe open.
        for (h, isOut) in [(out.fileHandleForReading, true), (err.fileHandleForReading, false)] {
            group.enter()
            h.readabilityHandler = { fh in
                let d = fh.availableData
                if d.isEmpty {
                    fh.readabilityHandler = nil
                    if box.eof(isOut) { group.leave() }
                } else {
                    box.append(d, isOut)
                }
            }
        }
        func stopReading() {
            out.fileHandleForReading.readabilityHandler = nil
            err.fileHandleForReading.readabilityHandler = nil
        }
        // The overall timeout is authoritative: exit + drain must both fit inside it.
        if done.wait(timeout: deadline) == .timedOut {
            p.terminate()
            if done.wait(timeout: .now() + 0.5) == .timedOut {
                kill(p.processIdentifier, SIGKILL)
                _ = done.wait(timeout: .now() + 0.5)
            }
            _ = group.wait(timeout: .now() + 0.2)
            stopReading()
            return .timedOut
        }
        // Child exited: drain until EOF or the deadline (plus a short grace), keep what was read.
        _ = group.wait(timeout: max(deadline, .now() + 0.2))
        stopReading()
        let (o, e) = box.get()
        return .exited(status: p.terminationStatus, stdout: o, stderr: e)
    }

    final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var o = Data(), e = Data()
        private var eofO = false, eofE = false
        func append(_ d: Data, _ isOut: Bool) { lock.lock(); if isOut { o.append(d) } else { e.append(d) }; lock.unlock() }
        /// True only the first time a stream hits EOF (exactly one group.leave per stream).
        func eof(_ isOut: Bool) -> Bool {
            lock.lock(); defer { lock.unlock() }
            if isOut { if eofO { return false }; eofO = true } else { if eofE { return false }; eofE = true }
            return true
        }
        func get() -> (Data, Data) { lock.lock(); defer { lock.unlock() }; return (o, e) }
    }
}
