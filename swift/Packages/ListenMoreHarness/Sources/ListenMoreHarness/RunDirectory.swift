import Foundation
#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

/// A run's private temp directory (mode 0700): the only place a scenario may write, wiped at the end.
/// Named `lm-harness-<pid>-<uuid>`, so a later run can tell a folder left by a crash from a live one.
public struct RunDirectory {
    public let url: URL

    public static func create() throws -> RunDirectory {
        let name = "lm-harness-\(getpid())-\(UUID().uuidString)"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        return RunDirectory(url: url)
    }

    /// A run folder younger than this is never swept. A harness in another PID namespace (a container
    /// sharing /tmp) can look dead from here; each scenario has its own folder and the longest runs
    /// about two minutes live, so a folder untouched for five minutes belongs to no running scenario.
    public static let sweepMinAgeS: TimeInterval = 300

    /// Removes run folders whose harness process is gone (a crash skipped their wipe) and that haven't
    /// changed for `minAge` seconds. Only names in the exact `lm-harness-<pid>-<uuid>` form are touched;
    /// a folder of a running harness is kept. Returns how many were removed.
    @discardableResult
    public static func sweepStale(in dir: URL = FileManager.default.temporaryDirectory, minAge: TimeInterval = sweepMinAgeS,
                                  now: Date = Date()) -> Int {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return 0 }
        var removed = 0
        for name in names {
            guard let pid = ownerPid(name), !processAlive(pid) else { continue }
            let url = dir.appendingPathComponent(name)
            // A directory's mtime changes when an entry in it is added or removed: here when the scenario
            // creates its transcripts folder (writes inside that folder don't touch it), so it reads as
            // about when the scenario started.
            guard let modified = (try? fm.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date,
                  now.timeIntervalSince(modified) >= minAge else { continue }
            if (try? fm.removeItem(at: url)) != nil { removed += 1 }
        }
        return removed
    }

    /// The pid in a run folder's name, or nil if the name isn't a run folder's.
    static func ownerPid(_ name: String) -> Int32? {
        guard let m = name.range(of: #"^lm-harness-([0-9]{1,10})-[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}$"#,
                                 options: .regularExpression), m == name.startIndex..<name.endIndex else { return nil }
        return Int32(name.dropFirst("lm-harness-".count).prefix { $0.isNumber })
    }

    static func processAlive(_ pid: Int32) -> Bool {
        pid == getpid() || kill(pid, 0) == 0 || errno == EPERM
    }

    /// Removes the directory; true when it's gone.
    @discardableResult
    public func wipe() -> Bool {
        try? FileManager.default.removeItem(at: url)
        return !FileManager.default.fileExists(atPath: url.path)
    }
}

/// Looks for audio written to disk outside the run directory: files created or modified since `start`
/// under the given roots, with an audio extension or an audio file signature.
public struct DiskAudit {
    public static let audioExtensions: Set<String> = ["wav", "wave", "pcm", "raw", "mp3", "m4a", "aac", "flac", "ogg", "oga",
                                                      "opus", "caf", "aif", "aiff", "aifc", "webm", "mp4", "amr", "au", "snd"]
    static let skipDirectories: Set<String> = [".git", ".build", ".swiftpm", "node_modules", "build", "DerivedData"]

    public let roots: [URL]
    public let exclude: URL
    public let start: Date

    public init(roots: [URL], exclude: URL, start: Date = Date()) {
        self.roots = roots
        self.exclude = exclude
        self.start = start.addingTimeInterval(-1)
    }

    /// Roots worth watching: the working directory's repository (or the directory itself), the temp
    /// directory and the home directory's top level.
    public static func defaultRoots() -> [URL] {
        let fm = FileManager.default
        var roots: [URL] = [fm.temporaryDirectory]
        var dir = URL(fileURLWithPath: fm.currentDirectoryPath)
        var repo: URL?
        for _ in 0..<8 {
            if fm.fileExists(atPath: dir.appendingPathComponent(".git").path) { repo = dir; break }
            dir.deleteLastPathComponent()
        }
        roots.append(repo ?? URL(fileURLWithPath: fm.currentDirectoryPath))
        roots.append(fm.homeDirectoryForCurrentUser)
        return roots
    }

    public func violations(maxDepth: Int = 6) -> [String] {
        var out: Set<String> = []
        let skip = exclude.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        for root in roots {
            let rootPath = root.resolvingSymlinksInPath().path
            walk(URL(fileURLWithPath: rootPath), depth: 0, maxDepth: rootPath == home ? 1 : maxDepth, skip: skip, into: &out)
        }
        return out.sorted()
    }

    private func walk(_ dir: URL, depth: Int, maxDepth: Int, skip: String, into out: inout Set<String>) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names {
            let url = dir.appendingPathComponent(name)
            let path = url.path
            if path == skip || path.hasPrefix(skip + "/") { continue }
            guard let attrs = try? fm.attributesOfItem(atPath: path) else { continue }
            let type = attrs[.type] as? FileAttributeType
            if type == .typeDirectory {
                if depth < maxDepth && !Self.skipDirectories.contains(name) {
                    walk(url, depth: depth + 1, maxDepth: maxDepth, skip: skip, into: &out)
                }
            } else if type == .typeRegular, let modified = attrs[.modificationDate] as? Date, modified >= start {
                if Self.audioExtensions.contains(url.pathExtension.lowercased()) || Self.hasAudioSignature(url) { out.insert(path) }
            }
        }
    }

    /// RIFF/WAVE, AIFF, CAF, FLAC, Ogg, MP3 with an ID3 tag, MP4/M4A (`ftyp`).
    public static func hasAudioSignature(_ url: URL) -> Bool {
        guard let h = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? h.close() }
        guard let d = try? h.read(upToCount: 12), d.count >= 4 else { return false }
        return isAudioHeader(d)
    }

    public static func isAudioHeader(_ d: Data) -> Bool {
        let b = [UInt8](d.prefix(12))
        guard b.count >= 4 else { return false }
        func ascii(_ s: String, at i: Int) -> Bool {
            let u = Array(s.utf8)
            return b.count >= i + u.count && Array(b[i..<(i + u.count)]) == u
        }
        if ascii("RIFF", at: 0) && (ascii("WAVE", at: 8) || b.count < 12) { return true }
        if ascii("FORM", at: 0) || ascii("caff", at: 0) || ascii("fLaC", at: 0) || ascii("OggS", at: 0) || ascii("ID3", at: 0) { return true }
        return ascii("ftyp", at: 4)
    }
}
