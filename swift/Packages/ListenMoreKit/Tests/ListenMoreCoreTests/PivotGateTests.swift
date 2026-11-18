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
    static let openerTwoFirstPerson = "Same thing happened to me last spring, it took me weeks before the whole place finally felt settled again."
    static let openerMidSentence = "The long ride last spring left all of us sore, the same thing happened to me and my legs on the hills."
    static let worried = "My dad has been in the hospital all week and I have been so worried about him."
    static let engaged = "We just got engaged last weekend and I am still so excited about it."
    static let rememberAboutThem = "Oh no, I remember you said he had surgery last spring, that sounds really hard on your whole family, sending all of you good thoughts."
    static let meTooMidSentence = "That is wonderful news, congratulations to you both, your sister told me too and she was so thrilled for you."
    static let commiseration = "Oh no, I am so sorry to hear that, I hope he gets better soon, I will be thinking of him and I am here if I can help."
    static let sympathyThenStory = "I am so sorry to hear that, I had the same thing with my knee last year and I was on crutches for a month."
    static let acknowledgeThenStory = "I'm so sorry, that's rough. When my dad had surgery I was at the hospital every night and I barely slept for a month."
    static let pureCommiseration = "I'm so sorry to hear that, I hope he gets better soon, I'll be thinking of him."
    static let commiserationAndHelp = "I am so sorry to hear that, I hope it gets easier, I will be thinking about it all week and I am here if I can help."
    static let aboutThirdPerson = "My week was busy, I had my brother over and he and his kids stayed with us, they loved the park."
    static let movedStory = "I had the same thing when I moved last year, the boxes took me a month to clear out."
    static let lostMarkQuestions = [
        "\(movedStory) Did your landlord help at all",
        "\(movedStory) How's the new neighborhood",
        "\(movedStory) Is it close to work",
        "I had the same thing when I moved last year, the boxes took me a month to clear out, it is exhausting, right",
    ]
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

    /// A sentence opening with a pivot opener needs two first-person words, not three.
    func testAnOpenerAtASentenceStartNeedsTwoFirstPersonWords() {
        XCTAssertEqual(run(pivot(reply: PivotLines.openerTwoFirstPerson), until: 30).counters.candidates, 1)
    }

    /// "Me too" alone (one first-person word) doesn't make a reply about the user.
    func testMeTooAndTalkAboutTheirDayIsNone() {
        assertNoCandidate(pivot(reply: "Oh nice, me too, that sounds like such a great day, the weather on Sunday was perfect for a long race."))
    }

    /// An opener with a single first-person word ("same thing happened to me") isn't enough.
    func testAnOpenerWithOneFirstPersonWordIsNone() {
        assertNoCandidate(pivot(reply: "Same thing happened to me last spring, it took weeks and weeks before the whole place finally felt settled again."))
    }

    /// After sympathy, reactions to their news count as about them too.
    func testSympathyThenReactionsToTheirNewsIsNone() {
        assertNoCandidate(pivot(reply: "So sorry to hear that. I know the drill, I bet that sounds like a lot at the moment, I love that the doctors are quick.",
                                share: PivotLines.worried))
    }

    /// "Me too" plus reactions to their day ("i love that", "that sounds like"): about them.
    func testMeTooAndReactingToTheirDayIsNone() {
        assertNoCandidate(pivot(reply: "Me too, I love that, that sounds like such a great day out, the weather on Sunday was perfect for a long race."))
    }

    /// A reaction that opens the reply acknowledges them, like sympathy: the story after it counts.
    func testAReactionThenTheUsersOwnStoryIsACandidate() {
        XCTAssertEqual(run(pivot(reply: "That sounds amazing, that reminds me of my first race last spring, it took ages to get over the nerves."),
                           until: 30).counters.candidates, 1)
    }

    /// Three first-person words against one "you": not enough about the user.
    func testAnOpenerInAReplyAboutTheirNewsIsNone() {
        assertNoCandidate(pivot(reply: "When my sister told me the news I was so thrilled for you, it is such wonderful news for the whole family.",
                                share: PivotLines.engaged))
    }

    /// "I hope to…" is the user's own plan, not sympathy.
    func testIHopeAboutTheUserIsNotSympathy() {
        XCTAssertEqual(run(pivot(reply: "I hope to run one someday, I did a ten k last spring and I was wiped out for the whole weekend after."),
                           until: 30).counters.candidates, 1)
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

    // MARK: about them

    func testCommiserationIsNone() {
        assertNoCandidate(pivot(reply: PivotLines.commiseration, share: PivotLines.worried))
    }

    /// Acknowledging their feeling and then telling the user's own story is still a pivot.
    func testSympathyThenTheUsersOwnStoryIsACandidate() {
        for reply in [PivotLines.acknowledgeThenStory, PivotLines.sympathyThenStory] {
            XCTAssertEqual(run(pivot(reply: reply, share: PivotLines.worried), until: 30).counters.candidates, 1, reply)
        }
    }

    /// Sympathy, then the user's own story with no listed opener: judged on what follows the sympathy,
    /// where "we" counts as the user.
    func testSympathyThenAStoryWithoutAnOpenerIsACandidate() {
        let house = "We finally bought our first house last week and I am so excited to move in."
        for (share, reply) in [
            (PivotLines.worried, "I'm so sorry. My mom was in the hospital last year and I was there every night, I barely slept for a month."),
            (house, "Congrats! We just bought a house too, I spent the whole month painting my kitchen and I still have boxes everywhere."),
            (house, "Congrats! We just bought a house too, we moved in last month and we are still painting every single room in it."),
            (PivotLines.worried, "So sorry to hear that. Same here, my dad was in for a week in the spring and I was driving there every day after work."),
        ] {
            XCTAssertEqual(run(pivot(reply: reply, share: share), until: 30).counters.candidates, 1, reply)
        }
    }

    /// After sympathy, "we" is the team unless the user's own story is there too ("i", "my", "we just").
    func testWeAfterSympathyWithoutTheUsersOwnStoryIsTheTeam() {
        let house = "We finally bought our first house last week and I am so excited to move in."
        assertNoCandidate(pivot(reply: "So sorry to hear that. We will sort out the plan on our side and we will move the review to the week after.",
                                share: PivotLines.worried))
        assertNoCandidate(pivot(reply: "Congratulations! We should all celebrate, our whole team will chip in and we will get a cake for the office on Friday.",
                                share: house))
    }

    /// Accommodation is an offer of help: "we can push", "no stress", "take your time".
    func testAccommodatingThemIsAboutThem() {
        assertNoCandidate(pivot(reply: "So sorry to hear that. We can push the review to next week, we will sort out the plan on our side, no stress at all.",
                                share: PivotLines.worried))
        assertNoCandidate(pivot(reply: "No stress at all, I will take my part of the review and I can do my slides for it later in the week.",
                                share: PivotLines.worried))
    }

    /// "We" counts as the user only after sympathy: elsewhere it is often the team.
    func testWeCountsAsTheUserOnlyAfterSympathy() {
        assertNoCandidate(pivot(reply: "Oh nice, we just shipped the new build and we are moving the whole team to it, our rollout starts on Monday."))
    }

    func testOfferingHelpIsAboutThem() {
        for reply in [
            "I am here if I can help, let me know if you need anything",
            "I am here if I can help, let me know if you need anything at all from me this week.",
            "I'm so sorry, I hope he's okay. If you need anything I can take your meetings this week, just let me know.",
            "I am so sorry, that is awful. I can cover my part and yours this week, I will move my calls and I am happy to help.",
        ] {
            XCTAssertEqual(run(pivot(reply: reply, share: PivotLines.worried), until: 30).counters.candidates, 0, reply)
        }
    }

    /// A sentence opening with the user's own family ("my dad had…") turns to the user's story.
    func testAFamilyStoryAfterSympathyIsACandidate() {
        for reply in [
            "Oh no, so sorry, hope it gets better soon. My dad had the same surgery last year and I was at the hospital every day.",
            "My dad was in the hospital for a week last spring and I drove there every single day after work.",
        ] {
            XCTAssertEqual(run(pivot(reply: reply, share: PivotLines.worried), until: 30).counters.candidates, 1, reply)
        }
    }

    /// Passing on a message from family ("my mom says hi", "my son asked about the race") is about them,
    /// though the sentence opens with family.
    func testPassingOnAMessageFromFamilyIsNone() {
        let house = "We finally bought our first house last week and I am so excited to move in."
        for (share, reply) in [
            (PivotLines.share, "My mom says hi, I mentioned the race when we spoke on Sunday and the whole family was impressed by the time."),
            (PivotLines.share, "My son asked about the race this morning, I said the time was amazing and the whole team should be proud."),
            (house, "Congrats! My mom says hi, I mentioned the house when we spoke on Sunday and the whole family was excited."),
        ] {
            XCTAssertEqual(run(pivot(reply: reply, share: share), until: 30).counters.candidates, 0, reply)
        }
    }

    /// Family words that open a sentence about them, not a story of the user's own.
    func testFamilyWordsInTalkAboutThemAreNone() {
        let house = "We finally bought our first house last week and I am so excited to move in."
        for (share, reply) in [
            (PivotLines.worried, "So sorry to hear that. My family sends our love, we are all thinking of you this week."),
            (PivotLines.worried, "I'm so sorry. My mom sends her love and I will call you later tonight to check in on you."),
            (PivotLines.worried, "My kids are fine, thanks, I hope your dad is home soon and you get some rest this weekend."),
            (PivotLines.worried, "So sorry to hear that, I hope he gets better. My dad and I will be thinking of you both all week."),
            (PivotLines.engaged, "Congrats! My sister just got engaged too, she is so excited and they are planning a big wedding."),
            (house, "Congrats! My kids keep asking when we can come over and see the new place, they are so excited for you."),
        ] {
            XCTAssertEqual(run(pivot(reply: reply, share: share), until: 30).counters.candidates, 0, reply)
        }
    }

    /// Well-wishes after sympathy are about them, however first-person they read.
    func testWellWishesAfterSympathyAreAboutThem() {
        for reply in [
            "So sorry. My husband and I will keep you all in our thoughts this week, let us know.",
            "So sorry to hear that. My dad will be in my thoughts, I will keep my fingers crossed all week for him.",
        ] {
            XCTAssertEqual(run(pivot(reply: reply, share: PivotLines.worried), until: 30).counters.candidates, 0, reply)
        }
    }

    /// Sympathy and talk about them, with no turn to the user's own experience.
    func testPureCommiserationIsNone() {
        assertNoCandidate(pivot(reply: PivotLines.pureCommiseration, share: PivotLines.worried))
    }

    /// Mostly first person ("i will be thinking", "i am here"), but only sympathy and an offer of help.
    func testCommiserationWithAnOfferOfHelpIsNone() {
        assertNoCandidate(pivot(reply: PivotLines.commiserationAndHelp, share: PivotLines.worried))
    }

    /// Three first-person words, but as many about someone else (he, his, they).
    func testAReplyAsMuchAboutSomeoneElseIsNone() {
        assertNoCandidate(pivot(reply: PivotLines.aboutThirdPerson))
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

    /// Questions whose "?" the transcriber dropped: a contraction, an auxiliary plus a pronoun, or a tag.
    func testQuestionsWithoutAQuestionMarkAreNone() {
        XCTAssertEqual(run(pivot(reply: PivotLines.movedStory + " It was a long month for all of my stuff and my old bed.",
                                 share: PivotLines.moved), until: 30).counters.candidates, 1, "the same story with no question")
        for reply in PivotLines.lostMarkQuestions {
            XCTAssertEqual(run(pivot(reply: reply, share: PivotLines.moved), until: 30).counters.candidates, 0, reply)
        }
    }

    func testATagQuestionEndingTheirTurnIsNone() {
        assertNoCandidate(pivot(share: "I finally ran my first half marathon on Sunday and I was so nervous at the start, you know"))
    }

    func testBriefMeTooIsNone() {
        assertNoCandidate(pivot(reply: PivotLines.brief))
        assertNoCandidate(pivot(reply: "Me too, same thing happened to me."))
    }

    func testEmpathyAboutThemIsNone() {
        assertNoCandidate(pivot(reply: PivotLines.empathy))
    }

    func testFactualWorkExchangeIsNone() {
        assertNoCandidate(pivot(reply: PivotLines.releaseReply, share: PivotLines.release))
    }

    func testWeatherSmallTalkAndAWorkTripAreNone() {
        assertNoCandidate(pivot(reply: "Oh it has been lovely here, I went for a long walk this morning and I sat outside with my coffee for an hour.",
                                share: "We have been stuck inside all week because the weather has been terrible here."))
        assertNoCandidate(pivot(reply: "Great, I will update my notes, I spent the morning on my part of the rollout and I finished my review of the scripts.",
                                share: "I just got back from the client trip and we went through the whole migration plan with their team."))
        XCTAssertEqual(run(pivot(share: "We just got back from a long road trip with the kids and I was so tired by the end."), until: 30)
            .counters.candidates, 1, "a personal trip is still a share")
    }

    func testTheyAskedAQuestionIsNone() {
        assertNoCandidate(pivot(share: PivotLines.shareThenAsk))
    }

    func testTheyInvitedYouToShareIsNone() {
        assertNoCandidate(pivot(share: PivotLines.inviteThenShare))
    }

    /// Their invitation, the user's "yeah", then their share: the invitation still holds.
    func testAnInvitationSplitByABackchannelStillHolds() {
        var s = PivotScript()
        s.them("Have you ever run a race? I always wanted to try one.", 0.5, 3.5)
        s.you("Yeah.", 4.0, 4.4)
        s.them(PivotLines.share, 5.0, 10.0)
        s.you(PivotLines.pivot, 10.5, 16.5)
        assertNoCandidate(s)
    }

    /// A pending invitation lapses `pivot_invite_hold_s` after it was heard.
    func testAPendingInvitationExpires() {
        var s = PivotScript()
        s.them("Have you ever run a race? I always wanted to try one.", 0.5, 3.5)
        s.you("Yeah.", 4.0, 4.4)
        s.them(PivotLines.share, 60.0, 65.0)
        s.you(PivotLines.pivot, 65.5, 71.5)
        XCTAssertEqual(run(s, until: 80).counters.candidates, 1, "their share ends 67 s after the invitation's turn")
        var inside = PivotScript()
        inside.them("Have you ever run a race? I always wanted to try one.", 0.5, 3.5)
        inside.you("Yeah.", 4.0, 4.4)
        inside.them(PivotLines.share, 50.0, 55.0)
        inside.you(PivotLines.pivot, 55.5, 61.5)
        XCTAssertEqual(run(inside, until: 80).counters.candidates, 0, "57 s after: still invited")
    }

    /// Exactly `pivot_invite_hold_s` after the invitation's turn, it still holds.
    func testAPendingInvitationHoldsAtExactlyTheHold() {
        var s = PivotScript()
        s.them("Have you ever run a race? I always wanted to try one.", 0.5, 3.5)
        s.you("Yeah.", 4.0, 4.4)
        s.them(PivotLines.share, 56.0, 61.0)
        s.you(PivotLines.pivot, 61.5, 64.4)
        let gate = run(s, until: 80)
        XCTAssertEqual(gate.counters.candidates, 0, "their turn ends at 66.4 s, exactly 60 s after the invitation's at 6.4 s")
    }

    /// Another backchannel doesn't restart the hold: it counts from when the invitation was heard.
    func testABackchannelDoesNotRestartTheHold() {
        var s = PivotScript()
        s.them("Have you ever run a race? I always wanted to try one.", 0.5, 3.5)
        s.you("Yeah.", 4.0, 4.4)
        s.them(PivotLines.release, 35.0, 38.0)
        s.you("Yeah.", 38.5, 38.9)
        s.them(PivotLines.share, 66.0, 71.0)
        s.you(PivotLines.pivot, 71.5, 77.5)
        XCTAssertEqual(run(s, until: 90).counters.candidates, 1, "79.5 s is 73 s after the invitation, though 39 s after the second yeah")
    }

    /// An invitation the user answered at length is spent: a later share and pivot still count.
    func testAnInvitationAnsweredAtLengthIsSpent() {
        var s = PivotScript()
        s.them("Have you ever run a race? I always wanted to try one.", 0.5, 3.5)
        s.you("No, I never have, I mostly ride my bike on the weekends and I keep meaning to sign up for one.", 4.0, 9.0)
        s.them(PivotLines.share, 12.0, 17.0)
        s.you(PivotLines.pivot, 17.5, 23.5)
        XCTAssertEqual(run(s, until: 40).counters.candidates, 1)
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

    /// No transcript arrives during a long silence, and still no line is kept past 120 s.
    func testNoLineIsHeldPast120SOfSilence() {
        var s = PivotScript()
        s.them(PivotLines.share, 0.5, 5.5)
        let gate = PivotGate(config: config)
        var heldAt: [Int: Int] = [:]
        s.play(into: gate, until: 130) { t in
            for mark in [100, 125.5, 126] where abs(t - mark) < 1e-9 { heldAt[Int(mark * 10)] = gate.heldLines }
        }
        XCTAssertEqual(heldAt[1000], 1)
        XCTAssertEqual(heldAt[1255], 1, "exactly 120 s after the line's end")
        XCTAssertEqual(heldAt[1260], 0)
    }

    // MARK: group calls (every voice on the call stream is "them")

    /// One voice's plain line, then another voice shares; the user answers 7.5 s after the first line
    /// but 1 s after the share: the window counts from their last speech, whoever spoke.
    func testAShareFromAnotherVoiceCountsFromItsEnd() throws {
        var s = PivotScript()
        s.them(PivotLines.release, 0.5, 3.5)
        s.them(PivotLines.share, 5.0, 10.0)
        s.you(PivotLines.pivot, 11.0, 17.0)
        let c = try XCTUnwrap(run(s, until: 30).candidates.first)
        XCTAssertEqual(c.themEnd, 10.0, accuracy: 1e-9)
    }

    /// A short reaction from another voice doesn't change what the user answers: the share stands.
    func testAnotherVoiceReactingAfterTheShareKeepsIt() {
        var s = PivotScript()
        s.them(PivotLines.share, 0.5, 5.5)
        s.them("Wow, congratulations!", 6.0, 7.0)
        s.you(PivotLines.pivot, 7.5, 13.5)
        XCTAssertEqual(run(s, until: 30).counters.candidates, 1)
    }

    /// The transcriber commits a line at nearly every pause, so a short tail in its own line is still
    /// part of the share.
    func testAShortTailInItsOwnLineKeepsTheShare() {
        for tail in ["It was such a long day.", "Honestly it was amazing."] {
            var s = PivotScript()
            s.them(PivotLines.share, 0.5, 5.5)
            s.them(tail, 5.8, 7.0)
            s.you(PivotLines.pivot, 7.5, 13.5)
            XCTAssertEqual(run(s, until: 30).counters.candidates, 1, tail)
        }
    }

    /// Another voice's own 14-word story after the share changes what the user answers.
    func testAnotherVoicesOwnStoryAfterTheShareEndsIt() {
        var s = PivotScript()
        s.them(PivotLines.share, 0.5, 5.5)
        s.them("Oh nice, I did one last year too and I was wrecked for days after.", 6.5, 9.0)
        s.you("Ha, I would never manage that, my knees are terrible and I get bored running for more than ten minutes at a time.", 9.5, 15.5)
        assertNoCandidate(s)
    }

    /// After small talk, someone moves on to the agenda and the user gives a work update.
    func testMovingOnToTheAgendaEndsTheShare() {
        let update = "Sure, yesterday I finished my part of the migration and today I am on my code reviews, then I will pick up my next ticket."
        let lake = "I just got back from a week at the lake with the kids and I was so relaxed."
        var standup = PivotScript()
        standup.them(lake, 0.5, 5.5)
        standup.them("Great, let's start the standup. Sam, you go first.", 6.5, 9.0)
        standup.you(update, 9.5, 15.5)
        assertNoCandidate(standup)

        var dashboard = PivotScript()
        dashboard.them("I just got back from my sister's wedding and I was so emotional the whole day.", 0.5, 5.5)
        dashboard.them("Okay, let's look at the release dashboard now.", 6.5, 8.5)
        dashboard.you("Sure, I updated my numbers this morning and I think my part of the dashboard is ready, I will share my screen now.", 9.0, 15.0)
        assertNoCandidate(dashboard)

        var yourUpdate = PivotScript()
        yourUpdate.them("I just got back from my sister's wedding and I was so emotional the whole day.", 0.5, 5.5)
        yourUpdate.them("Sam, give us your update on the migration please.", 6.5, 8.5)
        yourUpdate.you("Sure, I finished my part yesterday and I am running my last checks today, I should be done with mine by noon.", 9.0, 15.0)
        assertNoCandidate(yourUpdate)

        var anyway = PivotScript()
        anyway.them(lake, 0.5, 5.5)
        anyway.them("Anyway. Sam.", 6.5, 7.5)
        anyway.you(update, 8.0, 14.0)
        assertNoCandidate(anyway)

        var deck = PivotScript()
        deck.them(PivotLines.share, 0.5, 5.5)
        deck.them("Nice. Can we get the numbers for the board deck by Friday", 6.0, 8.0)
        deck.you("Sure, I will pull my numbers tonight, I already have most of my slides done and I just need to check the totals.", 8.5, 14.5)
        assertNoCandidate(deck)

        var oneLine = PivotScript()
        oneLine.them("\(lake) Great, let's start the standup, you go first.", 0.5, 8.0)
        oneLine.you(update, 8.5, 14.5)
        assertNoCandidate(oneLine)

        var shortMoveOn = PivotScript()
        shortMoveOn.them("\(lake) Okay, let's get started.", 0.5, 7.0)
        shortMoveOn.you(update, 7.5, 13.5)
        assertNoCandidate(shortMoveOn)
    }

    /// A round-robin handoff (`update_handoff_phrases`) after the share moves on too.
    func testAHandoffAfterTheShareEndsIt() {
        for handoff in ["Okay Sam, you're up.", "You're next."] {
            var s = PivotScript()
            s.them(PivotLines.share, 0.5, 5.5)
            s.them(handoff, 6.0, 7.0)
            s.you(PivotLines.pivot, 7.5, 13.5)
            XCTAssertEqual(run(s, until: 30).counters.candidates, 0, handoff)
        }
    }

    /// Moving on inside the share's own sentence ends it too.
    func testMovingOnInsideTheShareSentenceEndsIt() {
        assertNoCandidate(pivot(share: "I just got back from a week at the lake with the kids and I was so relaxed, so let's get started."))
    }

    /// In the share's own line, a short sentence after it keeps the share; a longer one moves on.
    func testOnlyAShortSentenceMayFollowTheShare() {
        XCTAssertEqual(run(pivot(share: "\(PivotLines.share) It was amazing."), until: 30).counters.candidates, 1)
        assertNoCandidate(pivot(share: "\(PivotLines.share) Anyway, the migration is done and all of the tests passed this morning."))
    }

    func testAnotherVoiceInvitingTheUserIsNone() {
        var s = PivotScript()
        s.them(PivotLines.share, 0.5, 5.5)
        s.them("What about you, have you ever run one?", 6.0, 7.5)
        s.you(PivotLines.pivot, 8.0, 14.0)
        assertNoCandidate(s)
    }

    /// Another voice asks the one who shared a question; the user answering it about themselves
    /// isn't counted.
    func testAnotherVoiceAskingTheSharerIsNone() {
        var s = PivotScript()
        s.them(PivotLines.share, 0.5, 5.5)
        s.them("How long did the whole race take you", 6.0, 7.5)
        s.you(PivotLines.pivot, 8.0, 14.0)
        assertNoCandidate(s)
    }

    /// A different voice starting after the user's reply ends the turn at its onset.
    func testAnotherVoiceStartingEndsTheUsersTurn() throws {
        var s = pivot()
        s.them("Okay, shall we move on to the next item on the agenda then.", 13.0, 16.0)
        let c = try XCTUnwrap(run(s, until: 30).candidates.first)
        XCTAssertEqual(c.turnEnd, 13.0, accuracy: 1e-9)
    }

    /// A different voice talking over the user's reply (after a short pause in it) drops the reply.
    func testAnotherVoiceOverTheUsersReplyIsNone() {
        var s = PivotScript()
        s.them(PivotLines.share, 0.5, 5.5)
        s.you(PivotLines.pivotStart, 6.0, 11.0)
        s.you("And the hills on the second day were even worse than the first.", 12.0, 15.0)
        s.them("Sorry, I think we lost the screen share for a second there.", 13.5, 16.0)
        assertNoCandidate(s)
    }

    // MARK: one condition at a time

    /// About the user (no other person), but only two first-person words and no opener.
    func testTwoFirstPersonWordsWithoutAnOpenerIsNone() {
        assertNoCandidate(pivot(reply: "Oh nice, the long ride last spring left me sore for days and the hills were brutal the whole way, my legs gave out."))
    }

    /// The question hides behind a lead-in word ("so how did…") and lost its "?".
    func testAQuestionAfterALeadInWordIsNone() {
        assertNoCandidate(pivot(reply: "Same thing happened to me last year, it took me weeks. So how did the move go in the end", share: PivotLines.moved))
    }

    /// An invitation inside a clause that doesn't open like a question.
    func testAnInvitationInsideTheReplyIsNone() {
        assertNoCandidate(pivot(reply: "Same thing happened to me last year, I spent weeks unpacking and I had to repaint my whole place, anything like that happening at the new place",
                                share: PivotLines.moved))
    }

    func testTheirTurnWithoutAShareMarkerIsNone() {
        assertNoCandidate(pivot(share: "Running my first half marathon on Sunday made me so nervous at the start line."))
    }

    func testTheirTurnWithoutAShareWordIsNone() {
        assertNoCandidate(pivot(share: "I finally finished reading the long report on Sunday and I was so tired of it."))
    }

    func testTheirTurnShorterThanTheMinimumIsNone() {
        assertNoCandidate(pivot(share: "I just got married!"))
    }

    /// The opener follows lead-in words ("oh nice,"), and only two first-person words back it.
    func testAnOpenerAfterLeadInWordsCounts() {
        XCTAssertEqual(run(pivot(reply: "Oh nice, that reminds me of my own long ride last spring, it took weeks before the soreness finally went away."),
                           until: 30).counters.candidates, 1)
    }

    /// After the sympathy, the user's story starts at a later sentence with an opener.
    func testSympathyThenAnOpenerInALaterSentenceCounts() {
        XCTAssertEqual(run(pivot(reply: "I'm so sorry, the week must have been so long. That reminds me of my dad last spring, it took weeks to sort out.",
                                 share: PivotLines.worried), until: 30).counters.candidates, 1)
    }

    /// After sympathy, an opener counts only at a start: in a middle clause it doesn't, and two
    /// first-person words aren't enough without it.
    func testSympathyThenAnOpenerInAMiddleClauseIsNone() {
        assertNoCandidate(pivot(reply: "I'm so sorry, that sounds scary. The week was long, that reminds me of my dad last spring, it took ages to sort out.",
                                share: PivotLines.worried))
    }

    /// A bare "oh no" before the sympathy doesn't hide it: still pure commiseration.
    func testOhNoBeforeTheSympathyIsStillCommiseration() {
        assertNoCandidate(pivot(reply: "Oh no, I am so sorry to hear that, I hope it gets easier soon, I will be thinking about it all week long.",
                                share: PivotLines.worried))
    }

    /// Their last sentence opens like a question, though its last clause doesn't.
    func testTheirLastSentenceOpeningAsAQuestionIsNone() {
        assertNoCandidate(pivot(share: "Did you know I finally ran my first half marathon on Sunday, I was so nervous"))
    }

    /// Their last clause opens like a question, though their last sentence doesn't.
    func testTheirLastClauseOpeningAsAQuestionIsNone() {
        assertNoCandidate(pivot(share: "I finally ran my first half marathon on Sunday and I was so nervous, would you believe it"))
    }

    /// `clear()` drops a pending invitation along with the text.
    func testClearDropsAPendingInvitation() {
        var s = PivotScript()
        s.them("Have you ever run a race? I always wanted to try one.", 0.5, 3.5)
        s.you("Yeah.", 4.0, 4.4)
        s.them(PivotLines.share, 9.0, 14.0)
        s.you(PivotLines.pivot, 14.5, 20.5)
        let gate = PivotGate(config: config)
        s.play(into: gate, until: 30) { t in
            if abs(t - 8.0) < 1e-9 { gate.clear() }
        }
        XCTAssertEqual(gate.counters.candidates, 1)
    }

    /// A plain turn of theirs (no share, no invitation) is closed without waiting for the user's
    /// transcript, so a late one isn't counted.
    func testAPlainTurnIsDecidedWithoutWaitingForTheUser() {
        var s = PivotScript()
        s.them(PivotLines.release, 0.5, 5.5)
        s.you(PivotLines.releaseReply, 6.0, 12.0, delay: 5.0)
        XCTAssertEqual(run(s, until: 30).counters, PivotGate.Counters())
    }

    /// Their share ended over 120 s before their next, plain turn: it is gone, not part of that turn.
    func testAShareOlderThan120SIsNotPartOfTheirNextTurn() {
        var s = PivotScript()
        s.them(PivotLines.share, 0.5, 5.5)
        s.them("Anyway, back to the agenda for today, the next item on the list is the budget review.", 130.0, 134.0)
        s.you(PivotLines.pivot, 134.5, 140.5)
        assertNoCandidate(s, until: 150)
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
