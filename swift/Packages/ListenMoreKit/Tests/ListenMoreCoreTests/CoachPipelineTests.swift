import XCTest
@testable import ListenMoreCore

/// GPT stand-in for the pipeline: records what it is fed and hands out queued outputs.
final class StubPipelineGpt: PipelineGpt {
    var queued: [GptOutput] = []
    var locals: [LocalEvent.Kind] = []
    var frames = 0
    var micMutes: [Bool] = []

    func onLocal(_ event: LocalEvent) { locals.append(event.kind) }
    func feed(me: [Float], meVad: VadState, others: [Float], othersVad: VadState, meRunS: Double) { frames += 1 }
    func setMicMuted(_ muted: Bool) { micMutes.append(muted) }
    func drain(now: TimeInterval) -> [GptOutput] {
        defer { queued.removeAll() }
        return queued
    }
}

final class CoachPipelineTests: XCTestCase {
    var config: ListenMoreConfig!

    override func setUpWithError() throws {
        config = try TestConfig.load()
    }

    func cut(t: Double = 4, onset: Double = 3, othersActive: Bool? = false, othersLast: Double? = 3.8, trailing: Bool = false) -> LocalEvent {
        LocalEvent(kind: .interrupt, t: t, onset: onset, othersActive: othersActive, othersLastSpeech: othersLast, trailing: trailing)
    }

    func verdict(_ ev: LocalEvent, at t: Double, _ text: TextRules?) -> CoachPipeline.CutInVerdict {
        CoachPipeline.cutInVerdict(ev, t: t, text: text, waitS: 1.0)
    }

    // MARK: cut-in verdicts

    func testWithoutTranscriptsACutInFiresAndATrailingOneDrops() {
        XCTAssertEqual(verdict(cut(), at: 4, nil), .fire)
        XCTAssertEqual(verdict(cut(trailing: true), at: 6, nil), .drop)
    }

    func testCutInThatAnswersAQuestionIsDropped() {
        let text = TextRules(config: config)
        _ = text.onSegment(.others, text: "What do you think?", refT: 2.8, now: 3.2)
        XCTAssertEqual(verdict(cut(othersActive: true), at: 4, text), .drop)
        XCTAssertEqual(verdict(cut(trailing: true), at: 6, text), .drop)
    }

    func testCutInFiresWhileTheyAreStillTalking() {
        XCTAssertEqual(verdict(cut(othersActive: true), at: 4, TextRules(config: config)), .fire)
    }

    func testCutInWaitsForTheirLastWordsThenFires() {
        let text = TextRules(config: config)
        XCTAssertEqual(verdict(cut(), at: 4.5, text), .wait)
        XCTAssertEqual(verdict(cut(), at: 5.0, text), .fire, "no transcript within cut_in_text_wait_ms")
        _ = text.onSegment(.others, text: "So the plan for next week is", refT: 3.8, now: 4.4)
        XCTAssertEqual(verdict(cut(), at: 4.5, text), .fire, "their words arrived and were not a question")
    }

    func testTrailingCutInFiresOnlyWhenTheirWordsWereUnfinished() {
        let ev = cut(t: 5.3, onset: 3, othersLast: 3.4, trailing: true)
        let text = TextRules(config: config)
        XCTAssertEqual(verdict(ev, at: 5.5, text), .wait)
        XCTAssertEqual(verdict(ev, at: 6.3, text), .drop, "no transcript in time")
        _ = text.onSegment(.others, text: "We could ship it now but", refT: 3.4, now: 4.0)
        XCTAssertEqual(verdict(ev, at: 5.5, text), .fire)
        let done = TextRules(config: config)
        _ = done.onSegment(.others, text: "We could ship it now.", refT: 3.4, now: 4.0)
        XCTAssertEqual(verdict(ev, at: 5.5, done), .drop)
    }

    // MARK: pipeline

    let silence = [Float](repeating: 0, count: 480)

    func step(_ p: CoachPipeline, _ t: Double) -> [Cue] {
        p.process(t: t, mic: silence[...], call: silence[...])
    }

    func testLocalOnlyPipelineHasNoTranscriptRules() {
        let p = CoachPipeline(config: config, gpt: nil)
        XCTAssertNil(p.text)
        XCTAssertEqual(step(p, 0.02), [])
    }

    func testJudgeVerdictBecomesAGptCue() throws {
        let gpt = StubPipelineGpt()
        let p = CoachPipeline(config: config, gpt: gpt)
        gpt.queued = [.offer(label: "not_listening", t: 9.9, refT: 9.5, confidence: 0.9),
                      .offer(label: "none", t: 9.9, refT: 9.5, confidence: 0.9)]
        let cue = try XCTUnwrap(step(p, 10).first)
        XCTAssertEqual(cue.type, .notListening)
        XCTAssertEqual(cue.source, .gpt)
        XCTAssertEqual(cue.onset, 9.5)
        XCTAssertEqual(gpt.frames, 1)
    }

    func testSegmentsFeedTheTranscriptRulesAndTheirCuesGoThroughThePolicy() throws {
        let gpt = StubPipelineGpt()
        let p = CoachPipeline(config: config, gpt: gpt)
        gpt.queued = [.segment(.others, "Can you send the report by Friday?", refT: 1, now: 1.5)]
        XCTAssertEqual(step(p, 1.5), [])
        gpt.queued = [.segment(.me, "Well I was thinking about the garden over the long weekend", refT: 4, now: 4.5)]
        let cue = try XCTUnwrap(step(p, 4.5).first)
        XCTAssertEqual(cue.type, .missedQuestion)
        XCTAssertEqual(cue.level, .soft)
        XCTAssertEqual(cue.source, .text)
    }

    func testClosingPhraseHoldsCues() {
        let gpt = StubPipelineGpt()
        let p = CoachPipeline(config: config, gpt: gpt)
        gpt.queued = [.segment(.others, "Okay, bye everyone.", refT: 1, now: 1.2),
                      .offer(label: "not_listening", t: 1.2, refT: 1, confidence: 0.95)]
        XCTAssertEqual(step(p, 1.2), [])
        XCTAssertEqual(p.policy.held.map(\.why), [.closing])
    }

    func testOneCueAtATimeAcrossSources() {
        let gpt = StubPipelineGpt()
        let p = CoachPipeline(config: config, gpt: gpt)
        gpt.queued = [.offer(label: "not_listening", t: 5, refT: 4.5, confidence: 0.95)]
        XCTAssertEqual(step(p, 5).count, 1)
        gpt.queued = [.offer(label: "not_listening", t: 12, refT: 11, confidence: 0.95)]
        XCTAssertEqual(step(p, 12), [])
        XCTAssertEqual(p.policy.held.last?.why, .global)
    }

    func testCutInOnRealAudioWithoutGptFiresAtOnce() {
        let mic = Synthetic.track(8, [(3.0, 6.0)], f0: 120), call = Synthetic.track(8, [(1.0, 5.5)], f0: 210)
        let p = CoachPipeline(config: config, gpt: nil)
        let hop = config.frameSamples
        var cues: [Cue] = []
        for i in 0..<(mic.count / hop) {
            cues += p.process(t: Double(i + 1) * config.frameS, mic: mic[(i * hop)..<((i + 1) * hop)], call: call[(i * hop)..<((i + 1) * hop)])
        }
        XCTAssertEqual(cues.map(\.type), [.interrupt])
        XCTAssertEqual(cues.first?.source, .local)
    }

    func testClearDropsTranscriptState() {
        let gpt = StubPipelineGpt()
        let p = CoachPipeline(config: config, gpt: gpt)
        gpt.queued = [.segment(.others, "What do you think?", refT: 1, now: 1.2)]
        _ = step(p, 1.2)
        XCTAssertTrue(p.text?.questionNear(2) ?? false)
        p.clear()
        XCTAssertFalse(p.text?.questionNear(2) ?? true)
    }
}
