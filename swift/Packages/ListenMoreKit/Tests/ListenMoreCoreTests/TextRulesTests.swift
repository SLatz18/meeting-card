import XCTest
@testable import ListenMoreCore

/// Transcript rules on generic sentences: question pending, heat, closing quiet and the checks the
/// local layer and the cut-in verdict ask for.
final class TextRulesTests: XCTestCase {
    var config: ListenMoreConfig!

    override func setUpWithError() throws {
        config = try TestConfig.load()
    }

    func rules(participants: Int = 2, offset: Double = 0) -> TextRules {
        TextRules(config: config, participants: participants, meetingOffsetS: offset)
    }

    func types(_ cs: [CueSuggestion]) -> [CueType] { cs.map(\.type) }

    /// The user is quiet from `from` to `to`, one frame at a time.
    func quiet(_ r: TextRules, from: Double, to: Double) -> [CueSuggestion] {
        var out: [CueSuggestion] = []
        var t = from
        while t <= to + 1e-9 {
            out += r.onTick(now: t, userActive: false, frameS: 0.02)
            t += 0.02
        }
        return out
    }

    // MARK: question pending

    func testUnansweredQuestionGetsASoftCueOnceTheReplyDrifts() throws {
        let r = rules()
        XCTAssertEqual(r.onSegment(.others, text: "Can you send the report by Friday?", refT: 1, now: 1.5), [])
        let cues = r.onSegment(.me, text: "Well I was thinking about the garden over the long weekend", refT: 4, now: 4.5)
        let cue = try XCTUnwrap(cues.first)
        XCTAssertEqual(cue.type, .missedQuestion)
        XCTAssertEqual(cue.level, .soft)
        XCTAssertEqual(cue.source, .text)
        XCTAssertEqual(cue.onset, 4)
    }

    func testDirectAnswerOrSharedContentClearsTheQuestion() {
        for reply in ["Yes, no problem.", "3 pages at most.", "The report will be ready Friday."] {
            let r = rules()
            _ = r.onSegment(.others, text: "Can you send the report by Friday?", refT: 1, now: 1.5)
            XCTAssertEqual(r.onSegment(.me, text: reply, refT: 3, now: 3.5), [], reply)
            XCTAssertEqual(r.outcomes.questionCleared, 1, reply)
            XCTAssertEqual(quiet(r, from: 4, to: 10), [], reply)
        }
    }

    func testOpenInvitationAcceptsAnyReply() {
        let r = rules()
        _ = r.onSegment(.others, text: "Any thoughts?", refT: 1, now: 1.2)
        XCTAssertEqual(r.onSegment(.me, text: "Mostly that the timeline looks tight to me overall", refT: 3, now: 3.5), [])
        XCTAssertEqual(r.outcomes.questionCleared, 1)
    }

    func testStatementsAndUnaddressedGroupQuestionsAreNotPending() {
        let r = rules()
        _ = r.onSegment(.others, text: "We shipped the build yesterday.", refT: 1, now: 1.5)
        XCTAssertEqual(r.onSegment(.me, text: "Well I was thinking about the garden over the long weekend", refT: 3, now: 3.5), [])
        let group = rules(participants: 4)
        _ = group.onSegment(.others, text: "Can someone send the report by Friday?", refT: 1, now: 1.5)
        XCTAssertEqual(group.onSegment(.me, text: "Well I was thinking about the garden over the long weekend", refT: 3, now: 3.5), [])
    }

    func testGroupQuestionCountsWhenItNamesTheUser() {
        config.text.userNames = ["Alex"]
        let r = rules(participants: 4)
        _ = r.onSegment(.others, text: "Alex, can you send the report by Friday?", refT: 1, now: 1.5)
        XCTAssertEqual(types(r.onSegment(.me, text: "Well I was thinking about the garden over the long weekend", refT: 3, now: 3.5)),
                       [.missedQuestion])
    }

    func testEndOfTheUsersTurnWithoutAnAnswerIsSoftThenTimesOut() {
        let r = rules()
        _ = r.onSegment(.others, text: "Can you send the report by Friday?", refT: 1, now: 1.5)
        XCTAssertEqual(r.onTick(now: 2, userActive: true, frameS: 0.02), [])
        XCTAssertEqual(r.onSegment(.me, text: "Hmm, okay.", refT: 2.5, now: 3), [])
        let gap = config.local.monologueMeGapResetS
        let cues = quiet(r, from: 3, to: 3 + gap)
        XCTAssertEqual(cues.map(\.level), [.soft])
        _ = r.onSegment(.me, text: "Right.", refT: 7, now: 7.5)
        _ = r.onTick(now: 7.5, userActive: true, frameS: 0.02)
        XCTAssertEqual(quiet(r, from: 8, to: 8 + gap), [], "soft shows once per question")
        XCTAssertEqual(r.outcomes.questionTimedOut, 1, "two user turns without an answer")
    }

    func testLongDriftEscalatesToStrong() {
        let r = rules()
        _ = r.onSegment(.others, text: "Can you send the report by Friday?", refT: 1, now: 1.5)
        _ = r.onSegment(.me, text: "So.", refT: 2, now: 2.2)
        var cues: [CueSuggestion] = []
        var t = 2.2
        while t < 2.2 + config.text.questionEscalateUserS + 0.1 {
            cues += r.onTick(now: t, userActive: true, frameS: 0.02)
            t += 0.02
        }
        XCTAssertEqual(cues.map(\.level), [.strong])
    }

    func testSomeoneElseAnsweringRetiresTheQuestion() {
        let r = rules()
        _ = r.onSegment(.others, text: "Can you send the report by Friday?", refT: 1, now: 1.5)
        _ = r.onSegment(.others, text: "I can take that one, I have the latest numbers ready to go here", refT: 4, now: 4.5)
        _ = quiet(r, from: 4.5, to: 4.5 + config.text.questionTimeoutAfterOthersS + 0.1)
        XCTAssertEqual(r.outcomes.questionOthersAnswered, 1)
        XCTAssertEqual(r.onSegment(.me, text: "Well I was thinking about the garden over the long weekend", refT: 60, now: 60.5), [])
    }

    // MARK: heat

    let hot = "No, that is never going to work, it always breaks and nobody checks it."

    func testHeatNeedsScoreAndIsSuppressedEarlyInTheCall() throws {
        XCTAssertEqual(rules(offset: 0).onSegment(.me, text: hot, refT: 10, now: 10.5), [], "first minutes of the call")
        let cue = try XCTUnwrap(rules(offset: 600).onSegment(.me, text: hot, refT: 10, now: 10.5).first)
        XCTAssertEqual(cue.type, .aggressive)
        XCTAssertEqual(cue.source, .text)
        XCTAssertEqual(rules(offset: 600).onSegment(.me, text: "That plan works for me.", refT: 10, now: 10.5), [])
    }

    func testApologyOrPersonalTopicVetoesHeat() {
        XCTAssertEqual(rules(offset: 600).onSegment(.me, text: hot + " Sorry.", refT: 10, now: 10.5), [])
        let r = rules(offset: 600)
        _ = r.onSegment(.others, text: "How was the vacation?", refT: 8, now: 8.5)
        XCTAssertEqual(r.onSegment(.me, text: hot, refT: 10, now: 10.5), [])
    }

    func testLexiconOnlyHeatNeedsAProsodyRise() {
        let lexical = "It never works, it always breaks, nobody checks, everyone knows."
        let r = rules(offset: 600)
        XCTAssertEqual(r.onSegment(.me, text: lexical, refT: 10, now: 10.5), [])
        let r2 = rules(offset: 600)
        r2.onLocal(LocalEvent(kind: .prosody, t: 9, onset: 9,
                              prosody: ProsodyReading(t: 9, baselineReady: true, flagged: true, loudnessJumpDb: 3, rateJumpPct: 30)))
        XCTAssertEqual(types(r2.onSegment(.me, text: lexical, refT: 10, now: 10.5)), [.aggressive])
    }

    func testHeatShowsOncePerUserTurn() {
        let r = rules(offset: 600)
        XCTAssertEqual(types(r.onSegment(.me, text: hot, refT: 10, now: 10.5)), [.aggressive])
        r.shown(.aggressive)
        XCTAssertEqual(r.onSegment(.me, text: hot, refT: 12, now: 12.5), [])
        _ = r.onSegment(.others, text: "Okay.", refT: 13, now: 13.5)
        XCTAssertEqual(types(r.onSegment(.me, text: hot, refT: 15, now: 15.5)), [.aggressive])
    }

    // MARK: closing and queries

    func testClosingPhraseQuietsCuesForAWhile() {
        let r = rules()
        XCTAssertFalse(r.closingActive(now: 5))
        _ = r.onSegment(.others, text: "Great, talk soon everyone.", refT: 5, now: 5.5)
        XCTAssertTrue(r.closingActive(now: 6))
        XCTAssertFalse(r.closingActive(now: 5 + config.text.closingQuietS + 0.1))
    }

    func testTrailingWordsDecideIfTheirLastWordsWereUnfinished() {
        let r = rules()
        XCTAssertNil(r.trailingUnfinished(3))
        _ = r.onSegment(.others, text: "We could move it to next week and", refT: 3, now: 3.4)
        XCTAssertEqual(r.trailingUnfinished(3.2), true)
        _ = r.onSegment(.others, text: "That is the plan.", refT: 8, now: 8.4)
        XCTAssertEqual(r.trailingUnfinished(8), false)
        _ = r.onSegment(.others, text: "Well, I think,", refT: 12, now: 12.4)
        XCTAssertEqual(r.trailingUnfinished(12), true)
    }

    func testQuestionNearAndTheirTextSince() {
        let r = rules()
        _ = r.onSegment(.others, text: "Does that work for you?", refT: 5, now: 5.5)
        XCTAssertTrue(r.questionNear(6))
        XCTAssertFalse(r.questionNear(5 + config.local.cutInQuestionLookbackS + 0.5))
        XCTAssertTrue(r.othersTextSince(4.9))
        XCTAssertFalse(r.othersTextSince(5.1))
    }

    func testHowWhyQuestionBeforeTheRun() {
        let r = rules()
        _ = r.onSegment(.others, text: "Why did the rollout slip?", refT: 10, now: 10.5)
        XCTAssertTrue(r.howWhyBefore(11))
        XCTAssertFalse(r.howWhyBefore(10 + config.text.howWhyLookbackS + 1))
        let r2 = rules()
        _ = r2.onSegment(.others, text: "When did the rollout slip?", refT: 10, now: 10.5)
        XCTAssertFalse(r2.howWhyBefore(11))
    }

    func testRoundRobinHandoffOnlyInGroups() {
        let group = rules(participants: 4)
        _ = group.onSegment(.others, text: "Thanks, you're up next.", refT: 10, now: 10.5)
        XCTAssertTrue(group.updateTurnBefore(11))
        let pair = rules(participants: 2)
        _ = pair.onSegment(.others, text: "Thanks, you're up next.", refT: 10, now: 10.5)
        XCTAssertFalse(pair.updateTurnBefore(11))
    }

    func testNumberReadBack() {
        let r = rules()
        _ = r.onSegment(.others, text: "It's four two seven nine.", refT: 1, now: 1.2)
        _ = r.onSegment(.me, text: "Four two seven nine, correct.", refT: 2, now: 2.2)
        XCTAssertTrue(r.readback(from: 1, now: 3))
        let chat = rules()
        _ = chat.onSegment(.others, text: "We should look at the plan again.", refT: 1, now: 1.2)
        _ = chat.onSegment(.me, text: "Agreed, let's do it.", refT: 2, now: 2.2)
        XCTAssertFalse(chat.readback(from: 1, now: 3))
    }

    func testClearDropsEverything() {
        let r = rules()
        _ = r.onSegment(.others, text: "Can you send the report by Friday?", refT: 1, now: 1.5)
        r.clear()
        XCTAssertFalse(r.questionNear(2))
        XCTAssertFalse(r.othersTextSince(0))
        XCTAssertEqual(r.onSegment(.me, text: "Well I was thinking about the garden over the long weekend", refT: 3, now: 3.5), [])
    }

    // MARK: text helpers

    func testHelpersFollowWordBoundaries() {
        XCTAssertEqual(TextRules.phraseCount("hello there, hell no", "hell"), 1)
        XCTAssertEqual(TextRules.phraseCount("see you, see you", "see you"), 2)
        XCTAssertTrue(TextRules.startsWith("no, never", "no,"))
        XCTAssertFalse(TextRules.startsWith("nobody", "no"))
        XCTAssertEqual(TextRules.tokens("It\u{2019}s 4 o'clock!"), ["it's", "4", "o'clock"])
        XCTAssertEqual(TextRules.sentences("One. Two?! three"), ["One.", "Two?!", "three"])
        XCTAssertEqual(TextRules.stem("boxes"), "box")
        XCTAssertEqual(TextRules.stem("reports"), "report")
        XCTAssertEqual(TextRules.stem("class"), "class")
        XCTAssertTrue(TextRules.isDecimal("\u{0663}"))
    }
}
