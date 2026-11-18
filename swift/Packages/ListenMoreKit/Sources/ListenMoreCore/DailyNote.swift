import Foundation

/// The optional daily-note link: one line appended to the day's note, pointing at the call's note.
public struct DailyNoteOptions: Equatable, Sendable {
    public enum Style: String, CaseIterable, Sendable {
        /// `- 09:05 [[path|title]]`
        case link
        /// `![[path]]`: Obsidian shows the call's note inside the daily note; its text stays in the call's file.
        case embed
    }

    /// `{yyyy}`, `{MM}`, `{dd}` and `{date}` (2026-01-31), relative to the vault (or the chosen folder
    /// when it isn't in a vault).
    public static let defaultPattern = "Daily/{yyyy}-{MM}-{dd}.md"

    public var pathPattern: String
    public var style: Style

    public init(pathPattern: String = DailyNoteOptions.defaultPattern, style: Style = .link) {
        self.pathPattern = pathPattern
        self.style = style
    }
}

/// Finding the day's note and adding the call's line to it. Append only: existing text is never
/// rewritten, and each call's line carries a hidden marker so adding it again does nothing.
public enum DailyNote {
    /// The day's note under `root`, or nil when the pattern is empty, absolute, or climbs out of `root`.
    public static func url(pattern: String, date: Date, root: URL, timeZone: TimeZone = .current) -> URL? {
        let raw = pattern.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, !raw.hasPrefix("/"), !raw.hasPrefix("~") else { return nil }
        let filled = [("{yyyy}", "yyyy"), ("{MM}", "MM"), ("{dd}", "dd"), ("{date}", "yyyy-MM-dd")]
            .reduce(raw) { $0.replacingOccurrences(of: $1.0, with: TranscriptFormat.stamp(date, $1.1, timeZone)) }
        let parts = filled.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, !parts.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        var comps = parts.map { NoteFileName.sanitize($0) }
        guard !comps.contains(where: \.isEmpty) else { return nil }
        let ext = ".\(NoteFileName.fileExtension)"
        if !comps[comps.count - 1].lowercased().hasSuffix(ext) { comps[comps.count - 1] += ext }
        let url = comps.reduce(root.standardizedFileURL) { $0.appendingPathComponent($1) }
        return isInside(url, root) ? url : nil
    }

    /// `url` stays under `root` once symlinks in its nearest existing folder are resolved.
    static func isInside(_ url: URL, _ root: URL) -> Bool {
        let base = root.standardizedFileURL.resolvingSymlinksInPath().path
        var dir = url.deletingLastPathComponent().standardizedFileURL
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: dir.path) {
            tail.insert(dir.lastPathComponent, at: 0)
            let parent = dir.deletingLastPathComponent()
            if parent.path == dir.path { break }
            dir = parent
        }
        let resolved = tail.reduce(dir.resolvingSymlinksInPath()) { $0.appendingPathComponent($1) }.path
        return resolved == base || resolved.hasPrefix(base.hasSuffix("/") ? base : base + "/")
    }

    /// The hidden per-call marker (an Obsidian comment, not shown when reading).
    public static func marker(callId: String) -> String { "%%meetingcard:\(callId)%%" }

    /// The line for the call: a link (with its start time and title) or an embed, then the marker.
    /// The link uses the note's path in the vault when there is one, else its name.
    public static func line(note: URL, vaultRoot: URL?, start: Date, title: String, style: DailyNoteOptions.Style,
                            callId: String, timeZone: TimeZone = .current) -> String {
        let target = vaultRoot.flatMap { ObsidianVault.linkPath(of: note, under: $0) }
            ?? String(note.lastPathComponent.dropLast(NoteFileName.fileExtension.count + 1))
        let mark = marker(callId: callId)
        switch style {
        case .link:
            let alias = NoteFileName.sanitize(title)
            return "- \(TranscriptFormat.stamp(start, "HH:mm", timeZone)) [[\(target)|\(alias.isEmpty ? target : alias)]] \(mark)"
        case .embed:
            return "![[\(target)]] \(mark)"
        }
    }

    /// Appends `line` (and a newline) unless the note already has `marker`. Starts on a new line when
    /// the note doesn't end with one; creates the note, and its folders, when missing. Returns whether
    /// it wrote. A note that exists but can't be read is left alone.
    @discardableResult
    public static func append(_ line: String, marker: String, to url: URL, store: TranscriptStore) throws -> Bool {
        var prefix = ""
        if store.exists(url) {
            guard let existing = store.read(url) else { return false }
            if existing.contains(marker) { return false }
            if !existing.isEmpty && !existing.hasSuffix("\n") { prefix = "\n" }
        } else {
            try store.prepare(folder: url.deletingLastPathComponent())
        }
        try store.append(prefix + line + "\n", to: url)
        return true
    }
}
