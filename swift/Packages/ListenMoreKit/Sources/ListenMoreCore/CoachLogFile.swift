import Foundation

/// The coach diagnostics file: local only, short-lived, small. It takes `CoachLogEntry` values and
/// nothing else (no string, no data), so what it can write is what `CoachLogEvent` can say.
///
/// - Size: when a write would take the file past `maxBytes`, it becomes `<name>.1` (replacing the
///   previous `.1`) and a new file starts. That is at most two files, about 2 x `maxBytes`.
/// - Age: lines older than `maxAge` are dropped, from both files, when the file is first written
///   and then at most once an hour. An old file left with no recent lines is deleted.
/// - Access: created readable by the user only.
public final class CoachLogFile: CoachLogSink, @unchecked Sendable {
    public static let defaultMaxBytes = 1_000_000
    public static let defaultMaxAge: TimeInterval = 3 * 24 * 3600
    public static let pruneInterval: TimeInterval = 3600

    public let url: URL
    public let maxBytes: Int
    public let maxAge: TimeInterval
    private let now: @Sendable () -> Date
    private let lock = NSLock()
    private var lastPrune: Date?

    public init(url: URL, maxBytes: Int = CoachLogFile.defaultMaxBytes, maxAge: TimeInterval = CoachLogFile.defaultMaxAge,
                now: @escaping @Sendable () -> Date = { Date() }) {
        self.url = url
        self.maxBytes = maxBytes
        self.maxAge = maxAge
        self.now = now
    }

    /// The one older file kept when the current one fills up.
    public var rotatedURL: URL { url.deletingLastPathComponent().appendingPathComponent(url.lastPathComponent + ".1") }

    public func write(_ entry: CoachLogEntry) {
        lock.lock(); defer { lock.unlock() }
        let data = Data((entry.line + "\n").utf8)
        let fm = FileManager.default
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        pruneIfDue()
        if size(of: url) + data.count > maxBytes, size(of: url) > 0 {
            try? fm.removeItem(at: rotatedURL)
            try? fm.moveItem(at: url, to: rotatedURL)
        }
        if let h = try? FileHandle(forUpdating: url) {
            defer { try? h.close() }
            _ = try? h.seekToEnd()
            try? h.write(contentsOf: data)
        } else {
            try? data.write(to: url)
            try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
    }

    /// Drops lines older than `maxAge` from both files now.
    public func prune() {
        lock.lock(); defer { lock.unlock() }
        pruneNow()
    }

    private func pruneIfDue() {
        let t = now()
        if let last = lastPrune, t.timeIntervalSince(last) < Self.pruneInterval { return }
        pruneNow()
    }

    private func pruneNow() {
        lastPrune = now()
        let cutoff = now().addingTimeInterval(-maxAge)
        for file in [rotatedURL, url] { drop(linesBefore: cutoff, in: file) }
    }

    private func drop(linesBefore cutoff: Date, in file: URL) {
        guard let data = try? Data(contentsOf: file), let text = String(data: data, encoding: .utf8) else { return }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        let kept = lines.filter { (CoachLogEntry.date(ofLine: $0) ?? .distantPast) >= cutoff }
        guard kept.count != lines.count else { return }
        if kept.isEmpty {
            try? FileManager.default.removeItem(at: file)
            return
        }
        try? Data((kept.joined(separator: "\n") + "\n").utf8).write(to: file)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
    }

    private func size(of file: URL) -> Int {
        ((try? FileManager.default.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// What "Show Coach Log" reveals: the file, or its folder before anything has been written.
    public static func revealTarget(fileExists: Bool, file: URL) -> URL {
        fileExists ? file : file.deletingLastPathComponent()
    }
}
