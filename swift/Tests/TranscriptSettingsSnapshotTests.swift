import XCTest
@testable import MeetingCardCore

/// Text snapshots of the Settings rows for saved transcripts as Obsidian notes (the App draws one
/// control per row; the CI snapshot job renders them as `transcript-settings*.png`). Synthetic paths only.
final class TranscriptSettingsSnapshotTests: XCTestCase {
    let choose = "Choose\u{2026}"

    func input(_ f: (inout TranscriptSettingsRows.Input) -> Void = { _ in }) -> TranscriptSettingsRows.Input {
        var i = TranscriptSettingsRows.Input(folderPath: "~/Example Vault/Meetings", keyUsable: true,
                                             fileNamePattern: "{date} {time} {title}", tags: "meeting/transcript",
                                             dailyNotePath: "Daily/{yyyy}-{MM}-{dd}.md")
        f(&i)
        return i
    }

    func testDefaults() {
        XCTAssertEqual(TranscriptSettingsRows(input(), chooseFolder: choose).snapshot, """
        [folder] Save transcripts to: ~/Example Vault/Meetings [Choose…]
        [vault] Not in an Obsidian vault: notes are plain Markdown files.
        [fileName] File name: [{date} {time} {title}]
        [fileNameHelp] Use {date}, {time}, {title} and {app}.
        [tags] Tags: [meeting/transcript]
        [tagsHelp] Separate tags with commas.
        [dailyNote] Link from the daily note: off
        [dailyNoteHelp] Adds one line to the day’s note. Nothing already in it is changed.
        [retention] Keep transcripts: <Forever> of Forever | 7 days | 30 days | 90 days | 1 year
        [retentionHelp] Older notes saved by MeetingCard are removed after each call and at launch. Notes you’ve edited since are kept.
        """)
    }

    func testInAVaultWithTheDailyNoteRetentionAndADeletableCall() {
        let rows = TranscriptSettingsRows(input {
            $0.vaultName = "Example Vault"
            $0.dailyNoteOn = true
            $0.dailyNoteEmbed = true
            $0.retentionDays = 30
            $0.canDelete = true
        }, chooseFolder: choose)
        XCTAssertEqual(rows.snapshot, """
        [folder] Save transcripts to: ~/Example Vault/Meetings [Choose…]
        [vault] In the Obsidian vault “Example Vault”.
        [fileName] File name: [{date} {time} {title}]
        [fileNameHelp] Use {date}, {time}, {title} and {app}.
        [tags] Tags: [meeting/transcript]
        [tagsHelp] Separate tags with commas.
        [dailyNote] Link from the daily note: on
        [dailyNoteHelp] Adds one line to the day’s note. Nothing already in it is changed.
        [dailyNotePath] Daily note path: [Daily/{yyyy}-{MM}-{dd}.md]
        [dailyNoteStyle] Show the call as: <Embed> of Link | Embed
        [retention] Keep transcripts: <30 days> of Forever | 7 days | 30 days | 90 days | 1 year
        [retentionHelp] Older notes saved by MeetingCard are removed after each call and at launch. Notes you’ve edited since are kept.
        [delete] [Delete This Call’s Transcript]
        """)
    }

    func testWithoutAUsableKeyTheControlsAreOff() {
        let rows = TranscriptSettingsRows(input { $0.keyUsable = false; $0.dailyNoteOn = true }, chooseFolder: choose)
        for id in ["folder", "fileName", "tags", "dailyNote", "dailyNotePath", "dailyNoteStyle", "retention"] {
            XCTAssertEqual(rows.row(id)?.enabled, false, id)
        }
        XCTAssertTrue(rows.snapshot.contains("[dailyNote] Link from the daily note: on (off)"))
        XCTAssertEqual(rows.row("vault")?.enabled, true, "notes stay readable")
    }

    func testAnUnknownRetentionShowsForever() {
        XCTAssertEqual(TranscriptSettingsRows(input { $0.retentionDays = 12 }, chooseFolder: choose).row("retention")?.control,
                       .choice(label: "Keep transcripts", choices: ["Forever", "7 days", "30 days", "90 days", "1 year"], selected: 0))
    }

    /// Every Settings string for this feature comes from TranscriptCopy (the PR's table for the writer).
    func testStringsAreTheCopyTable() {
        XCTAssertEqual(TranscriptCopy.vaultStatus("V"), "In the Obsidian vault \u{201C}V\u{201D}.")
        XCTAssertEqual(TranscriptCopy.retention(7), "7 days")
        XCTAssertEqual(TranscriptCopy.retention(365), "1 year")
        XCTAssertEqual(TranscriptCopy.retention(nil), "Forever")
    }
}
