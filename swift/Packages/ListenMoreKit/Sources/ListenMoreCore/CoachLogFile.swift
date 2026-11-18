import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The coach diagnostics file: local only, short-lived, small. It takes `CoachLogEntry` values and
/// nothing else (no string, no data), so what it can write is what `CoachLogEvent` can say.
///
/// - Size: when a write would take the file past `maxBytes`, it becomes `<name>.1` (replacing the
///   previous `.1`) and a new file starts. That is at most two files, about 2 x `maxBytes`. If the
///   rotation itself fails, the file is cut instead, so it can never grow past the cap.
/// - Age: lines older than `maxAge` are dropped, from both files, when the file is first written
///   and then at most once an hour, by writing a temporary file and renaming it over the original.
///   An old file left with no recent lines is deleted.
/// - Access: created readable by the user only, at creation (not by a later chmod). Lines are appended
///   with `O_APPEND`; rotation and pruning hold an exclusive `flock` on `<name>.lock`, and appends a shared
///   one, so two instances cannot interleave a rotation with a write.
/// - Threads: entries are written on a private serial queue, never on the caller's thread (the main
///   thread logs). `flush()` waits for what is queued (quit, tests). A backlog past `maxPending` drops
///   entries and says so with `log.dropped`.
public final class CoachLogFile: CoachLogSink, @unchecked Sendable {
    public static let defaultMaxBytes = 1_000_000
    public static let defaultMaxAge: TimeInterval = 3 * 24 * 3600
    public static let pruneInterval: TimeInterval = 3600
    public static let defaultMaxPending = 5000

    /// The few file operations a failure can be injected into (tests).
    public struct Operations: Sendable {
        public var rename: @Sendable (_ from: URL, _ to: URL) -> Bool
        public var remove: @Sendable (_ url: URL) -> Bool

        public static let system = Operations(
            rename: { from, to in Darwin_or_Glibc_rename(from.path, to.path) == 0 },
            remove: { url in unlink(url.path) == 0 || errno == ENOENT })

        public init(rename: @escaping @Sendable (URL, URL) -> Bool, remove: @escaping @Sendable (URL) -> Bool) {
            self.rename = rename
            self.remove = remove
        }
    }

    public let url: URL
    public let maxBytes: Int
    public let maxAge: TimeInterval
    public let maxPending: Int
    private let now: @Sendable () -> Date
    private let operations: Operations
    private let queue = DispatchQueue(label: "com.listenmore.coachlog", qos: .utility)
    private let state = NSLock()
    private var pending = 0
    private var dropped = 0
    private var lastPrune: Date?

    public init(url: URL, maxBytes: Int = CoachLogFile.defaultMaxBytes, maxAge: TimeInterval = CoachLogFile.defaultMaxAge,
                maxPending: Int = CoachLogFile.defaultMaxPending, operations: Operations = .system,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.maxBytes = maxBytes
        self.maxAge = maxAge
        self.maxPending = maxPending
        self.operations = operations
        self.now = now
    }

    /// The one older file kept when the current one fills up.
    public var rotatedURL: URL { url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".1") }
    private var lockURL: URL { url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".lock") }

    /// Entries dropped for a full backlog and not yet reported.
    public var droppedCount: Int { state.withLock { dropped } }

    public func write(_ entry: CoachLogEntry) {
        let accepted: Bool = state.withLock {
            guard pending < maxPending else {
                dropped += 1
                return false
            }
            pending += 1
            return true
        }
        guard accepted else { return }
        queue.async { [self] in
            append(entry)
            let owed: Int = state.withLock {
                pending -= 1
                defer { if pending == 0 { dropped = 0 } }
                return pending == 0 ? dropped : 0
            }
            if owed > 0 { append(CoachLogEntry(date: now(), event: .logDropped(count: owed))) }
        }
    }

    /// Waits until everything queued so far has been written.
    public func flush() {
        queue.sync {}
    }

    /// Drops lines older than `maxAge` from both files now.
    public func prune() {
        queue.sync { withLock(exclusive: true) { pruneNow() } }
    }

    // MARK: on the queue

    private func append(_ entry: CoachLogEntry) {
        let data = Data((entry.line + "\n").utf8)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let t = now()
        if lastPrune.map({ t.timeIntervalSince($0) >= Self.pruneInterval }) ?? true {
            withLock(exclusive: true) { pruneNow() }
        }
        if size(of: url) + data.count > maxBytes, size(of: url) > 0 {
            withLock(exclusive: true) { rotate(needed: data.count) }
        }
        withLock(exclusive: false) { appendBytes(data) }
    }

    /// `O_APPEND`, mode 0600 at creation.
    private func appendBytes(_ data: Data) {
        let fd = open(url.path, O_WRONLY | O_APPEND | O_CREAT, 0o600)
        guard fd >= 0 else { return }
        defer { close(fd) }
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = posixWrite(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 { break }
                offset += n
            }
        }
    }

    /// Moves the full file to `.1`. If that fails the file is removed, and if that fails too it is truncated, so the cap
    /// holds whatever the file system does.
    private func rotate(needed: Int) {
        guard size(of: url) + needed > maxBytes, size(of: url) > 0 else { return }
        if operations.rename(url, rotatedURL) { return }
        if operations.remove(url) { return }
        let fd = open(url.path, O_WRONLY | O_TRUNC)
        if fd >= 0 { close(fd) }
    }

    private func pruneNow() {
        lastPrune = now()
        let cutoff = now().addingTimeInterval(-maxAge)
        for file in [rotatedURL, url] { drop(linesBefore: cutoff, in: file) }
    }

    /// Writes the kept lines to a temporary file (0600 from creation) and renames it over the original.
    private func drop(linesBefore cutoff: Date, in file: URL) {
        guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let kept = lines.filter { (CoachLogEntry.date(ofLine: $0) ?? .distantPast) >= cutoff }
        guard kept.count != lines.count else { return }
        if kept.isEmpty {
            _ = operations.remove(file)
            return
        }
        let temp = file.deletingLastPathComponent().appendingPathComponent(file.lastPathComponent + ".tmp")
        _ = unlink(temp.path)
        let fd = open(temp.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard fd >= 0 else { return }
        let body = Data((kept.joined(separator: "\n") + "\n").utf8)
        let ok: Bool = body.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = posixWrite(fd, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if n <= 0 { return false }
                offset += n
            }
            return true
        }
        close(fd)
        if ok, operations.rename(temp, file) { return }
        _ = unlink(temp.path)
    }

    private func size(of file: URL) -> Int {
        var st = stat()
        return stat(file.path, &st) == 0 ? Int(st.st_size) : 0
    }

    /// Holds `flock` on the lock file around `body` (exclusive for rotation and pruning, shared for appends).
    private func withLock(exclusive: Bool, _ body: () -> Void) {
        let fd = open(lockURL.path, O_RDWR | O_CREAT, 0o600)
        guard fd >= 0 else { return body() }
        flock(fd, exclusive ? LOCK_EX : LOCK_SH)
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        body()
    }

    /// What "Show Coach Log" reveals: the file, or its folder before anything has been written.
    public static func revealTarget(fileExists: Bool, file: URL) -> URL {
        fileExists ? file : file.deletingLastPathComponent()
    }
}

#if canImport(Darwin)
private func posixWrite(_ fd: Int32, _ p: UnsafeRawPointer, _ n: Int) -> Int { Darwin.write(fd, p, n) }
#else
private func posixWrite(_ fd: Int32, _ p: UnsafeRawPointer, _ n: Int) -> Int { Glibc.write(fd, p, n) }
#endif

#if canImport(Darwin)
private func Darwin_or_Glibc_rename(_ a: String, _ b: String) -> Int32 { Darwin.rename(a, b) }
#else
private func Darwin_or_Glibc_rename(_ a: String, _ b: String) -> Int32 { Glibc.rename(a, b) }
#endif
