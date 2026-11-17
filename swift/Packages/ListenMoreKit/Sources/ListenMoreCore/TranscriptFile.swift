import Foundation

/// The coach's only disk writer: the opt-in saved transcript, text only, one Markdown file per call
/// in the folder the user chose. Writes go straight to that file (no atomic temp copy elsewhere)
/// and the file is readable by the user only. Audio has no path here. PrivacyGuardTests checks that
/// no other coach source writes to disk.
public final class FileTranscriptStore: TranscriptStore {
    public init() {}

    /// ~/Library/Application Support/MeetingCard/Transcripts
    public static func defaultFolder(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Application Support/MeetingCard/Transcripts", isDirectory: true)
    }

    public func prepare(folder: URL) throws {
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
    }

    public func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    public func write(_ text: String, to url: URL) throws {
        let isNew = !exists(url)
        try Data(text.utf8).write(to: url)
        if isNew { try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
    }

    public func remove(_ url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
}
