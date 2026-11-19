import XCTest
@testable import ListenMoreCore

final class SpeakerTests: XCTestCase {
    private func embedding(_ values: [Float], model: String = "synthetic") throws -> SpeakerEmbedding {
        try XCTUnwrap(SpeakerEmbedding(model: model, values: values))
    }

    func testClustersReuseNumbersAndKeepEmbeddingSpacesSeparate() throws {
        var clusters = SpeakerClusters()
        XCTAssertEqual(clusters.assign(try embedding([1, 0, 0]))?.number, 1)
        XCTAssertEqual(clusters.assign(try embedding([0, 1, 0]))?.number, 2)
        XCTAssertEqual(clusters.assign(try embedding([0.9, 0.1, 0]))?.number, 1)
        XCTAssertEqual(clusters.assign(try embedding([1, 0, 0], model: "other"))?.number, 3)
        XCTAssertEqual(clusters.assign(try embedding([0.1, 0.9, 0]))?.number, 2)
        XCTAssertNil(SpeakerEmbedding(model: "synthetic", values: [.nan, 1]))
        XCTAssertNil(SpeakerEmbedding(model: "synthetic", values: [0, 0]))
    }

    func testLocalFallbackEmbedsVoiceLikeSignalButNotSilence() throws {
        let rate = 16_000
        let signal = (0..<rate).map { i -> Float in
            let t = Double(i) / Double(rate)
            return Float(0.12 * sin(2 * .pi * 180 * t) + 0.04 * sin(2 * .pi * 540 * t))
        }
        let mfcc = MFCCSpeakerEmbedder()
        let a = try XCTUnwrap(mfcc.embed(signal, sampleRate: rate))
        let b = try XCTUnwrap(mfcc.embed(signal.map { $0 / 2 }, sampleRate: rate))
        XCTAssertEqual(a.values.count, 26)
        XCTAssertGreaterThan(try XCTUnwrap(a.similarity(to: b)), 0.95)
        XCTAssertNil(mfcc.embed(Array(repeating: 0, count: rate), sampleRate: rate))
    }

    func testProfileMatchAcrossReopenRenameDisableAndDelete() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("speaker-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let a = try embedding([1, 0]), b = try embedding([0, 1])
        let store = SpeakerProfiles(folder: folder)
        XCTAssertNil(store.match(a))
        try store.setEnabled(true)
        let alice = try store.save(name: "  Guest   A ", embedding: a)
        let bob = try store.save(name: "Guest B", embedding: b)
        XCTAssertEqual(store.match(try embedding([1, 1])), nil)
        XCTAssertNil(store.match(a, excluding: [alice.id]))
        try store.setEnabled(false)
        XCTAssertNil(store.match(a))
        XCTAssertTrue(store.profiles.isEmpty)

        let reopened = SpeakerProfiles(folder: folder)
        try reopened.setEnabled(true)
        XCTAssertEqual(reopened.match(try embedding([1, 0.1])), alice)
        XCTAssertEqual(reopened.match(b), bob)
        try reopened.rename(alice.id, to: "New tag")
        XCTAssertEqual(reopened.match(a)?.name, "New tag")
        try reopened.delete(bob.id)
        XCTAssertNil(reopened.match(b))
        try reopened.delete(alice.id)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.appendingPathComponent("SpeakerProfiles.json").path))
        try reopened.deleteAll()
    }

    func testLiveNamesReachCaptionAndSavedTranscriptWithoutReplacingTemporaryRename() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("speaker-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        let profiles = SpeakerProfiles(folder: folder.appendingPathComponent("VoiceProfiles"))
        let voice = try embedding([1, 0])
        try profiles.setEnabled(true)
        let saved = try profiles.save(name: "Guest", embedding: voice)
        let live = LiveTranscript(settings: .init(captions: true, saving: true, folder: folder, keyUsable: true),
                                  store: FileTranscriptStore(), speakerProfiles: profiles)
        live.callStarted()
        live.receive(.speakerEmbedding(.other(1), voice))
        live.receive(.partial(.other(1), item: "a", text: "Partial one"))
        live.receive(.partial(.other(1), item: "b", text: "Partial two"))
        live.receive(.final(.other(1), text: "Final two", item: "b"))
        live.receive(.final(.other(2), text: "Different speaker", item: "c"))
        XCTAssertEqual(live.captions.lines.map { live.labels.label($0.speaker) }, ["Guest", "Speaker 2"])
        XCTAssertEqual(live.captions.lines.first?.pending.map(\.item), ["a"])
        let url = try XCTUnwrap(live.recorder.lastURL)
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("Guest:** Final two"))
        live.rename(.other(2), to: "Temporary")
        XCTAssertTrue(try String(contentsOf: url, encoding: .utf8).contains("Temporary:** Different speaker"))
        try profiles.delete(saved.id)
        live.refreshVoiceProfiles()
        XCTAssertEqual(live.labels.label(.other(1)), "Speaker 1")
        live.callEnded()
        XCTAssertEqual(live.labels.label(.other(2)), "Speaker 2")
        XCTAssertTrue(live.callSpeakers.isEmpty)
    }

    func testJudgeGetsStableAnonymousLabelsAndRedactsSavedNames() throws {
        let core = GptCore(config: try TestConfig.load())
        _ = core.onText(.other(1), text: "Guest A made a point.", refT: 0, now: 0)
        _ = core.onText(.other(2), text: "I agree.", refT: 1, now: 1)
        let names = ["Guest A"]
        let lines = core.judgeWindow(now: 1, privateNames: names)
        XCTAssertEqual(lines.map(\.speaker), [.other(1), .other(2)])
        XCTAssertEqual(lines.first?.text, "[name] made a point.")
        let prompt = core.buildPrompt(.init(refT: 1, reason: "me_reply"), now: 1, privateNames: names)
        XCTAssertTrue(prompt.contains("OTHERS (Speaker 1): [name] made a point."))
        XCTAssertTrue(prompt.contains("OTHERS (Speaker 2): I agree."))
    }

    private struct SignEmbedder: SpeakerEmbedder {
        func embed(_ samples: [Float], sampleRate: Int) -> SpeakerEmbedding? {
            SpeakerEmbedding(model: "synthetic", values: samples[0] > 0 ? [1, 0] : [0, 1])
        }
    }

    func testResumingCaptureKeepsSpeakerNumbersEvenIfTheSpeakersSwitchOrder() async throws {
        let config = try TestConfig.load()
        let call = SpeakerCallClusters(embedder: SignEmbedder())
        let rate = config.audio.sampleRate
        func say(_ sample: Float, offset: TimeInterval, turns: inout SpeakerTurns) async -> Speaker? {
            await turns.observe(Array(repeating: sample, count: rate), vad: GptFrames.vad(raw: true, onset: offset - 1))
            await turns.observe([], vad: GptFrames.vad(raw: false, offset: offset))
            return turns.attribution(at: offset, announce: false)?.speaker
        }

        let firstCapture = call.openCapture()
        var first = SpeakerTurns(embedder: call.embedder, config: config)
        first.call = (call, firstCapture)
        let firstA = await say(0.3, offset: 1, turns: &first)
        let firstB = await say(-0.3, offset: 3, turns: &first)
        XCTAssertEqual(firstA, .other(1))
        XCTAssertEqual(firstB, .other(2))

        call.closeCapture()
        XCTAssertFalse(call.admits(firstCapture))
        var resumed = SpeakerTurns(embedder: call.embedder, config: config)
        resumed.call = (call, call.openCapture())
        let resumedB = await say(-0.3, offset: 1, turns: &resumed)
        let resumedA = await say(0.3, offset: 3, turns: &resumed)
        XCTAssertEqual(resumedB, firstB, "resuming resets audio offsets but not the speaker identities")
        XCTAssertEqual(resumedA, firstA)
        XCTAssertNil(call.assign(try embedding([0, 1]), capture: firstCapture), "stale inference cannot write to the resumed call")

        let newCall = SpeakerCallClusters(embedder: call.embedder)
        var next = SpeakerTurns(embedder: newCall.embedder, config: config)
        next.call = (newCall, newCall.openCapture())
        let nextB = await say(-0.3, offset: 1, turns: &next)
        XCTAssertEqual(nextB, .other(1), "only a new call starts numbering over")
    }

    func testCallVadLabelsPartialsAndFinalsUsingTheirCommitOffset() async throws {
        let config = try TestConfig.load()
        let box = CaptionFeedTests.CaptionBox()
        let layer = GptLayer(config: config, now: { 0 }, offer: { _, _, _, _ in }, onCaption: { box.add($0) },
                             speakerEmbedder: SignEmbedder(), provider: nil, scheduler: InstantScheduler()) { speaker, sink in
            TurnTranscriber(speaker: speaker, sink: sink)
        }
        layer.start()
        let hop = config.audio.sampleRate * config.audio.frameMs / 1000
        for (i, sample) in [Float(0.3), -0.3, 0.3].enumerated() {
            let frame = Array(repeating: sample, count: hop)
            for f in 0..<(config.audio.sampleRate / hop) {
                layer.feed(me: GptFrames.silent, meVad: GptFrames.quiet, others: frame,
                           othersVad: GptFrames.vad(raw: true, onset: f == 0 ? Double(i) * 2 : nil), meRunS: 0)
            }
            layer.feed(me: GptFrames.silent, meVad: GptFrames.quiet, others: GptFrames.silent,
                       othersVad: GptFrames.vad(raw: false, offset: Double(i) * 2 + 1), meRunS: 0)
        }
        let delivered = await eventually { box.events.count == 6 }
        await layer.close()
        XCTAssertTrue(delivered)
        XCTAssertEqual(box.events, [1, 3, 5].enumerated().flatMap { i, offset in
            let speaker = Speaker.other(i == 1 ? 2 : 1), item = "turn-\(offset)"
            return [CaptionEvent.partial(speaker, item: item, text: "Partial"), .final(speaker, text: "Final", item: item)]
        })
    }

    private final class TurnTranscriber: TranscriptionSession {
        let speaker: Speaker
        let sink: @Sendable (TranscriptEvent) -> Void
        init(speaker: Speaker, sink: @escaping @Sendable (TranscriptEvent) -> Void) {
            self.speaker = speaker
            self.sink = sink
        }
        func start() async throws {}
        func sendAudio(_ pcm: Data) async throws {}
        func commit(refT: TimeInterval) async throws {
            let item = "turn-\(Int(refT))"
            sink(.turnDelta(speaker, "Partial", item: item, refT: refT))
            sink(.turnText(speaker, "Final", item: item, refT: refT))
        }
        func clear() async throws {}
        func close() async {}
    }
}
