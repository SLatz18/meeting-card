import XCTest
@testable import ListenMoreCore

/// Caption line merging and speaker labels. Synthetic, content-free text only.
final class CaptionBufferTests: XCTestCase {
    func texts(_ b: CaptionBuffer) -> [String] { b.lines.map(\.text) }

    func testPartialsBuildALineAndTheFinalTextReplacesThem() {
        var b = CaptionBuffer()
        b.apply(.partial(.others, item: "a", text: "alpha "), at: 1)
        b.apply(.partial(.others, item: "a", text: "bravo"), at: 1.2)
        XCTAssertEqual(texts(b), ["alpha bravo"])
        XCTAssertFalse(b.lines[0].isFinal)
        b.apply(.final(.others, text: "Alpha bravo."), at: 1.5)
        XCTAssertEqual(texts(b), ["Alpha bravo."])
        XCTAssertTrue(b.lines[0].isFinal)
    }

    func testSameSpeakerTurnsMergeWithinTheGapAndSplitAfterIt() {
        var b = CaptionBuffer(mergeGapS: 4)
        b.apply(.final(.me, text: "one"), at: 1)
        b.apply(.final(.me, text: "two"), at: 4)
        XCTAssertEqual(texts(b), ["one two"], "within the gap: one line")
        b.apply(.final(.me, text: "three"), at: 9)
        XCTAssertEqual(texts(b), ["one two", "three"], "past the gap: a new line")
    }

    func testASpeakerChangeStartsANewLine() {
        var b = CaptionBuffer()
        b.apply(.final(.me, text: "one"), at: 1)
        b.apply(.partial(.others, item: "x", text: "two"), at: 1.1)
        b.apply(.final(.me, text: "three"), at: 1.2)
        XCTAssertEqual(b.lines.map(\.speaker), [.me, .others, .me])
        XCTAssertEqual(texts(b), ["one", "two", "three"])
    }

    func testTurnsFinishInOrderPerSpeaker() {
        var b = CaptionBuffer()
        b.apply(.partial(.others, item: "a", text: "first"), at: 1)
        b.apply(.partial(.others, item: "b", text: "second"), at: 2)
        XCTAssertEqual(texts(b), ["first second"])
        b.apply(.final(.others, text: "First."), at: 2.5)
        XCTAssertEqual(texts(b), ["First. second"])
        b.apply(.final(.others, text: "Second."), at: 3)
        XCTAssertEqual(texts(b), ["First. Second."])
        XCTAssertTrue(b.lines[0].isFinal)
    }

    func testAnEmptyFinalDropsItsPartialLine() {
        var b = CaptionBuffer()
        b.apply(.partial(.me, item: "a", text: "uh"), at: 1)
        b.apply(.final(.me, text: "  "), at: 1.2)
        XCTAssertEqual(b.lines, [])
        b.apply(.final(.me, text: ""), at: 2)
        XCTAssertEqual(b.lines, [], "an empty final with nothing pending adds nothing")
    }

    func testBoundedLinesAndLineLength() {
        var b = CaptionBuffer(maxLines: 2, maxLineChars: 10, mergeGapS: 100)
        b.apply(.final(.me, text: "aaaa bbbb cc"), at: 1)
        b.apply(.final(.me, text: "dd"), at: 2)
        XCTAssertEqual(texts(b), ["aaaa bbbb cc", "dd"], "a full line takes no more merges")
        b.apply(.final(.others, text: "ee"), at: 3)
        XCTAssertEqual(texts(b), ["dd", "ee"], "only the last maxLines lines are kept")
        b.clear()
        XCTAssertEqual(b.lines, [])
    }
}

final class SpeakerLabelsTests: XCTestCase {
    func testDefaultsAreYouAndThem() {
        let l = SpeakerLabels()
        XCTAssertEqual(l.label(.me), "You")
        XCTAssertEqual(l.label(.others), "Them")
        XCTAssertFalse(l.isTagged)
    }

    func testTagsAreCleanedAndResettable() {
        var l = SpeakerLabels()
        l.rename(.others, to: "  Guest\n  two\t")
        XCTAssertEqual(l.label(.others), "Guest two")
        l.rename(.me, to: String(repeating: "x", count: 50))
        XCTAssertEqual(l.label(.me).count, SpeakerLabels.maxLength)
        l.rename(.others, to: "   ")
        XCTAssertEqual(l.label(.others), "Them", "a blank tag restores the default")
        l.rename(.others, to: "Team B")
        l.reset()
        XCTAssertEqual(l, SpeakerLabels())
    }
}

final class CaptionFeedTests: XCTestCase {
    func testTranscriberForwardsDeltasWithTheirItem() async throws {
        let config = try TestConfig.load()
        let connector = FakeConnector()
        let events = EventBox()
        let tx = LiveTranscriber(config: config, key: APIKey("sk-test-rt")!, speaker: .me, connector: connector) { events.append($0) }
        try await tx.start()
        let socket = try XCTUnwrap(connector.connections.first).socket
        socket.push(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"i7","content_index":0,"delta":"Hello,"}"#)
        socket.push(#"{"type":"conversation.item.input_audio_transcription.delta","item_id":"i7","content_index":0,"delta":""}"#)
        let got = await eventually { events.deltas.count == 1 }
        XCTAssertTrue(got)
        XCTAssertEqual(events.deltas.first?.0, .me)
        XCTAssertEqual(events.deltas.first?.1, "Hello,")
        XCTAssertEqual(events.deltas.first?.2, "i7")
        await tx.close()
    }

    final class CaptionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [CaptionEvent] = []
        private var _meters: [CostReading] = []
        var events: [CaptionEvent] { lock.withLock { _events } }
        var meters: [CostReading] { lock.withLock { _meters } }
        func add(_ e: CaptionEvent) { lock.withLock { _events.append(e) } }
        func meter(_ r: CostReading) { lock.withLock { _meters.append(r) } }
    }

    func layer(_ config: ListenMoreConfig, box: CaptionBox, me: [String], others: [String] = []) -> GptLayer {
        let l = GptLayer(config: config, now: { 0 }, offer: { _, _, _, _ in }, onCaption: { box.add($0) },
                         onMeter: { box.meter($0) }, judge: FakeJudge(), scheduler: InstantScheduler()) { speaker, onEvent in
            let t = FakeTranscriber(speaker: speaker, script: speaker == .me ? me : others, onEvent: onEvent)
            t.deltas = true
            t.billedPerCommit = 1
            return t
        }
        l.start()
        return l
    }

    func say(_ l: GptLayer, onset: TimeInterval, offset: TimeInterval) {
        let v = GptFrames.voiced, z = GptFrames.silent
        l.feed(me: v, meVad: GptFrames.vad(raw: true, onset: onset), others: z, othersVad: GptFrames.quiet, meRunS: 0)
        l.feed(me: z, meVad: GptFrames.vad(raw: false, offset: offset), others: z, othersVad: GptFrames.quiet, meRunS: 0)
    }

    func testTheLayerSendsPartialsThenTheFinalTextAndTheMeter() async throws {
        let config = try TestConfig.load()
        let box = CaptionBox()
        let l = layer(config, box: box, me: ["alpha bravo"])
        say(l, onset: 1, offset: 2)
        let got = await eventually { box.events.count == 3 }
        XCTAssertTrue(got)
        XCTAssertEqual(box.events, [.partial(.me, item: "item1", text: "alpha "), .partial(.me, item: "item1", text: "bravo "),
                                    .final(.me, text: "alpha bravo")])
        XCTAssertEqual(box.meters.last?.billedAudioS, 1)
        XCTAssertEqual(box.meters.last?.transcriptUsd, 0, "captions and the transcript reuse the cue transcription")
        await l.close()
    }

    func testTheCostCapStopsCaptions() async throws {
        var config = try TestConfig.load()
        // One billed second fits; the second turn's first voiced frame takes the meter past the cap.
        config.gpt.budgetUsdPerCall = 1.5 * config.gpt.pricesUsd.transcribePerMinute / 60
        let box = CaptionBox()
        let l = layer(config, box: box, me: ["alpha", "bravo"])
        say(l, onset: 1, offset: 2)
        let first = await eventually { box.events.count == 2 }
        XCTAssertTrue(first)
        say(l, onset: 3, offset: 4)
        let stopped = await eventually { await !l.snapshot().enabled }
        XCTAssertTrue(stopped)
        let snap = await l.snapshot()
        XCTAssertTrue(snap.budgetExhausted)
        XCTAssertEqual(box.events, [.partial(.me, item: "item1", text: "alpha "), .final(.me, text: "alpha")],
                       "nothing after the cap")
        XCTAssertEqual(box.meters.count, 2, "the billed segment, then the stop")
        await l.close()
    }
}
