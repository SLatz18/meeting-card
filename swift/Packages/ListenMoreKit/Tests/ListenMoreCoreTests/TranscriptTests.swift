import XCTest
@testable import ListenMoreCore

/// Records every store call in memory; touches no disk.
final class SpyStore: TranscriptStore {
    enum Call: Equatable { case prepare(URL), write(URL), remove(URL) }
    var calls: [Call] = []
    var files: [URL: String] = [:]
    var failWrites = false

    func prepare(folder: URL) throws { calls.append(.prepare(folder)) }
    func exists(_ url: URL) -> Bool { files[url] != nil }
    func write(_ text: String, to url: URL) throws {
        if failWrites { throw NSError(domain: "SpyStore", code: 1) }
        calls.append(.write(url))
        files[url] = text
    }
    func remove(_ url: URL) throws {
        calls.append(.remove(url))
        files[url] = nil
    }
    var writtenURLs: Set<URL> { Set(calls.compactMap { if case .write(let u) = $0 { u } else { nil } }) }
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
}

final class TranscriptFormatTests: XCTestCase {
    func testFileNameHasOnlyTheStartTime() {
        XCTAssertEqual(TranscriptFormat.fileName(start: TranscriptFixture.start, timeZone: TranscriptFixture.utc),
                       "Call 2026-01-31 09-05-07.md")
    }

    func testTimestamps() {
        XCTAssertEqual(TranscriptFormat.timestamp(0), "00:00:00")
        XCTAssertEqual(TranscriptFormat.timestamp(65.9), "00:01:05")
        XCTAssertEqual(TranscriptFormat.timestamp(3723), "01:02:03")
        XCTAssertEqual(TranscriptFormat.timestamp(-3), "00:00:00")
    }

    func testMarkdownLayout() {
        var labels = SpeakerLabels()
        labels.rename(.others, to: "Team B")
        let md = TranscriptFormat.markdown(start: TranscriptFixture.start, lines: [
            TranscriptLine(speaker: .me, offset: 2, text: "Shall we start?"),
            TranscriptLine(speaker: .others, offset: 65, text: "Yes,\nready."),
        ], labels: labels, timeZone: TranscriptFixture.utc)
        XCTAssertEqual(md, """
        # Call transcript

        - Started: 2026-01-31 09:05:07 +00:00
        - Speakers: You (microphone), Team B (call audio)

        **[00:00:02] You:** Shall we start?

        **[00:01:05] Team B:** Yes, ready.

        """)
    }
}

final class TranscriptRecorderTests: XCTestCase {
    let folder = TranscriptFixture.folder

    func recorder(_ store: SpyStore) -> TranscriptRecorder {
        TranscriptRecorder(store: store, timeZone: TranscriptFixture.utc)
    }

    func testSavingOffTouchesNothingAndKeepsNothing() {
        let store = SpyStore()
        let r = recorder(store)
        r.begin(start: TranscriptFixture.start, folder: nil, labels: SpeakerLabels())
        r.add(TranscriptLine(speaker: .me, offset: 1, text: "one"))
        r.relabel(SpeakerLabels())
        r.end()
        XCTAssertEqual(store.calls, [])
        XCTAssertEqual(r.state, .off)
        XCTAssertEqual(r.keptLineCount, 0)
        XCTAssertNil(r.lastURL)
    }

    func testSavingOnWritesOneFileInTheFolderOnly() throws {
        let store = SpyStore()
        let r = recorder(store)
        r.begin(start: TranscriptFixture.start, folder: folder, labels: SpeakerLabels())
        let url = folder.appendingPathComponent("Call 2026-01-31 09-05-07.md")
        XCTAssertEqual(r.state, .saving(url))
        r.add(TranscriptLine(speaker: .me, offset: 1, text: "one"))
        r.add(TranscriptLine(speaker: .others, offset: 2, text: "two"))
        var tagged = SpeakerLabels()
        tagged.rename(.others, to: "Guest")
        r.relabel(tagged)
        XCTAssertEqual(store.writtenURLs, [url])
        XCTAssertEqual(store.calls.first, .prepare(folder))
        XCTAssertTrue(try XCTUnwrap(store.files[url]).contains("**[00:00:02] Guest:** two"), "a tag relabels earlier lines")
        r.end()
        XCTAssertEqual(r.state, .saved(url))
        XCTAssertEqual(r.keptLineCount, 0, "nothing stays in memory after the call")
        r.add(TranscriptLine(speaker: .me, offset: 3, text: "late"))
        XCTAssertFalse(try XCTUnwrap(store.files[url]).contains("late"))
    }

    func testASecondCallInTheSameSecondGetsItsOwnFile() {
        let store = SpyStore()
        let r = recorder(store)
        r.begin(start: TranscriptFixture.start, folder: folder, labels: SpeakerLabels())
        r.begin(start: TranscriptFixture.start, folder: folder, labels: SpeakerLabels())
        XCTAssertEqual(r.lastURL?.lastPathComponent, "Call 2026-01-31 09-05-07 (2).md")
        XCTAssertEqual(store.writtenURLs.count, 2)
    }

    func testDeleteTheCurrentTranscriptStopsSavingForTheCall() throws {
        let store = SpyStore()
        let r = recorder(store)
        r.begin(start: TranscriptFixture.start, folder: folder, labels: SpeakerLabels())
        r.add(TranscriptLine(speaker: .me, offset: 1, text: "one"))
        XCTAssertTrue(try r.deleteCurrentOrLast())
        XCTAssertEqual(r.state, .deleted)
        XCTAssertTrue(store.files.isEmpty)
        r.add(TranscriptLine(speaker: .me, offset: 2, text: "two"))
        XCTAssertTrue(store.files.isEmpty, "nothing is written again after a delete")
        XCTAssertFalse(try r.deleteCurrentOrLast(), "nothing left to delete")
    }

    func testDeleteTheLastTranscriptAfterTheCall() throws {
        let store = SpyStore()
        let r = recorder(store)
        r.begin(start: TranscriptFixture.start, folder: folder, labels: SpeakerLabels())
        r.end()
        r.begin(start: TranscriptFixture.start.addingTimeInterval(600), folder: nil, labels: SpeakerLabels())
        XCTAssertTrue(try r.deleteCurrentOrLast(), "the last file stays deletable while a call runs with saving off")
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
        let (live, store, _) = make()
        live.callStarted()
        live.receive(.final(.me, text: "one"))
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

    func testTheCostCapStopsCaptionsAndFinishesTheFile() {
        let (live, store, clock) = make(captions: true, saving: true)
        live.callStarted()
        clock.advance(3)
        live.receive(.final(.me, text: "kept"))
        live.gptStopped(.budgetCap)
        XCTAssertEqual(live.captionState, .stopped(.budgetCap))
        XCTAssertEqual(live.visibleLines, [])
        XCTAssertFalse(live.recorder.isSaving)
        live.receive(.final(.me, text: "dropped"))
        XCTAssertEqual(live.captions.lines, [])
        let text = store.files.values.first ?? ""
        XCTAssertTrue(text.contains("**[00:00:03] You:** kept"))
        XCTAssertFalse(text.contains("dropped"))
        live.callStarted()
        XCTAssertEqual(live.captionState, .live, "the next call starts fresh")
    }

    func testSavingTurnedOnMidCallStartsTheFileFromThen() {
        let (live, store, clock) = make(captions: true)
        live.callStarted()
        live.receive(.final(.me, text: "before"))
        clock.advance(5)
        live.update(.init(captions: true, saving: true, folder: TranscriptFixture.folder, keyUsable: true))
        live.receive(.final(.others, text: "after"))
        let text = store.files.values.first ?? ""
        XCTAssertFalse(text.contains("before"), "lines from before saving was on were never kept")
        XCTAssertTrue(text.contains("**[00:00:05] Them:** after"))
        live.update(.init(captions: false, saving: false, folder: TranscriptFixture.folder, keyUsable: true))
        XCTAssertFalse(live.recorder.isSaving)
        XCTAssertEqual(live.captions.lines, [])
    }
}
