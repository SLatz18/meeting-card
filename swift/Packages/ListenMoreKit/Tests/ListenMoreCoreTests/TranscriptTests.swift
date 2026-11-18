import XCTest
@testable import ListenMoreCore

/// Keeps every file in memory and records each store call; touches no disk.
final class SpyStore: TranscriptStore {
    enum Call: Equatable { case prepare(URL), write(URL), create(URL), append(URL), remove(URL) }
    var calls: [Call] = []
    var files: [URL: String] = [:]
    var dirs: Set<URL> = []
    var mtimes: [URL: Date] = [:]
    var failWrites = false

    func prepare(folder: URL) throws {
        calls.append(.prepare(folder))
        dirs.insert(folder.standardizedFileURL)
    }
    func exists(_ url: URL) -> Bool { files[url] != nil || dirs.contains(url.standardizedFileURL) }
    func write(_ text: String, to url: URL) throws {
        if failWrites { throw NSError(domain: "SpyStore", code: 1) }
        calls.append(.write(url))
        files[url] = text
    }
    func create(_ text: String, at url: URL) throws {
        if failWrites { throw NSError(domain: "SpyStore", code: 1) }
        guard files[url] == nil else { throw TranscriptStoreError.exists }
        calls.append(.create(url))
        files[url] = text
    }
    func append(_ text: String, to url: URL) throws {
        if failWrites { throw NSError(domain: "SpyStore", code: 1) }
        calls.append(.append(url))
        files[url, default: ""] += text
    }
    func remove(_ url: URL) throws {
        calls.append(.remove(url))
        files[url] = nil
    }
    func read(_ url: URL) -> String? { files[url] }
    func head(_ url: URL, bytes: Int) -> String? { files[url].map { String(decoding: Data($0.utf8).prefix(bytes), as: UTF8.self) } }
    func contents(of folder: URL) -> [URL] {
        let base = folder.standardizedFileURL.path
        return files.keys.filter { $0.deletingLastPathComponent().standardizedFileURL.path == base }
    }
    func modified(_ url: URL) -> Date? { mtimes[url] }
    func isDirectory(_ url: URL) -> Bool { dirs.contains(url.standardizedFileURL) }

    /// Notes written whole: created or replaced.
    var writtenURLs: Set<URL> {
        Set(calls.compactMap {
            switch $0 {
            case .write(let u), .create(let u): u
            case .prepare, .append, .remove: nil
            }
        })
    }
    /// Notes only (not spools).
    var notes: [URL: String] { files.filter { $0.key.pathExtension == "md" } }
    /// The one note's text, when there is exactly one.
    var note: String? { notes.count == 1 ? notes.values.first : nil }
    var spools: [URL: String] { files.filter { CallSpool.isSpool($0.key) } }
}

final class SteppedClock: @unchecked Sendable {
    var now: Date
    init(_ start: Date) { now = start }
    func advance(_ s: TimeInterval) { now = now.addingTimeInterval(s) }
}

enum TranscriptFixture {
    static let utc = TimeZone(identifier: "UTC")!
    /// 2026-01-31 09:05:07 UTC
    static let start = Date(timeIntervalSince1970: 1_769_850_307)
    static let folder = URL(fileURLWithPath: "/synthetic/Transcripts", isDirectory: true)
    static func ids() -> () -> String {
        var n = 0
        return { n += 1; return "call\(n)" }
    }
}

final class TranscriptFormatTests: XCTestCase {
    func testTimestamps() {
        XCTAssertEqual(TranscriptFormat.timestamp(0), "00:00:00")
        XCTAssertEqual(TranscriptFormat.timestamp(65.9), "00:01:05")
        XCTAssertEqual(TranscriptFormat.timestamp(3723), "01:02:03")
        XCTAssertEqual(TranscriptFormat.timestamp(-3), "00:00:00")
    }
}

final class TranscriptRecorderTests: XCTestCase {
    let folder = TranscriptFixture.folder

    func recorder(_ store: SpyStore) -> TranscriptRecorder {
        TranscriptRecorder(store: store, timeZone: TranscriptFixture.utc, newCallId: TranscriptFixture.ids())
    }

    func testSavingOffTouchesNothingAndKeepsNothing() {
        let store = SpyStore()
        let r = recorder(store)
        r.begin(start: TranscriptFixture.start, folder: nil, labels: SpeakerLabels())
        r.add(TranscriptLine(speaker: .me, offset: 1, text: "one"))
        r.relabel(SpeakerLabels())
        r.gap(.paused, open: true, at: 2)
        r.cue("interrupt", at: 3)
        r.end()
        XCTAssertEqual(store.calls, [])
        XCTAssertEqual(r.state, .off)
        XCTAssertEqual(r.keptLineCount, 0)
        XCTAssertNil(r.lastURL)
    }

    func testSavingOnWritesTheNoteAndItsSpoolInTheFolderOnly() throws {
        let store = SpyStore()
        let r = recorder(store)
        r.begin(start: TranscriptFixture.start, folder: folder, labels: SpeakerLabels())
        let url = folder.appendingPathComponent("2026-01-31 0905 Call.md")
        XCTAssertEqual(r.state, .saving(url))
        r.add(TranscriptLine(speaker: .me, offset: 1, text: "one"))
        r.add(TranscriptLine(speaker: .others, offset: 2, text: "two"))
        var tagged = SpeakerLabels()
        tagged.rename(.others, to: "Guest")
        r.relabel(tagged)
        XCTAssertEqual(store.writtenURLs, [url], "the note is the only replaced file")
        XCTAssertEqual(store.calls.first, .prepare(folder))
        XCTAssertTrue(try XCTUnwrap(store.files[url]).contains("**[00:00:02] Guest:** two ^l2"), "a tag relabels earlier lines")
        XCTAssertEqual(store.spools.count, 1)
        for f in store.files.keys { XCTAssertTrue(f.path.hasPrefix(folder.path + "/"), f.path) }
        r.end()
        XCTAssertEqual(r.state, .saved(url))
        XCTAssertEqual(r.keptLineCount, 0, "nothing stays in memory after the call")
        XCTAssertEqual(store.spools.count, 0, "the spool goes once the note is final")
        XCTAssertTrue(try XCTUnwrap(store.files[url]).contains("transcript-status: complete"))
        r.add(TranscriptLine(speaker: .me, offset: 3, text: "late"))
        XCTAssertFalse(try XCTUnwrap(store.files[url]).contains("late"))
    }

    func testASecondCallInTheSameMinuteGetsItsOwnNote() {
        let store = SpyStore()
        let r = recorder(store)
        r.begin(start: TranscriptFixture.start, folder: folder, labels: SpeakerLabels())
        r.begin(start: TranscriptFixture.start.addingTimeInterval(20), folder: folder, labels: SpeakerLabels())
        XCTAssertEqual(r.lastURL?.lastPathComponent, "2026-01-31 0905 Call (2).md")
        XCTAssertEqual(store.writtenURLs.count, 2)
    }

    func testDeleteTheCurrentTranscriptStopsSavingForTheCall() throws {
        let store = SpyStore()
        let r = recorder(store)
        r.begin(start: TranscriptFixture.start, folder: folder, labels: SpeakerLabels())
        r.add(TranscriptLine(speaker: .me, offset: 1, text: "one"))
        XCTAssertTrue(try r.deleteCurrentOrLast())
        XCTAssertEqual(r.state, .deleted)
        XCTAssertTrue(store.files.isEmpty, "note and spool are gone")
        r.add(TranscriptLine(speaker: .me, offset: 2, text: "two"))
        r.end()
        XCTAssertTrue(store.files.isEmpty, "nothing is written again after a delete")
        XCTAssertFalse(try r.deleteCurrentOrLast(), "nothing left to delete")
    }

    func testDeleteTheLastTranscriptAfterTheCall() throws {
        let store = SpyStore()
        let r = recorder(store)
        r.begin(start: TranscriptFixture.start, folder: folder, labels: SpeakerLabels())
        r.end()
        r.begin(start: TranscriptFixture.start.addingTimeInterval(600), folder: nil, labels: SpeakerLabels())
        XCTAssertTrue(try r.deleteCurrentOrLast(), "the last note stays deletable while a call runs with saving off")
        XCTAssertTrue(store.files.isEmpty)
        XCTAssertEqual(r.state, .off)
    }

    func testAFailedWriteStopsSaving() {
        let store = SpyStore()
        store.failWrites = true
        let r = recorder(store)
        r.begin(start: TranscriptFixture.start, folder: folder, labels: SpeakerLabels())
        XCTAssertEqual(r.state, .failed)
        XCTAssertFalse(r.isSaving)
    }

    func testANoteEditedDuringTheCallIsNeverOverwritten() throws {
        let store = SpyStore()
        let r = recorder(store)
        r.begin(start: TranscriptFixture.start, folder: folder, labels: SpeakerLabels())
        let url = try XCTUnwrap(r.lastURL)
        r.add(TranscriptLine(speaker: .me, offset: 1, text: "one"))
        let edited = try XCTUnwrap(store.files[url]) + "\nMy own note.\n"
        store.files[url] = edited
        r.add(TranscriptLine(speaker: .others, offset: 2, text: "two"))
        XCTAssertEqual(store.files[url], edited, "the user's text stays as they left it")
        let beside = folder.appendingPathComponent("2026-01-31 0905 Call (2).md")
        XCTAssertEqual(r.state, .saving(beside))
        r.end()
        let final = try XCTUnwrap(store.files[beside])
        XCTAssertTrue(final.contains("one") && final.contains("two"), "the new note has the whole call")
        XCTAssertTrue(try r.deleteCurrentOrLast())
        XCTAssertTrue(store.notes.isEmpty, "delete removes both notes of the call")
    }

    func testANoteRemovedDuringTheCallStopsSaving() {
        let store = SpyStore()
        let r = recorder(store)
        r.begin(start: TranscriptFixture.start, folder: folder, labels: SpeakerLabels())
        store.files[r.lastURL!] = nil
        r.add(TranscriptLine(speaker: .me, offset: 1, text: "one"))
        XCTAssertEqual(r.state, .deleted)
        XCTAssertTrue(store.files.isEmpty, "not recreated, and the spool is gone too")
        r.end()
        XCTAssertTrue(store.files.isEmpty)
    }
}

final class LiveTranscriptTests: XCTestCase {
    func make(captions: Bool = false, saving: Bool = false, key: Bool = true) -> (LiveTranscript, SpyStore, SteppedClock) {
        let store = SpyStore()
        let clock = SteppedClock(TranscriptFixture.start)
        let live = LiveTranscript(settings: .init(captions: captions, saving: saving, folder: TranscriptFixture.folder, keyUsable: key),
                                  store: store, timeZone: TranscriptFixture.utc, clock: { clock.now })
        return (live, store, clock)
    }

    func testOffByDefault() {
        let s = LiveTranscript.Settings(folder: TranscriptFixture.folder)
        XCTAssertFalse(s.captions)
        XCTAssertFalse(s.saving)
        XCTAssertNil(s.note.dailyNote, "the daily-note line is off by default")
        let (live, store, _) = make()
        live.callStarted()
        live.receive(.final(.me, text: "one"))
        live.observe(CallConditions(youMuted: true))
        live.cue(.interrupt)
        XCTAssertEqual(live.captionState, .off)
        XCTAssertEqual(live.captions.lines, [])
        XCTAssertEqual(store.calls, [])
    }

    func testWithoutAUsableKeyCaptionsAreUnavailableAndNothingIsSaved() {
        let (live, store, _) = make(captions: true, saving: true, key: false)
        live.callStarted()
        live.receive(.final(.others, text: "one"))
        XCTAssertEqual(live.captionState, .unavailable)
        XCTAssertEqual(live.visibleLines, [])
        XCTAssertEqual(store.calls, [])
    }

    func testCaptionsDuringACallAreLabelledAndClearedAtTheEnd() {
        let (live, store, clock) = make(captions: true)
        XCTAssertEqual(live.captionState, .waiting)
        live.callStarted()
        XCTAssertEqual(live.captionState, .live)
        live.receive(.partial(.others, item: "a", text: "two"))
        clock.advance(1)
        live.receive(.final(.others, text: "Two."))
        live.receive(.final(.me, text: "One."))
        live.rename(.others, to: "Guest")
        XCTAssertEqual(live.visibleLines.map { live.labels.label($0.speaker) + ": " + $0.text }, ["Guest: Two.", "You: One."])
        live.callEnded()
        XCTAssertEqual(live.captions.lines, [])
        XCTAssertEqual(live.labels, SpeakerLabels(), "tags last one call")
        XCTAssertEqual(store.calls, [], "captions alone write nothing")
    }

    func testALineIsStampedWithItsTurnsStart() throws {
        let (live, store, clock) = make(saving: true)
        live.callStarted()
        clock.advance(4)
        live.receive(.partial(.others, item: "a", text: "Hel"))
        clock.advance(3)
        live.receive(.partial(.others, item: "a", text: "lo"))
        live.receive(.final(.others, text: "Hello."))
        live.receive(.final(.me, text: "Hi."))
        live.callEnded()
        let note = try XCTUnwrap(store.note)
        XCTAssertTrue(note.contains("**[00:00:04] Them:** Hello."), "the turn's first words, not when it finished")
        XCTAssertTrue(note.contains("**[00:00:07] You:** Hi."), "no partial: when it finished")
        XCTAssertTrue(note.contains("duration: \"00:00:07\""))
    }

    func testTheCostCapStopsCaptionsAndMarksTheNote() throws {
        let (live, store, clock) = make(captions: true, saving: true)
        live.callStarted()
        clock.advance(3)
        live.receive(.final(.me, text: "kept"))
        live.gptStopped(.budgetCap)
        XCTAssertEqual(live.captionState, .stopped(.budgetCap))
        XCTAssertEqual(live.visibleLines, [])
        XCTAssertTrue(live.recorder.isSaving, "the note stays open until the call ends")
        live.receive(.final(.me, text: "dropped"))
        XCTAssertEqual(live.captions.lines, [])
        clock.advance(60)
        live.callEnded()
        let text = try XCTUnwrap(store.note)
        XCTAssertTrue(text.contains("**[00:00:03] You:** kept"))
        XCTAssertFalse(text.contains("dropped"))
        XCTAssertTrue(text.contains("*[00:00:03–00:01:03] Transcription stopped (cost cap reached).*"))
        XCTAssertEqual(live.captionState, .waiting, "the stop lasts one call")
        live.callStarted()
        XCTAssertEqual(live.captionState, .live, "the next call starts fresh")
    }

    func testSavingTurnedOnMidCallStartsTheNoteFromThen() throws {
        let (live, store, clock) = make(captions: true)
        live.callStarted()
        live.receive(.final(.me, text: "before"))
        clock.advance(5)
        live.update(.init(captions: true, saving: true, folder: TranscriptFixture.folder, keyUsable: true))
        live.receive(.final(.others, text: "after"))
        let text = try XCTUnwrap(store.note)
        XCTAssertFalse(text.contains("before"), "lines from before saving was on were never kept")
        XCTAssertTrue(text.contains("**[00:00:05] Them:** after"))
        live.update(.init(captions: false, saving: false, folder: TranscriptFixture.folder, keyUsable: true))
        XCTAssertFalse(live.recorder.isSaving)
        XCTAssertEqual(live.captions.lines, [])
        XCTAssertTrue(try XCTUnwrap(store.note).contains("transcript-status: complete"))
    }
}
