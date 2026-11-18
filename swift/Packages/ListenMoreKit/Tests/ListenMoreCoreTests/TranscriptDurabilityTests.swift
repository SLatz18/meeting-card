import XCTest
@testable import ListenMoreCore

/// Real files in a temporary folder (runs on Linux and macOS): incremental, atomic writes; recovery
/// after the app quits mid-call; retention; the daily-note line; vault detection. Synthetic text only.
final class TranscriptDurabilityTests: XCTestCase {
    var root: URL!
    var folder: URL!
    let utc = TranscriptFixture.utc
    let start = TranscriptFixture.start

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("lm-durable-\(UUID().uuidString)", isDirectory: true)
        folder = root.appendingPathComponent("Vault/Meetings", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func recorder(_ store: TranscriptStore = FileTranscriptStore(), io: TranscriptIO = .inline) -> TranscriptRecorder {
        TranscriptRecorder(store: store, timeZone: utc, io: io, newCallId: TranscriptFixture.ids())
    }

    func names(_ dir: URL) throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted()
    }

    func read(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    func spool(_ id: String = "call1") -> URL { CallSpool.url(callId: id, in: folder) }

    // MARK: incremental, atomic

    func testEachLineIsOnDiskAsSoonAsItArrives() throws {
        let r = recorder()
        r.begin(start: start, folder: folder, labels: SpeakerLabels(), info: CallInfo(title: "Sync"))
        let note = try XCTUnwrap(r.lastURL)
        XCTAssertTrue(try read(note).contains("transcript-status: in-progress"))
        for i in 1...3 {
            r.add(TranscriptLine(speaker: i % 2 == 0 ? .me : .others, offset: Double(i), text: "line \(i)"))
            XCTAssertTrue(try read(note).contains("line \(i) ^l\(i)"), "line \(i) is in the note")
            XCTAssertEqual(try read(spool()).split(separator: "\n").count, 1 + i, "and in the spool")
        }
        XCTAssertEqual(try names(folder), [".meetingcard-call1.spool", "2026-01-31 0905 Sync.md"], "no temporary files left behind")
        let perms = try FileManager.default.attributesOfItem(atPath: note.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600)
        let spoolPerms = try FileManager.default.attributesOfItem(atPath: spool().path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(spoolPerms?.intValue, 0o600)
        r.end()
        XCTAssertEqual(try names(folder), ["2026-01-31 0905 Sync.md"], "the spool goes when the note is final")
    }

    func testReplacingNeverFollowsASymlink() throws {
        let outside = root.appendingPathComponent("outside.md")
        try "outside".write(to: outside, atomically: false, encoding: .utf8)
        let link = folder.appendingPathComponent("link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let store = FileTranscriptStore()
        XCTAssertThrowsError(try store.append("x", to: link), "append refuses a symlink")
        try store.write("replaced", to: link)
        XCTAssertEqual(try read(outside), "outside", "the file outside the folder is untouched")
        XCTAssertEqual(try read(link), "replaced", "the link itself was replaced by a plain file")
    }

    func testTheBackgroundQueueWritesInOrderAndFlushes() throws {
        let r = recorder(io: .serial(label: "test.transcript"))
        r.begin(start: start, folder: folder, labels: SpeakerLabels())
        for i in 1...50 { r.add(TranscriptLine(speaker: .others, offset: Double(i), text: "n\(i)")) }
        r.flush()
        let note = try read(try XCTUnwrap(r.lastURL))
        XCTAssertTrue(note.contains("n50 ^l50"))
        let spoolLines = try read(spool()).split(separator: "\n")
        XCTAssertEqual(spoolLines.count, 51)
        XCTAssertTrue(spoolLines.last?.contains("\"x\":\"n50\"") == true, "in order")
        r.end()
        r.flush()
        XCTAssertTrue(try read(try XCTUnwrap(r.lastURL)).contains("transcript-status: complete"))
    }

    // MARK: recovery

    /// The app quits mid-call: the recorder is dropped without `end()`.
    func crashMidCall(editNote: Bool = false) throws -> URL {
        var r: TranscriptRecorder? = recorder()
        var labels = SpeakerLabels()
        r?.begin(start: start, folder: folder, labels: labels, info: CallInfo(title: "Sync", app: "Zoom"))
        r?.add(TranscriptLine(speaker: .me, offset: 2, text: "first"))
        r?.gap(.youMuted, open: true, at: 5)
        r?.add(TranscriptLine(speaker: .others, offset: 9, text: "second"))
        r?.cue("interrupt", at: 9.5)
        labels.rename(.others, to: "Guest")
        r?.relabel(labels)
        let note = try XCTUnwrap(r?.lastURL)
        r = nil
        // The last spool record made it; the note render after it didn't.
        let line = CallSpool.line(TranscriptLine(speaker: .others, offset: 12, text: "only in the spool")).encoded()
        try FileTranscriptStore().append(line, to: spool())
        // A crash mid-append leaves a torn line.
        try FileTranscriptStore().append("{\"k\":\"line\",\"t\":13,\"x\":\"tor", to: spool())
        if editNote { try FileTranscriptStore().write(try read(note) + "\nMy notes.\n", to: note) }
        return note
    }

    func testRecoveryFinishesTheNoteFromTheSpool() throws {
        let note = try crashMidCall()
        let written = TranscriptMaintenance.recover(folder: folder, store: FileTranscriptStore(), timeZone: utc)
        XCTAssertEqual(written, [note])
        let md = try read(note)
        XCTAssertTrue(md.contains("transcript-status: recovered"))
        XCTAssertTrue(md.contains("end: 2026-01-31T09:05:19\n"), "ends at the last thing recorded")
        XCTAssertTrue(md.contains("**[00:00:02] You:** first ^l1"))
        XCTAssertTrue(md.contains("**[00:00:09] Guest:** second ^l2"), "the tag survives")
        XCTAssertTrue(md.contains("**[00:00:12] Guest:** only in the spool ^l3"), "nothing the spool had is lost")
        XCTAssertFalse(md.contains("^l4"), "the torn record is skipped")
        XCTAssertTrue(md.contains("*[00:00:05–00:00:12] Coach mic off: no You text.*"))
        XCTAssertTrue(md.contains("*[00:00:12–00:00:12] The app quit during the call"))
        XCTAssertTrue(md.contains("- [[#^l2|00:00:09]] Interruption"))
        XCTAssertTrue(md.contains("meeting-app: \"Zoom\""))
        XCTAssertFalse(try names(folder).contains { $0.hasSuffix(".spool") }, "the spool is removed")
        XCTAssertEqual(TranscriptMaintenance.recover(folder: folder, store: FileTranscriptStore(), timeZone: utc), [], "once only")
    }

    func testRecoveryNeverOverwritesANoteEditedAfterTheCrash() throws {
        let note = try crashMidCall(editNote: true)
        let edited = try read(note)
        let written = TranscriptMaintenance.recover(folder: folder, store: FileTranscriptStore(), timeZone: utc)
        XCTAssertEqual(try read(note), edited, "the user's note is untouched")
        XCTAssertEqual(written.map(\.lastPathComponent), ["2026-01-31 0905 Sync (2).md"])
        XCTAssertTrue(try read(written[0]).contains("only in the spool"))
    }

    func testRecoveryOfACallThatEndedJustRewritesItComplete() throws {
        let r = recorder()
        r.begin(start: start, folder: folder, labels: SpeakerLabels())
        r.add(TranscriptLine(speaker: .me, offset: 1, text: "one"))
        let note = try XCTUnwrap(r.lastURL)
        // The end record is synced; the app quit before the final render.
        try FileTranscriptStore().append(CallSpool.end(t: 30).encoded(), to: spool())
        XCTAssertEqual(TranscriptMaintenance.recover(folder: folder, store: FileTranscriptStore(), timeZone: utc), [note])
        let md = try read(note)
        XCTAssertTrue(md.contains("transcript-status: complete"))
        XCTAssertTrue(md.contains("duration: \"00:00:30\""))
        XCTAssertFalse(md.contains("app quit"))
    }

    func testMaintenanceDuringACallLeavesThatCallAlone() throws {
        let crashed = try crashMidCall()
        let r = TranscriptRecorder(store: FileTranscriptStore(), timeZone: utc, io: .serial(label: "test.maintain"), newCallId: { "live1" })
        r.begin(start: start.addingTimeInterval(7200), folder: folder, labels: SpeakerLabels(), info: CallInfo(title: "Live"))
        r.add(TranscriptLine(speaker: .me, offset: 1, text: "live line"))
        r.maintain(folder: folder, retentionDays: 1, now: start.addingTimeInterval(86_400 * 30))
        r.add(TranscriptLine(speaker: .me, offset: 2, text: "after upkeep"))
        r.flush()
        XCTAssertTrue(try read(crashed).contains("transcript-status: recovered"), "the crashed call is finished")
        let live = try XCTUnwrap(r.lastURL)
        XCTAssertTrue(r.isSaving)
        let md = try read(live)
        XCTAssertTrue(md.contains("transcript-status: in-progress") && md.contains("after upkeep"), "the live call keeps going")
        XCTAssertTrue(FileManager.default.fileExists(atPath: CallSpool.url(callId: "live1", in: folder).path), "its spool is kept")
        r.end()
        r.flush()
        XCTAssertTrue(try read(live).contains("transcript-status: complete"))
    }

    func testRecoveryClearsOldTemporaryFilesAndEmptySpools() throws {
        let temp = folder.appendingPathComponent(".x.md.123\(FileTranscriptStore.tempSuffix)")
        try "partial".write(to: temp, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7200)], ofItemAtPath: temp.path)
        let junk = spool("junk")
        try "not json\n".write(to: junk, atomically: false, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -200_000)], ofItemAtPath: junk.path)
        TranscriptMaintenance.recover(folder: folder, store: FileTranscriptStore(), timeZone: utc)
        XCTAssertEqual(try names(folder), [])
    }

    // MARK: retention

    func testRetentionRemovesOnlyOldUneditedNotesThisAppWrote() throws {
        let store = FileTranscriptStore()
        func note(_ name: String, daysAgo: Double, ours: Bool = true, touchedDaysAgo: Double? = nil) throws -> URL {
            let url = folder.appendingPathComponent(name)
            let when = Date(timeIntervalSinceNow: -daysAgo * 86_400)
            var r = CallRecord(callId: "c-\(name.count)", start: when)
            r.end = 60
            let text = ours ? CallNote.render(r, labels: SpeakerLabels(), status: .complete, timeZone: utc) : "---\nstart: 2020-01-01T00:00:00\n---\nmine\n"
            try store.write(text, to: url)
            let touched = Date(timeIntervalSinceNow: -(touchedDaysAgo ?? daysAgo) * 86_400)
            try FileManager.default.setAttributes([.modificationDate: touched], ofItemAtPath: url.path)
            return url
        }
        let old = try note("old.md", daysAgo: 40)
        let recent = try note("recent.md", daysAgo: 5)
        let edited = try note("edited.md", daysAgo: 40, touchedDaysAgo: 1)
        let foreign = try note("foreign.md", daysAgo: 400, ours: false)
        let current = try note("current.md", daysAgo: 40)
        let sub = folder.appendingPathComponent("Sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let viaLink = root.appendingPathComponent("Link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: viaLink, withDestinationURL: root.appendingPathComponent("Vault"))
        let currentByOtherPath = viaLink.appendingPathComponent("Meetings/current.md")
        let removed = TranscriptMaintenance.prune(folder: folder, store: store, olderThanDays: 30, timeZone: utc, keep: [currentByOtherPath])
        XCTAssertEqual(removed.map(\.lastPathComponent), [old.lastPathComponent], "the kept note is kept by any path to it")
        for kept in [recent, edited, foreign, current, sub] { XCTAssertTrue(store.exists(kept), kept.lastPathComponent) }
        XCTAssertEqual(TranscriptMaintenance.prune(folder: folder, store: store, olderThanDays: 0, timeZone: utc), [], "0: off")
    }

    // MARK: daily note

    func testDailyNoteAppendIsIdempotentAndKeepsExistingText() throws {
        let store = FileTranscriptStore()
        let daily = root.appendingPathComponent("Vault/Daily/2026-01-31.md")
        try FileManager.default.createDirectory(at: daily.deletingLastPathComponent(), withIntermediateDirectories: true)
        let existing = "# Saturday\n\n- [ ] a task without a newline at the end"
        try existing.write(to: daily, atomically: false, encoding: .utf8)
        let mark = DailyNote.marker(callId: "call1")
        XCTAssertTrue(try DailyNote.append("- 09:05 [[x|Sync]] \(mark)", marker: mark, to: daily, store: store))
        XCTAssertFalse(try DailyNote.append("- 09:05 [[x|Sync]] \(mark)", marker: mark, to: daily, store: store), "twice: once")
        let text = try read(daily)
        XCTAssertTrue(text.hasPrefix(existing), "existing text is untouched, byte for byte")
        XCTAssertEqual(text, existing + "\n- 09:05 [[x|Sync]] \(mark)\n")
        XCTAssertTrue(try DailyNote.append("- line two %%meetingcard:call2%%", marker: DailyNote.marker(callId: "call2"), to: daily, store: store))
        XCTAssertTrue(try read(daily).hasSuffix("\(mark)\n- line two %%meetingcard:call2%%\n"))
    }

    func testDailyNoteIsCreatedWhenMissing() throws {
        let daily = root.appendingPathComponent("Vault/Daily/new.md")
        XCTAssertTrue(try DailyNote.append("- l %%m%%", marker: "%%m%%", to: daily, store: FileTranscriptStore()))
        XCTAssertEqual(try read(daily), "- l %%m%%\n")
    }

    func testTheRecorderLinksTheCallFromTheVaultsDailyNote() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Vault/.obsidian"), withIntermediateDirectories: true)
        let r = recorder()
        let options = NoteOptions(dailyNote: DailyNoteOptions())
        r.begin(start: start, folder: folder, labels: SpeakerLabels(), info: CallInfo(title: "Sync"), options: options)
        r.end()
        let daily = root.appendingPathComponent("Vault/Daily/2026-01-31.md")
        XCTAssertEqual(try read(daily), "- 09:05 [[Meetings/2026-01-31 0905 Sync|Sync]] %%meetingcard:call1%%\n")
        r.begin(start: start.addingTimeInterval(3600), folder: folder, labels: SpeakerLabels(), options: NoteOptions(dailyNote: DailyNoteOptions(style: .embed)))
        r.end()
        XCTAssertTrue(try read(daily).hasSuffix("\n![[Meetings/2026-01-31 1005 Call]] %%meetingcard:call2%%\n"))
        XCTAssertTrue(try r.deleteCurrentOrLast())
        XCTAssertTrue(try read(daily).contains("call2"), "append only: Delete leaves the daily note alone")
    }

    func testRecoveryAddsTheDailyLineOnce() throws {
        let r0 = TranscriptRecorder(store: FileTranscriptStore(), timeZone: utc, newCallId: { "call9" })
        r0.begin(start: start, folder: folder, labels: SpeakerLabels(), options: NoteOptions(dailyNote: DailyNoteOptions(pathPattern: "Day {date}")))
        let daily = folder.appendingPathComponent("Day 2026-01-31.md")
        let before = try read(daily)
        TranscriptMaintenance.recover(folder: folder, store: FileTranscriptStore(), timeZone: utc)
        XCTAssertEqual(try read(daily), before, "already there: nothing added")
    }

    func testDailyNotePathsStayInsideTheRoot() throws {
        let vault = root.appendingPathComponent("Vault", isDirectory: true)
        let date = start
        func path(_ p: String) -> String? { DailyNote.url(pattern: p, date: date, root: vault, timeZone: utc)?.path }
        XCTAssertEqual(path("Daily/{yyyy}-{MM}-{dd}.md"), vault.appendingPathComponent("Daily/2026-01-31.md").standardizedFileURL.path)
        XCTAssertEqual(path("Journal/{yyyy}/{date}"), vault.appendingPathComponent("Journal/2026/2026-01-31.md").standardizedFileURL.path)
        XCTAssertNil(path("../escape.md"))
        XCTAssertNil(path("Daily/../../escape.md"))
        XCTAssertNil(path("/etc/x.md"))
        XCTAssertNil(path("~/x.md"))
        XCTAssertNil(path("  "))
        XCTAssertEqual(path("Bad:name?.md").map { URL(fileURLWithPath: $0).lastPathComponent }, "Bad name .md")
        let outside = root.appendingPathComponent("Outside", isDirectory: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: vault, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: vault.appendingPathComponent("Linked"), withDestinationURL: outside)
        XCTAssertNil(path("Linked/{date}.md"), "a symlinked folder that leaves the vault is refused")
    }

    func testDailyLineForms() {
        let note = folder.appendingPathComponent("2026-01-31 0905 Sync.md")
        let vault = root.appendingPathComponent("Vault", isDirectory: true)
        XCTAssertEqual(DailyNote.line(note: note, vaultRoot: vault, start: start, title: "Sync | [x]", style: .link, callId: "c", timeZone: utc),
                       "- 09:05 [[Meetings/2026-01-31 0905 Sync|Sync x]] %%meetingcard:c%%")
        XCTAssertEqual(DailyNote.line(note: note, vaultRoot: nil, start: start, title: "", style: .link, callId: "c", timeZone: utc),
                       "- 09:05 [[2026-01-31 0905 Sync|2026-01-31 0905 Sync]] %%meetingcard:c%%")
    }

    // MARK: vault

    func testVaultDetectionLooksAtTheFolderAndItsParents() throws {
        let store = FileTranscriptStore()
        XCTAssertNil(ObsidianVault.root(containing: folder, store: store))
        let vault = root.appendingPathComponent("Vault", isDirectory: true)
        try FileManager.default.createDirectory(at: vault.appendingPathComponent(".obsidian"), withIntermediateDirectories: true)
        XCTAssertEqual(ObsidianVault.root(containing: folder, store: store)?.standardizedFileURL.path, vault.standardizedFileURL.path)
        XCTAssertEqual(ObsidianVault.root(containing: vault, store: store)?.standardizedFileURL.path, vault.standardizedFileURL.path)
        XCTAssertEqual(ObsidianVault.linkPath(of: folder.appendingPathComponent("a b.md"), under: vault), "Meetings/a b")
        XCTAssertNil(ObsidianVault.linkPath(of: root.appendingPathComponent("x.md"), under: vault))
    }
}
