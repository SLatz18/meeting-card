import XCTest
@testable import ListenMoreCore

/// The Obsidian note's file name, properties and body. Synthetic text only.
final class NoteFileNameTests: XCTestCase {
    let start = TranscriptFixture.start
    let utc = TranscriptFixture.utc

    func name(_ title: String?, pattern: String = NoteFileName.defaultPattern, app: String? = nil) -> String {
        NoteFileName.base(pattern: pattern, start: start, info: CallInfo(title: title, app: app), timeZone: utc)
    }

    func testDefaultPatternIsDateTimeAndTitle() {
        XCTAssertEqual(name("Weekly sync"), "2026-01-31 0905 Weekly sync")
        XCTAssertEqual(name(nil), "2026-01-31 0905 Call", "no title: the placeholder word")
        XCTAssertEqual(name("   "), "2026-01-31 0905 Call")
        XCTAssertEqual(name("Demo", pattern: "{title} – {app} {date}", app: "Zoom"), "Demo – Zoom 2026-01-31")
    }

    func testUnsafeCharactersBecomeSpaces() {
        XCTAssertEqual(name("Q1: plan/review [draft] #2 ^x | a*b?c \"d\" <e> \\f %g"),
                       "2026-01-31 0905 Q1 plan review draft 2 x a b c d e f g")
        XCTAssertEqual(NoteFileName.sanitize("line one\nline\ttwo\u{7}"), "line one line two")
    }

    func testLeadingDotsAndTrailingDotsGo() {
        XCTAssertEqual(NoteFileName.sanitize("..hidden.."), "hidden")
        XCTAssertEqual(name(".", pattern: "{title}"), "Call", "an empty result falls back to the placeholder")
        XCTAssertEqual(name("x", pattern: "///"), "2026-01-31 0905 x", "a pattern that leaves nothing falls back to the default")
    }

    func testLongTitlesAreCut() {
        let n = NoteFileName.sanitize(String(repeating: "a", count: 300))
        XCTAssertEqual(n.count, NoteFileName.maxLength)
        XCTAssertEqual(NoteFileName.sanitize(String(repeating: "é", count: 200)).utf8.count, NoteFileName.maxBytes, "two bytes each: the byte cap")
    }

    func testReservedDeviceNamesAreChanged() {
        XCTAssertEqual(NoteFileName.sanitize("con"), "con_")
        XCTAssertEqual(NoteFileName.sanitize("LPT1.txt"), "LPT1_.txt", "the part before the first dot is what Windows reserves")
        XCTAssertEqual(NoteFileName.sanitize("con.txt"), "con_.txt")
        XCTAssertEqual(NoteFileName.sanitize("Console"), "Console")
        XCTAssertEqual(name("CON", pattern: "{title}"), "CON_", "title and file name are both sanitized: one underscore")
        for s in ["con.txt", "nul", "a..b", " .x. ", String(repeating: "会", count: 130)] {
            XCTAssertEqual(NoteFileName.sanitize(NoteFileName.sanitize(s)), NoteFileName.sanitize(s), s)
        }
    }

    /// Joiners some scripts and emoji need stay; other format characters (a bidi override) don't.
    func testZeroWidthJoinersAreKept() {
        XCTAssertEqual(name("\u{1F469}\u{200D}\u{1F4BB} Sync", pattern: "{title}"), "\u{1F469}\u{200D}\u{1F4BB} Sync")
        XCTAssertEqual(NoteFileName.sanitize("\u{0645}\u{06CC}\u{200C}\u{062E}\u{0648}\u{0627}\u{0645}"),
                       "\u{0645}\u{06CC}\u{200C}\u{062E}\u{0648}\u{0627}\u{0645}")
        XCTAssertEqual(NoteFileName.sanitize("a\u{202E}b"), "a b")
        XCTAssertTrue(NoteFileName.isPlainNoteName("\u{1F469}\u{200D}\u{1F4BB}.md"))
        XCTAssertEqual(CallNote.yaml("a\u{200D}b"), "\"a\u{200D}b\"")
        XCTAssertEqual(name("\u{200D}"), "2026-01-31 0905 Call", "a title of joiners alone is no title")
        XCTAssertEqual(name(" \u{200D}\u{200C} "), "2026-01-31 0905 Call")
        XCTAssertEqual(NoteFileName.sanitize("a \u{200D}b"), "a b", "a joiner after a space joins nothing")
    }

    func testRunsOfDotsBecomeOne() {
        XCTAssertEqual(NoteFileName.sanitize("v1..2...3"), "v1.2.3", "a name never holds `..`")
    }

    /// 120 Japanese characters are 360 UTF-8 bytes: the name is cut by bytes so it, its " (n)", ".md"
    /// and its temporary sibling all fit the 255-byte limit.
    func testLongNonASCIITitlesFitTheByteLimit() {
        let n = name(String(repeating: "会議", count: 60))
        XCTAssertLessThanOrEqual(n.utf8.count, NoteFileName.maxBytes)
        XCTAssertTrue(n.hasPrefix("2026-01-31 0905 会議"))
        XCTAssertLessThanOrEqual("\(n) (9999).md".utf8.count + FileTranscriptStore.tempNameOverhead, 255)
    }

    func testPlainNoteNames() {
        for ok in ["2026-01-31 0905 Call.md", "a (2).md", "会議.md"] { XCTAssertTrue(NoteFileName.isPlainNoteName(ok), ok) }
        for bad in ["../../escaped.md", "sub/x.md", "/abs.md", ".hidden.md", "x..md", "x.txt", ".md", "a\\b.md", "a\nb.md",
                    String(repeating: "a", count: 300) + ".md"] {
            XCTAssertFalse(NoteFileName.isPlainNoteName(bad), bad)
        }
    }

    func testRetentionMatchesNamesThePatternMakes() {
        let p = NoteFileName.defaultPattern
        XCTAssertTrue(NoteFileName.matches("2026-01-31 0905 Sync.md", pattern: p))
        XCTAssertTrue(NoteFileName.matches("2026-01-31 0905 Sync (3).md", pattern: p))
        XCTAssertFalse(NoteFileName.matches("Sync.md", pattern: p))
        XCTAssertFalse(NoteFileName.matches("0905 2026-01-31 Sync.md", pattern: p), "tokens in the pattern's order")
        XCTAssertFalse(NoteFileName.matches("2026-01-31 0905 Sync.txt", pattern: p))
        XCTAssertTrue(NoteFileName.matches("Anything.md", pattern: "{title}"))
    }

    func testUnicodeIsKeptAndComposed() {
        XCTAssertEqual(NoteFileName.sanitize("Cafe\u{301} 会議"), "Caf\u{e9} 会議")
    }

    func testCollisionsGetANumberCaseInsensitively() {
        let store = SpyStore()
        let folder = TranscriptFixture.folder
        store.files[folder.appendingPathComponent("A.md")] = ""
        store.files[folder.appendingPathComponent("a (2).md")] = ""
        XCTAssertEqual(NoteFileName.unique(base: "a", in: folder, store: store).lastPathComponent, "a (3).md")
        XCTAssertEqual(NoteFileName.unique(base: "b", in: folder, store: store, reserved: ["B.md"]).lastPathComponent, "b (2).md")
        XCTAssertEqual(NoteFileName.unique(base: "c", in: folder, store: store).lastPathComponent, "c.md")
    }
}

final class CallNoteTests: XCTestCase {
    func record() -> CallRecord {
        var r = CallRecord(callId: "call1", start: TranscriptFixture.start,
                           info: CallInfo(title: "Planning: \"Q1\"", app: "Zoom", participants: ["Guest A"], transcriber: "model-x"),
                           tags: ["meeting/transcript", "#team one"])
        r.lines = [TranscriptLine(speaker: .me, offset: 2, text: "Shall we start?"),
                   TranscriptLine(speaker: .others, offset: 65, text: "Yes,\nready.")]
        r.cues = [CueMark(type: CueType.interrupt.rawValue, offset: 70)]
        r.end = 1933
        return r
    }

    func testTheFullNote() {
        let md = CallNote.render(record(), labels: SpeakerLabels(), status: .complete, timeZone: TranscriptFixture.utc)
        XCTAssertEqual(md, """
        ---
        date: 2026-01-31
        start: 2026-01-31T09:05:07
        end: 2026-01-31T09:37:20
        duration: "00:32:13"
        meeting-app: "Zoom"
        title: "Planning: \\"Q1\\""
        participants:
          - "Guest A"
        speakers:
          - "You"
          - "Them"
        tags:
          - "meeting/transcript"
          - "team-one"
        transcriber: "model-x"
        coach-cues: 1
        transcript-status: complete
        meetingcard-call: "call1"
        meetingcard-saved: 1769852240
        ---

        ## Summary

        _Summary placeholder: add yours after the call._

        ## Coaching cues

        - [[#^l2|00:01:10]] Interruption

        ## Transcript

        **[00:00:02] You:** Shall we start? ^l1

        **[00:01:05] Them:** Yes, ready. ^l2

        """)
    }

    func testInProgressHasNoEndAndUnknownFieldsAreLeftOut() {
        var r = CallRecord(callId: "call2", start: TranscriptFixture.start)
        r.lines = []
        let md = CallNote.render(r, labels: SpeakerLabels(), status: .inProgress, timeZone: TranscriptFixture.utc)
        XCTAssertFalse(md.contains("end:"))
        XCTAssertFalse(md.contains("duration:"))
        XCTAssertFalse(md.contains("title:"))
        XCTAssertFalse(md.contains("participants:"), "participants only when known")
        XCTAssertTrue(md.contains("tags: []\n"))
        XCTAssertTrue(md.contains("speakers:\n  - \"You\"\n  - \"Them\"\n"), "both streams when nobody spoke yet")
        XCTAssertTrue(md.contains("coach-cues: 0\n"))
        XCTAssertTrue(md.contains("transcript-status: in-progress\n"))
        XCTAssertTrue(md.contains("_No coaching cues this call._"))
        XCTAssertTrue(md.contains("_Nothing was transcribed._"))
    }

    func testCuesLinkToTheLineTheyFellIn() {
        var r = record()
        r.cues = [CueMark(type: "monologue", offset: 1), CueMark(type: "missed_question", offset: 64), CueMark(type: "new_kind", offset: 999)]
        let md = CallNote.render(r, labels: SpeakerLabels(), status: .complete, timeZone: TranscriptFixture.utc)
        XCTAssertTrue(md.contains("- [[#^l1|00:00:01]] Long monologue\n"), "before the first line: the first line")
        XCTAssertTrue(md.contains("- [[#^l1|00:01:04]] Missed question\n"))
        XCTAssertTrue(md.contains("- [[#^l2|00:16:39]] new_kind\n"), "an unnamed cue type shows its key")
        XCTAssertTrue(md.contains("coach-cues: 3\n"))
    }

    func testBlockIdsFollowArrivalWhileLinesSortByTime() {
        var r = CallRecord(callId: "c", start: TranscriptFixture.start)
        r.lines = [TranscriptLine(speaker: .others, offset: 9, text: "late final"),
                   TranscriptLine(speaker: .me, offset: 4, text: "early start")]
        let md = CallNote.render(r, labels: SpeakerLabels(), status: .complete, timeZone: TranscriptFixture.utc)
        let early = md.range(of: "early start ^l2")!.lowerBound
        let late = md.range(of: "late final ^l1")!.lowerBound
        XCTAssertLessThan(early, late)
    }

    func testThemVoicesAreNumberedWhenKnown() {
        var r = CallRecord(callId: "c", start: TranscriptFixture.start)
        r.lines = [TranscriptLine(speaker: .others, offset: 1, text: "a", themIndex: 1),
                   TranscriptLine(speaker: .others, offset: 2, text: "b", themIndex: 2),
                   TranscriptLine(speaker: .me, offset: 3, text: "c")]
        var labels = SpeakerLabels()
        let md = CallNote.render(r, labels: labels, status: .complete, timeZone: TranscriptFixture.utc)
        XCTAssertTrue(md.contains("**[00:00:01] Them 1:** a"))
        XCTAssertTrue(md.contains("**[00:00:02] Them 2:** b"))
        XCTAssertTrue(md.contains("speakers:\n  - \"Them 1\"\n  - \"Them 2\"\n  - \"You\"\n"))
        labels.rename(.others, to: "Guest")
        XCTAssertTrue(CallNote.render(r, labels: labels, status: .complete, timeZone: TranscriptFixture.utc).contains("] Guest 2:** b"))
    }

    func testGapsAreMarkedInTheTranscript() {
        var r = CallRecord(callId: "c", start: TranscriptFixture.start)
        r.lines = [TranscriptLine(speaker: .others, offset: 30, text: "still here")]
        r.openGap(.youMuted, at: 10)
        r.closeGap(.youMuted, at: 40)
        r.openGap(.paused, at: 50)
        r.openGap(.transcriberStopped, at: 60, detail: "error")
        r.closeAllGaps(at: 75)
        r.openGap(.appQuit, at: 75)
        let md = CallNote.render(r, labels: SpeakerLabels(), status: .recovered, timeZone: TranscriptFixture.utc)
        let expected = """
        ## Transcript

        *[00:00:10–00:00:40] Coach mic off: no You text.*

        **[00:00:30] Them:** still here ^l1

        *[00:00:50–00:01:15] Coach paused: nothing transcribed.*

        *[00:01:00–00:01:15] Transcription stopped (transcriber error).*

        *[00:01:15–] The app quit during the call; this transcript was recovered and ends here.*

        """
        XCTAssertTrue(md.hasSuffix(expected), md)
        XCTAssertTrue(md.contains("transcript-status: recovered"))
    }

    func testTranscriptTextNeverBecomesObsidianSyntax() {
        var r = CallRecord(callId: "c", start: TranscriptFixture.start)
        r.lines = [TranscriptLine(speaker: .others, offset: 1, text: "see [[Other note]] #tag ^abc %%hidden%% $x$ ==hi== <b>")]
        let md = CallNote.render(r, labels: SpeakerLabels(), status: .complete, timeZone: TranscriptFixture.utc)
        XCTAssertTrue(md.contains(##"see \[\[Other note\]\] \#tag \^abc \%\%hidden\%\% \$x\$ \=\=hi\=\= \<b\> ^l1"##), md)
    }

    func testYamlQuotingHandlesAnyText() {
        XCTAssertEqual(CallNote.yaml("a: b"), "\"a: b\"")
        XCTAssertEqual(CallNote.yaml("- x"), "\"- x\"")
        XCTAssertEqual(CallNote.yaml("q\"\\\n\t\u{1}"), "\"q\\\"\\\\\\n\\t\\u0001\"")
    }

    func testTags() {
        XCTAssertEqual(CallNote.tag("#meeting/transcript"), "meeting/transcript")
        XCTAssertEqual(CallNote.tag("two words"), "two-words")
        XCTAssertEqual(CallNote.tag("a!b@c"), "abc")
        XCTAssertNil(CallNote.tag("2026"), "a tag can't be all digits")
        XCTAssertNil(CallNote.tag("###"))
        XCTAssertEqual(CallNote.tags(fromSetting: "meeting/transcript, #calls  calls"), ["meeting/transcript", "calls"])
    }

    func testPropertiesReadBack() {
        let md = CallNote.render(record(), labels: SpeakerLabels(), status: .complete, timeZone: TranscriptFixture.utc)
        let p = CallNote.properties(md)
        XCTAssertEqual(p["meetingcard-call"], "call1")
        XCTAssertEqual(p["start"], "2026-01-31T09:05:07")
        XCTAssertNil(p["tags"].flatMap { $0.isEmpty ? nil : $0 }, "lists are not flattened")
        XCTAssertEqual(CallNote.properties("no front matter"), [:])
    }
}

/// Mute, pause, the call app's mute, transcriber stops and retries, as the live transcript marks them.
final class GapMarkingTests: XCTestCase {
    func make() -> (LiveTranscript, SpyStore, SteppedClock) {
        let store = SpyStore()
        let clock = SteppedClock(TranscriptFixture.start)
        let live = LiveTranscript(settings: .init(saving: true, folder: TranscriptFixture.folder, keyUsable: true),
                                  store: store, timeZone: TranscriptFixture.utc, clock: { clock.now })
        return (live, store, clock)
    }

    func testMuteMarksNoYouTextAndThemGoesOn() throws {
        let (live, store, clock) = make()
        live.callStarted()
        clock.advance(10)
        live.observe(CallConditions(youMuted: true))
        clock.advance(5)
        live.receive(.final(.others, text: "Them still talks."))
        clock.advance(15)
        live.observe(CallConditions())
        live.callEnded()
        let md = try XCTUnwrap(store.note)
        XCTAssertTrue(md.contains("*[00:00:10–00:00:30] Coach mic off: no You text.*"))
        XCTAssertTrue(md.contains("**[00:00:15] Them:** Them still talks."))
    }

    func testPauseAndTheCallAppsMuteAreSeparateGaps() throws {
        let (live, store, clock) = make()
        live.callStarted()
        clock.advance(5)
        live.observe(CallConditions(paused: true))
        clock.advance(5)
        live.observe(CallConditions(paused: true, appMuted: true))
        live.observe(CallConditions(paused: true, appMuted: true))
        clock.advance(5)
        live.observe(CallConditions(appMuted: true))
        clock.advance(5)
        live.callEnded()
        let md = try XCTUnwrap(store.note)
        XCTAssertTrue(md.contains("*[00:00:05–00:00:15] Coach paused: nothing transcribed.*"))
        XCTAssertTrue(md.contains("*[00:00:10–00:00:20] Muted in the call app: nothing transcribed.*"), "open at the end: closed at the call's end")
        XCTAssertEqual(md.components(separatedBy: "Coach paused").count - 1, 1, "a repeat opens nothing")
    }

    func testConditionsAtTheStartAreMarkedFromZero() throws {
        let (live, store, clock) = make()
        live.observe(CallConditions(youMuted: true))
        live.callStarted()
        clock.advance(8)
        live.callEnded()
        XCTAssertTrue(try XCTUnwrap(store.note).contains("*[00:00:00–00:00:08] Coach mic off: no You text.*"))
    }

    func testRetriesAndReconnectsAreMarked() throws {
        let (live, store, clock) = make()
        live.callStarted()
        clock.advance(3)
        live.observe(CallConditions(transcriberRetrying: true))
        clock.advance(4)
        live.observe(CallConditions(callAudioReconnecting: true))
        clock.advance(2)
        live.observe(CallConditions())
        live.callEnded()
        let md = try XCTUnwrap(store.note)
        XCTAssertTrue(md.contains("*[00:00:03–00:00:07] Transcription reconnecting.*"))
        XCTAssertTrue(md.contains("*[00:00:07–00:00:09] Call audio reconnecting.*"))
    }

    func testCuesAreCountedAndTimed() throws {
        let (live, store, clock) = make()
        live.callStarted()
        live.receive(.final(.me, text: "Let me finish."))
        clock.advance(12)
        live.cue(.interrupt)
        live.cue(.monologue)
        live.callEnded()
        let md = try XCTUnwrap(store.note)
        XCTAssertTrue(md.contains("coach-cues: 2\n"))
        XCTAssertTrue(md.contains("- [[#^l1|00:00:12]] Interruption\n- [[#^l1|00:00:12]] Long monologue\n"))
    }

    func testCallInfoFillsTheNameAndProperties() throws {
        let (live, store, _) = make()
        live.setCallInfo(CallInfo(title: "Design review", app: "Zoom", transcriber: "model-x"))
        live.callStarted()
        live.callEnded()
        let (url, md) = try XCTUnwrap(store.notes.first)
        XCTAssertEqual(url.lastPathComponent, "2026-01-31 0905 Design review.md")
        XCTAssertTrue(md.contains("meeting-app: \"Zoom\"\ntitle: \"Design review\"\n"))
        XCTAssertTrue(md.contains("transcriber: \"model-x\"\n"))
        XCTAssertEqual(live.callInfo, CallInfo(), "details last one call")
    }
}
