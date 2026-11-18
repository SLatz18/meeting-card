import Foundation

/// Settings words for saved transcripts as Obsidian notes. Every string is a PLACEHOLDER pending copy
/// review (listed for the writer in the PR); the note's own words are the Kit's `NoteWording`.
public enum TranscriptCopy {
    public static let saveTo = "Save transcripts to"
    /// %@: the vault folder's name.
    public static let inVault = "In the Obsidian vault \u{201C}%@\u{201D}."
    public static let notInVault = "Not in an Obsidian vault: notes are plain Markdown files."
    public static let folderUnavailable = "This folder is missing or in the Trash, so nothing is saved. Choose another."
    public static let unfinishedOne = "1 unfinished transcript: MeetingCard finishes it after a call or at the next launch."
    /// %d: how many.
    public static let unfinishedMany = "%d unfinished transcripts: MeetingCard finishes them after a call or at the next launch."
    public static let fileNameLabel = "File name"
    public static let fileNameHelp = "Use {date}, {time}, {title} and {app}."
    public static let tagsLabel = "Tags"
    public static let tagsHelp = "Separate tags with commas."
    public static let dailyNoteToggle = "Link from the daily note"
    public static let dailyNoteHelp = "Adds one line to the day\u{2019}s note. Nothing already in it is changed."
    public static let dailyNotePathLabel = "Daily note path"
    public static let dailyNoteStyleLabel = "Show the call as"
    public static let dailyNoteLink = "Link"
    public static let dailyNoteEmbed = "Embed"
    public static let retentionLabel = "Keep transcripts"
    public static let retentionForever = "Forever"
    public static let retentionYear = "1 year"
    /// %d: a number of days.
    public static let retentionDays = "%d days"
    public static let retentionHelp = "Older notes saved by MeetingCard are removed after each call and at launch. Notes you\u{2019}ve edited after the call are kept."
    public static let deleteThisCall = "Delete This Call\u{2019}s Transcript"
    public static let deleteThisCallMenu = "Delete This Call\u{2019}s Transcript\u{2026}"
    public static let deleteConfirmBody = "This call\u{2019}s notes are removed from the folder, including one started beside a note you edited during the call. A link in the daily note stays. This can\u{2019}t be undone."

    public static func vaultStatus(_ vaultName: String?, folderUsable: Bool = true) -> String {
        guard folderUsable else { return folderUnavailable }
        return vaultName.map { String(format: inVault, $0) } ?? notInVault
    }

    /// nil when nothing is unfinished.
    public static func unfinished(_ n: Int) -> String? {
        n <= 0 ? nil : n == 1 ? unfinishedOne : String(format: unfinishedMany, n)
    }

    public static func retention(_ days: Int?) -> String {
        switch days {
        case nil: retentionForever
        case 365?: retentionYear
        case let d?: String(format: retentionDays, d)
        }
    }
}
