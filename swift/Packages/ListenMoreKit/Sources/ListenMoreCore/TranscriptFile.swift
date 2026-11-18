import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// The coach's only disk writer: the opt-in saved transcript, text only, in the folder the user chose
/// (the call's note, the call's hidden spool file beside it while the call runs, and with that
/// option on, one line appended to the day's note). Replacing a file writes a hidden temporary
/// sibling in the same folder, syncs it and renames it over the target, so a reader sees the old text
/// or the new, never a mix, and nothing is staged in another folder. Creating a note does the same
/// but never replaces a file that appeared meanwhile. Appends are synced before they return. Files
/// are readable by the user only and a symlink at the target is never followed. Audio has no path
/// here. PrivacyGuardTests checks that no other coach source writes to disk.
public final class FileTranscriptStore: TranscriptStore {
    /// The host picks the folder (MeetingCard: per app identity, or the user's choice).
    public init() {}

    public func prepare(folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    public func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func isDirectory(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Replaces the file's contents with `text`, atomically.
    public func write(_ text: String, to url: URL) throws {
        let temp = try syncedTemp(text, beside: url)
        guard posixRename(temp.path, url.path) == 0 else {
            let e = posixError()
            _ = posixUnlink(temp.path)
            throw e
        }
        posixSyncDirectory(url.deletingLastPathComponent().path)
    }

    /// Writes a new file atomically; throws `TranscriptStoreError.exists` (and writes nothing) if
    /// anything is already at `url`.
    public func create(_ text: String, at url: URL) throws {
        let temp = try syncedTemp(text, beside: url)
        let r = posixRenameExclusive(temp.path, url.path)
        let e = errno
        if r != 0 { _ = posixUnlink(temp.path) }
        guard r == 0 else {
            if e == EEXIST { throw TranscriptStoreError.exists }
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(e))
        }
        posixSyncDirectory(url.deletingLastPathComponent().path)
    }

    /// Adds `text` at the end of the file (created if missing) and syncs it.
    public func append(_ text: String, to url: URL) throws {
        let isNew = !exists(url)
        let fd = try posixOpen(url.path, O_WRONLY | O_APPEND | O_CREAT | O_NOFOLLOW | O_CLOEXEC)
        do {
            try posixWriteAll(fd, Data(text.utf8))
            try posixSync(fd)
        } catch {
            _ = posixClose(fd)
            throw error
        }
        guard posixClose(fd) == 0 else { throw posixError() }
        if isNew { posixSyncDirectory(url.deletingLastPathComponent().path) }
    }

    public func read(_ url: URL) -> String? {
        guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func head(_ url: URL, bytes: Int) -> String? {
        guard let h = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? h.close() }
        guard let data = try? h.read(upToCount: bytes) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    public func contents(of folder: URL) -> [URL] {
        (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    }

    public func modified(_ url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    public func remove(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }

    /// `text`, synced, in a new hidden file next to `url` (Obsidian and Finder skip dot files); a crash
    /// can leave one behind, which recovery removes.
    private func syncedTemp(_ text: String, beside url: URL) throws -> URL {
        let temp = Self.tempSibling(of: url)
        let fd = try posixOpen(temp.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC)
        do {
            try posixWriteAll(fd, Data(text.utf8))
            try posixSync(fd)
        } catch {
            _ = posixClose(fd)
            _ = posixUnlink(temp.path)
            throw error
        }
        guard posixClose(fd) == 0 else {
            let e = posixError()
            _ = posixUnlink(temp.path)
            throw e
        }
        return temp
    }

    static func tempSibling(of url: URL) -> URL {
        url.deletingLastPathComponent().appendingPathComponent(".\(url.lastPathComponent).\(UUID().uuidString)\(tempSuffix)")
    }

    static let tempSuffix = ".mc-tmp"
    /// Bytes a temporary sibling adds to its target's name: two dots, the UUID and the suffix.
    static let tempNameOverhead = 2 + 36 + tempSuffix.utf8.count
}

// File-scope wrappers: inside the store, `write`, `append` and `remove` name its own methods.

private func posixError() -> NSError {
    NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
}

private func posixOpen(_ path: String, _ flags: Int32) throws -> Int32 {
    let fd = open(path, flags, mode_t(0o600))
    guard fd >= 0 else { throw posixError() }
    return fd
}

private func posixClose(_ fd: Int32) -> Int32 {
    close(fd)
}

private func posixUnlink(_ path: String) -> Int32 {
    unlink(path)
}

private func posixRename(_ from: String, _ to: String) -> Int32 {
    renameat(AT_FDCWD, from, AT_FDCWD, to)
}

/// Renames only if nothing is at `to` (errno EEXIST otherwise): RENAME_EXCL on Apple platforms, a
/// hard link then unlink elsewhere or where the volume lacks RENAME_EXCL. A volume with neither
/// (FAT, exFAT, some network shares) claims the name with an empty file created exclusively, then
/// renames over its own placeholder.
private func posixRenameExclusive(_ from: String, _ to: String) -> Int32 {
    #if canImport(Darwin)
    if renamex_np(from, to, UInt32(RENAME_EXCL)) == 0 { return 0 }
    if errno != ENOTSUP && errno != EINVAL { return -1 }
    #endif
    if linkat(AT_FDCWD, from, AT_FDCWD, to, 0) == 0 {
        _ = unlink(from)
        return 0
    }
    guard errno == EPERM || errno == ENOTSUP || errno == EOPNOTSUPP || errno == EMLINK else { return -1 }
    let placeholder = open(to, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
    guard placeholder >= 0 else { return -1 }
    _ = close(placeholder)
    if posixRename(from, to) == 0 { return 0 }
    let e = errno
    _ = unlink(to)
    errno = e
    return -1
}

private func posixWriteAll(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { (buf: UnsafeRawBufferPointer) in
        guard let base = buf.baseAddress else { return }
        var done = 0
        while done < buf.count {
            let n = write(fd, base + done, buf.count - done)
            if n < 0 {
                if errno == EINTR { continue }
                throw posixError()
            }
            done += n
        }
    }
}

/// To stable storage: F_FULLFSYNC on Apple platforms (plain fsync may leave data in the drive's
/// cache there), fsync elsewhere.
private func posixSync(_ fd: Int32) throws {
    #if canImport(Darwin)
    if fcntl(fd, F_FULLFSYNC) == 0 { return }
    #endif
    guard fsync(fd) == 0 else { throw posixError() }
}

/// Makes a new or renamed entry durable. Best effort: some file systems refuse fsync on a directory.
private func posixSyncDirectory(_ path: String) {
    let fd = open(path, O_RDONLY | O_CLOEXEC)
    guard fd >= 0 else { return }
    _ = fsync(fd)
    _ = close(fd)
}
