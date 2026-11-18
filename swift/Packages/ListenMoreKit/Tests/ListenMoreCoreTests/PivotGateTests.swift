import XCTest
@testable import ListenMoreCore

/// Generic synthetic lines for the self-pivot gate.
enum PivotLines {
    static let share = "I finally ran my first half marathon on Sunday and I was so nervous at the start line."
    static let pivot = "Oh nice, that reminds me of when I did a long charity bike ride last spring, I was exhausted for days and my legs were sore the whole week."
    static let mostlyMe = "Oh nice, I did a long charity ride last spring and I was so tired, my legs were sore for a week and I slept all weekend."
    static let empathy = "That is amazing, you must be so proud of yourself, I bet your family was cheering for you the whole way."
    static let moved = "We just moved into a new apartment and I am still unpacking boxes every evening."
    static let relateThenAskMark = "Same thing happened to me last year, it took me weeks. The boxes must be everywhere by now?"
    static let relateThenAskNoMark = "Same thing happened to me last year, it took me weeks. How did the move go in the end"
    static let openerOneFirstPerson = "Same thing happened to me last spring, it took weeks and weeks before the whole place finally felt settled again."
    static let openerMidSentence = "The long ride last spring left all of us sore, the same thing happened to me on the hills and the wind."
    static let worried = "My dad has been in the hospital all week and I have been so worried about him."
    static let engaged = "We just got engaged last weekend and I am still so excited about it."
    static let rememberAboutThem = "Oh no, I remember you said he had surgery last spring, that sounds really hard on your whole family, sending all of you good thoughts."
    static let meTooMidSentence = "That is wonderful news, congratulations to you both, your sister told me too and she was so thrilled for you."
    static let brief = "Me too, same here."
    static let release = "The release is scheduled for Thursday and the test plan is signed off."
    static let releaseReply = "Great, I will update the checklist and send the release notes to the team after lunch, then I will close my tickets."
    static let shareThenAsk = "I finally ran my first half marathon on Sunday and I was so nervous, have you run one?"
    static let inviteThenShare = "Have you ever run a race? I finally ran my first half marathon on Sunday and I was so nervous at the start line."
    static let pivotStart = "That reminds me of when I did a long charity bike ride last spring, I was exhausted for days."
    static let followUp = "How did you feel at the finish line?"
    static let next = "Anyway, back to the agenda for today."
}

/// A two-speaker script on 20 ms frames. A talk is voiced on every frame from `from` to `to`; the VAD
/// reports its onset on the first frame and its offset (the last voiced frame's time) on the frame
/// after; its transcript lands `delay` after `to`, with that offset as the reference time.
struct PivotScript {
    struct Talk {
        let speaker: Speaker
        let from: Int
        let to: Int
        let text: String
        let delay: Int
    }

    struct Frame {
        var t: TimeInterval
        var mutes: [Bool] = []
        var me: VadState
        var others: VadState
        var texts: [(speaker: Speaker, text: String, refT: TimeInterval)] = []

        func vad(_ speaker: Speaker) -> VadState { speaker == .me ? me : others }
    }

    static let frameS = 0.02
    private(set) var talks: [Talk] = []
    private(set) var mutes: [(frame: Int, muted: Bool)] = []

    static func frame(_ s: Double) -> Int { Int((s / frameS).rounded()) }

    mutating func them(_ text: String, _ from: Double, _ to: Double, delay: Double = 0.76) {
        talks.append(Talk(speaker: .others, from: Self.frame(from), to: Self.frame(to), text: text, delay: Self.frame(delay)))
    }

    mutating func you(_ text: String, _ from: Double, _ to: Double, delay: Double = 0.76) {
        talks.append(Talk(speaker: .me, from: Self.frame(from), to: Self.frame(to), text: text, delay: Self.frame(delay)))
    }

    mutating func mute(_ muted: Bool, at t: Double) {
        mutes.append((Self.frame(t), muted))
    }

    /// Frame k is at audio time (k + `startFrame`) x 20 ms, the way the engine counts.
    func frames(until: Double, startFrame: Int = 0) -> [Frame] {
        let time = { (k: Int) in Double(k + startFrame) * Self.frameS }
        var was: [Speaker: Bool] = [.me: false, .others: false]
        return (0...Self.frame(until)).map { k in
            var vads: [Speaker: VadState] = [:]
            for speaker in [Speaker.me, .others] {
                let active = talks.contains { $0.speaker == speaker && $0.from <= k && k <= $0.to }
                let prev = was[speaker] ?? false
                vads[speaker] = VadState(raw: active, active: active, onset: active && !prev ? time(k) : nil,
                                         offset: !active && prev ? time(k - 1) : nil, dbfs: active ? -20 : -90)
                was[speaker] = active
            }
            var f = Frame(t: time(k), me: vads[.me]!, others: vads[.others]!)
            f.mutes = mutes.filter { $0.frame == k }.map(\.muted)
            f.texts = talks.filter { $0.to + $0.delay == k }.map { ($0.speaker, $0.text, time($0.to)) }
            return f
        }
    }

    /// Plays the script into a gate, as `GptCore` would. `before` runs ahead of each frame.
    func play(into gate: PivotGate, until: Double, startFrame: Int = 0, before: (TimeInterval) -> Void = { _ in }) {
        for f in frames(until: until, startFrame: startFrame) {
            before(f.t)
            f.mutes.forEach(gate.setMuted)
            for speaker in [Speaker.me, .others] { _ = gate.onVad(speaker, f.vad(speaker), now: f.t) }
            for s in f.texts { _ = gate.onText(s.speaker, text: s.text, refT: s.refT, now: f.t) }
        }
    }

    /// Plays the script into a `GptCore` the way the engine does: Mute goes to `setMeMuted`, every
    /// frame to `feed`, every transcript to `onText`. `before` runs ahead of each frame.
    func play(into core: GptCore, until: Double, startFrame: Int = 0, before: (TimeInterval) -> Void = { _ in }) {
        for f in frames(until: until, startFrame: startFrame) {
            before(f.t)
            for m in f.mutes { _ = core.setMeMuted(m) }
            for speaker in [Speaker.me, .others] {
                let v = f.vad(speaker)
                _ = core.feed(speaker, frame: v.raw ? GptFrames.voiced : GptFrames.silent, vad: v, now: f.t)
            }
            for s in f.texts { _ = core.onText(s.speaker, text: s.text, refT: s.refT, now: f.t) }
        }
    }
}

/// The self-pivot gate's decisions, one rule at a time. Each no-candidate script is the true pivot
/// with one thing changed, so it fails only on the rule it names.
final class PivotGateTests: XCTestCase {
    var config: ListenMoreConfig!

    override func setUpWithError() throws {
        config = try TestConfig.load()
    }

    func run(_ s: PivotScript, until: Double, startFrame: Int = 0) -> PivotGate {
        let gate = PivotGate(config: config)
        s.play(into: gate, until: until, startFrame: startFrame)
        return gate
    }

    /// Them share (0.5–5.5 s), You reply 0.5 s later for 6 s.
    func pivot(reply: String = PivotLines.pivot, share: String = PivotLines.share, replyFrom: Double = 6.0) -> PivotScript {
        var s = PivotScript()
        s.them(share, 0.5, 5.5)
        s.you(reply, replyFrom, replyFrom + 6.0)
        return s
    }

    func assertNoCandidate(_ s: PivotScript, until: Double = 30, file: StaticString = #filePath, line: UInt = #line) {
        let gate = run(s, until: until)
        XCTAssertEqual(gate.candidates, [], file: file, line: line)
        XCTAssertEqual(gate.counters.candidates, 0, file: file, line: line)
    }

    // MARK: candidates

    func testTruePivotIsACandidateAtTheEndOfTheQuietGap() throws {
        let gate = run(pivot(), until: 30)
        let c = try XCTUnwrap(gate.candidates.first)
        XCTAssertEqual(gate.candidates.count, 1)
        XCTAssertEqual(c.themEnd, 5.5, accuracy: 1e-9)
        XCTAssertEqual(c.replyStart, 6.0, accuracy: 1e-9)
        XCTAssertEqual(c.replyEnd, 12.0, accuracy: 1e-9)
        XCTAssertEqual(c.turnEnd, 14.0, accuracy: 1e-9, "the user is quiet for pivot_turn_end_gap_s")
        XCTAssertEqual(c.decidedAt, c.turnEnd, accuracy: 1e-9, "the transcript was already in")
        XCTAssertEqual(gate.counters, PivotGate.Counters(candidates: 1, rateLimited: 0, lateTranscripts: 0))
    }

    func testTheirOnsetEndsTheTurnAtOnce() throws {
        var s = pivot()
        s.them(PivotLines.next, 13.0, 15.0)
        let c = try XCTUnwrap(run(s, until: 30).candidates.first)
        XCTAssertEqual(c.turnEnd, 13.0, accuracy: 1e-9)
        XCTAssertEqual(c.decidedAt, 13.0, accuracy: 1e-9)
    }

    func testMostlyFirstPersonWithoutAnOpenerIsACandidate() {
        XCTAssertEqual(run(pivot(reply: PivotLines.mostlyMe), until: 30).counters.candidates, 1)
    }

    /// A sentence opening with a pivot opener needs only the first-person share, not the word count.
    func testAnOpenerAtASentenceStartNeedsOneFirstPersonWord() {
        XCTAssertEqual(run(pivot(reply: PivotLines.openerOneFirstPerson), until: 30).counters.candidates, 1)
    }

    // MARK: openers

    func testAnOpenerInsideASentenceDoesNotCount() {
        assertNoCandidate(pivot(reply: PivotLines.openerMidSentence))
    }

    /// "I remember" opens the sentence, but the reply is about them (you, he, your).
    func testAnOpenerInAReplyAboutThemIsNone() {
        assertNoCandidate(pivot(reply: PivotLines.rememberAboutThem, share: PivotLines.worried))
    }

    func testMeTooInsideASentenceIsNone() {
        assertNoCandidate(pivot(reply: PivotLines.meTooMidSentence, share: PivotLines.engaged))
    }

    /// At these frames the raw differences of frame times land a hair past 5 s (2, 11888) or short of
    /// 2 s (679, 11888); read through `Elapsed.span` they are exact.
    func testTheWindowEdgesHoldAnywhereOnTheClock() throws {
        for startFrame in [0, 2, 679, 11_888, 50_015, 4_320_001] {
            var s = PivotScript()
            s.them(PivotLines.share, 0.5, 5.5)
            s.you(PivotLines.pivot, 10.5, 16.5)
            let gate = run(s, until: 30, startFrame: startFrame)
            XCTAssertEqual(gate.counters.candidates, 1, "a reply exactly 5 s later, frame \(startFrame)")
            let c = try XCTUnwrap(gate.candidates.first)
            XCTAssertEqual(c.turnEnd - c.replyEnd, 2.0, accuracy: 1e-9, "quiet exactly pivot_turn_end_gap_s, frame \(startFrame)")
            var late = PivotScript()
            late.them(PivotLines.share, 0.5, 5.5)
            late.you(PivotLines.pivot, 10.52, 16.5)
            XCTAssertEqual(run(late, until: 30, startFrame: startFrame).counters.candidates, 0, "one frame past, frame \(startFrame)")
        }
    }

    // MARK: no candidate

    func testRelateThenAskWithAQuestionMarkIsNone() {
        assertNoCandidate(pivot(reply: PivotLines.relateThenAskMark, share: PivotLines.moved))
    }

    func testRelateThenAskWithoutAQuestionMarkIsNone() {
        assertNoCandidate(pivot(reply: PivotLines.relateThenAskNoMark, share: PivotLines.moved))
    }

    func testBriefMeTooIsNone() {
        assertNoCandidate(pivot(reply: PivotLines.brief))
    }

    func testEmpathyAboutThemIsNone() {
        assertNoCandidate(pivot(reply: PivotLines.empathy))
    }

    func testFactualWorkExchangeIsNone() {
        assertNoCandidate(pivot(reply: PivotLines.releaseReply, share: PivotLines.release))
    }

    func testTheyAskedAQuestionIsNone() {
        assertNoCandidate(pivot(share: PivotLines.shareThenAsk))
    }

    func testTheyInvitedYouToShareIsNone() {
        assertNoCandidate(pivot(share: PivotLines.inviteThenShare))
    }

    func testReplyStartingLateIsNone() {
        assertNoCandidate(pivot(replyFrom: 11.0))
    }

    func testMuteMidTurnIsNone() {
        var s = pivot()
        s.mute(true, at: 13.0)
        s.mute(false, at: 20.0)
        assertNoCandidate(s)
    }

    func testAShareBeforeMuteAndUnmuteIsNone() {
        var s = PivotScript()
        s.them(PivotLines.share, 0.5, 5.5)
        s.mute(true, at: 6.0)
        s.mute(false, at: 6.5)
        s.you(PivotLines.pivot, 7.0, 13.0)
        assertNoCandidate(s)
    }

    /// They start over the user's reply, after a short pause in it: the reply isn't over, and what was
    /// said before the pause is not judged alone.
    func testTheirOnsetWhileYouStillTalkIsNone() {
        var s = PivotScript()
        s.them(PivotLines.share, 0.5, 5.5)
        s.you(PivotLines.pivotStart, 6.0, 11.0)
        s.you(PivotLines.next, 12.0, 15.0)
        s.them(PivotLines.next, 13.5, 15.5)
        assertNoCandidate(s)
    }

    /// `clear()` drops the turn in progress and every line: their earlier share can't make a later
    /// plain line read as one.
    func testClearDropsTheTurnAndItsText() {
        var s = pivot()
        s.them(PivotLines.next, 15.0, 17.0)
        s.you(PivotLines.pivot, 17.5, 23.5)
        let gate = PivotGate(config: config)
        s.play(into: gate, until: 40) { t in
            if abs(t - 13.0) < 1e-9 { gate.clear() }
        }
        XCTAssertEqual(gate.counters, PivotGate.Counters())
    }

    // MARK: transcript wait

    func testALateTranscriptInsideTheWaitIsDecidedWhenItLands() throws {
        var s = PivotScript()
        s.them(PivotLines.share, 0.5, 5.5)
        s.you(PivotLines.pivot, 6.0, 12.0, delay: 3.5)
        let gate = run(s, until: 30)
        let c = try XCTUnwrap(gate.candidates.first)
        XCTAssertEqual(c.turnEnd, 14.0, accuracy: 1e-9)
        XCTAssertEqual(c.decidedAt, 15.5, accuracy: 1e-9, "the transcript landed exactly pivot_transcript_wait_s after the turn end")
        XCTAssertEqual(gate.counters.lateTranscripts, 0)
    }

    func testATranscriptPastTheWaitIsDropped() {
        var s = PivotScript()
        s.them(PivotLines.share, 0.5, 5.5)
        s.you(PivotLines.pivot, 6.0, 12.0, delay: 3.52)
        let gate = run(s, until: 30)
        XCTAssertEqual(gate.candidates, [])
        XCTAssertEqual(gate.counters, PivotGate.Counters(candidates: 0, rateLimited: 0, lateTranscripts: 1))
    }

    // MARK: rate limits

    func twoPivots(secondAt t: Double) -> PivotScript {
        var s = pivot()
        s.them(PivotLines.share, t, t + 5.0)
        s.you(PivotLines.pivot, t + 5.5, t + 11.5)
        return s
    }

    func testASecondPivotInsideTheRearmIsNone() {
        let gate = run(twoPivots(secondAt: 60), until: 90)
        XCTAssertEqual(gate.counters, PivotGate.Counters(candidates: 1, rateLimited: 1, lateTranscripts: 0))
    }

    func testASecondPivotAtTheRearmIsACandidate() {
        let gate = run(twoPivots(secondAt: 180.5), until: 220)
        XCTAssertEqual(gate.counters.candidates, 2)
        XCTAssertEqual(gate.candidates[1].turnEnd - gate.candidates[0].turnEnd, 180, accuracy: 1e-9)
    }

    func testThePerCallCapHoldsLaterPivots() {
        config.text.pivotRearmS = 0
        config.text.pivotMaxPerCall = 1
        let gate = run(twoPivots(secondAt: 60), until: 90)
        XCTAssertEqual(gate.counters, PivotGate.Counters(candidates: 1, rateLimited: 1, lateTranscripts: 0))
    }

    // MARK: pauses

    func testAPauseShorterThanTheGapThenAQuestionIsNone() {
        var s = PivotScript()
        s.them(PivotLines.share, 0.5, 5.5)
        s.you(PivotLines.pivotStart, 6.0, 11.0)
        s.you(PivotLines.followUp, 12.98, 14.5)
        assertNoCandidate(s)
    }

    // MARK: config

    func testDefaultsAndValidation() throws {
        let t = config.text
        XCTAssertEqual(t.pivotShareMinWords, 8)
        XCTAssertEqual(t.pivotReplyMaxStartS, 5.0)
        XCTAssertEqual(t.pivotReplyMinWords, 15)
        XCTAssertEqual(t.pivotTurnEndGapS, 2.0)
        XCTAssertEqual(t.pivotTranscriptWaitS, 1.5)
        XCTAssertEqual(t.pivotRearmS, 180)
        XCTAssertEqual(t.pivotMaxPerCall, 20)
        XCTAssertThrowsError(try ListenMoreConfig.load(overrides: ["text": ["pivot_turn_end_gap_s": 0]]))
        XCTAssertThrowsError(try ListenMoreConfig.load(overrides: ["text": ["pivot_first_person_share": 1.5]]))
        XCTAssertEqual(try ListenMoreConfig.load(overrides: ["text": ["pivot_rearm_s": 60]]).text.pivotRearmS, 60)
    }
}
