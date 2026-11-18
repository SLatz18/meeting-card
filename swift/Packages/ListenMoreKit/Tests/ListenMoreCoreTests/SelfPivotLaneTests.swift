import XCTest
@testable import ListenMoreCore

/// The host's self-pivot switch, flipped from tests (or from a judge, mid-call).
final class SwitchBox: @unchecked Sendable {
    private let lock = NSLock()
    private var on: Bool

    init(_ on: Bool = true) { self.on = on }

    var isOn: Bool { lock.withLock { on } }
    func set(_ v: Bool) { lock.withLock { on = v } }
}

/// A self-pivot judge that answers from a closure and records how often it was asked (never the prompt).
final class ScriptedSelfPivotJudge: CueJudge, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private let answer: @Sendable (Int) throws -> JudgeResult

    init(answer: @escaping @Sendable (Int) throws -> JudgeResult = { _ in JudgeResult(cue: "self_pivot", confidence: 0.9, shortReason: "") }) {
        self.answer = answer
    }

    var calls: Int { lock.withLock { _calls } }

    func judge(prompt: String) async throws -> (JudgeResult, JudgeUsage) {
        let n = lock.withLock { () -> Int in
            _calls += 1
            return _calls
        }
        return (try answer(n), JudgeUsage(inputTokens: 500, cachedTokens: 0, outputTokens: 20))
    }
}

/// Plays a script into a `GptCore` and runs each self-pivot request at once, the way `GptLayer` would
/// with an instant network: begin, answer, finish, then any queued one.
struct SelfPivotDriver {
    var answer: (Int) -> Result<(JudgeResult, JudgeUsage), Error> = { _ in
        .success((JudgeResult(cue: "self_pivot", confidence: 0.9, shortReason: ""), JudgeUsage(inputTokens: 500, outputTokens: 20)))
    }
    /// Seconds from the request to its answer.
    var latency = 0.5

    struct Run {
        var offers: [GptCore.Offer] = []
        var prompts: [String] = []
    }

    func run(_ s: PivotScript, core: GptCore, until: Double, startFrame: Int = 0,
             before: (TimeInterval) -> Void = { _ in }) -> Run {
        var out = Run()
        var asked = 0
        for f in s.frames(until: until, startFrame: startFrame) {
            before(f.t)
            for m in f.mutes { _ = core.setMeMuted(m) }
            for speaker in [Speaker.me, .others] {
                let v = f.vad(speaker)
                _ = core.feed(speaker, frame: v.raw ? GptFrames.voiced : GptFrames.silent, vad: v, now: f.t)
            }
            for t in f.texts { _ = core.onText(t.speaker, text: t.text, refT: t.refT, now: f.t) }
            var queue = core.takeSelfPivotStarts()
            while !queue.isEmpty {
                let req = queue.removeFirst()
                if let prompt = core.beginSelfPivot(req, now: f.t) {
                    out.prompts.append(prompt)
                    asked += 1
                    if let o = core.finishSelfPivot(req, result: answer(asked), now: f.t + latency) { out.offers.append(o) }
                }
                if let next = core.selfPivotEnded() { queue.append(next) }
            }
        }
        return out
    }
}

final class SelfPivotLaneTests: XCTestCase {
    var config: ListenMoreConfig!
    let clock = ManualClock(0)
    let offers = OfferBox()

    /// MeetingCard's config: not_listening is off, so the cue judge never runs.
    static let meetingCard: [String: Any] = ["cues": ["disabled": ["not_listening"]], "gpt": ["judge_min_interval_s": 0]]

    override func setUpWithError() throws {
        config = try ListenMoreConfig.load(overrides: Self.meetingCard)
    }

    func pivot(share: String = PivotLines.share, reply: String = PivotLines.pivot, at b: Double = 0) -> PivotScript {
        var s = PivotScript()
        s.them(share, b + 0.5, b + 5.5)
        s.you(reply, b + 6.0, b + 12.0)
        return s
    }

    /// `n` true pivots, `every` seconds apart.
    func pivots(_ n: Int, every: Double) -> PivotScript {
        var s = PivotScript()
        for k in 0..<n {
            let b = Double(k) * every
            s.them(PivotLines.share, b + 0.5, b + 5.5)
            s.you(PivotLines.pivot, b + 6.0, b + 12.0)
        }
        return s
    }

    func core(_ config: ListenMoreConfig? = nil, call: CoachCallContext = CoachCallContext(),
              allowed: @escaping @Sendable () -> Bool = { true }, wired: Bool = true) -> GptCore {
        let c = GptCore(config: config ?? self.config, call: call, selfPivotAllowed: allowed)
        if wired { c.wireSelfPivotJudge() }
        return c
    }

    /// Steps a layer one frame at a time on the manual clock; transcripts come from the fake transcribers.
    func runLayer(_ s: PivotScript, config: ListenMoreConfig? = nil, judge: CueJudge = FakeJudge(), selfPivotJudge: CueJudge?,
                  me: [String] = [PivotLines.pivot], others: [String] = [PivotLines.share],
                  allowed: @escaping @Sendable () -> Bool = { true }, until: Double,
                  settle: (GptLayer.Snapshot) -> Bool = { _ in true }) async -> GptLayer.Snapshot {
        let clock = clock, offers = offers
        let layer = GptLayer(config: config ?? self.config, now: { clock.now() }, offer: { offers.add($0, $1, $2, $3) },
                             judge: judge, selfPivotJudge: selfPivotJudge, selfPivotAllowed: allowed,
                             scheduler: InstantScheduler()) { speaker, onEvent in
            FakeTranscriber(speaker: speaker, script: speaker == .me ? me : others, onEvent: onEvent)
        }
        layer.start()
        for f in s.frames(until: until) {
            clock.set(f.t)
            layer.feed(me: f.me.raw ? GptFrames.voiced : GptFrames.silent, meVad: f.me,
                       others: f.others.raw ? GptFrames.voiced : GptFrames.silent, othersVad: f.others, meRunS: 0)
            _ = await layer.snapshot()
        }
        _ = await eventually { settle(await layer.snapshot()) }
        let snap = await layer.snapshot()
        await layer.close()
        return snap
    }

    // MARK: criterion 1 and trap 1: in MeetingCard, the self-pivot judge is the only judge

    /// MeetingCard turns not_listening off, so the cue judge never runs. Self-pivot must not change that:
    /// the one request a true pivot makes is the self-pivot judge's, and it shows as a self_pivot offer.
    func testInMeetingCardTheOnlyJudgeCallIsTheSelfPivotOne() async throws {
        let http = FakeHTTP()
        http.reply = ("self_pivot", 0.9)
        let key = try XCTUnwrap(APIKey("sk-test"))
        let snap = await runLayer(pivot(), judge: LiveJudge(config: config, key: key, http: http),
                                  selfPivotJudge: LiveJudge(config: config, key: key, http: http, spec: .selfPivot), until: 20,
                                  settle: { $0.selfPivotJudgeCalls >= 1 && !self.offers.offers.isEmpty })
        XCTAssertEqual(http.requests.count, 1)
        let format = (http.requests.first?.body["text"] as? [String: Any])?["format"] as? [String: Any]
        XCTAssertEqual(format?["name"] as? String, "listen_more_self_pivot")
        XCTAssertEqual(http.requests.first?.body["store"] as? Bool, false)
        XCTAssertEqual(snap.selfPivotJudgeCalls, 1)
        XCTAssertEqual(snap.otherJudgeCalls, 0)
        XCTAssertEqual(offers.offers.map(\.label), ["self_pivot"])
        XCTAssertEqual(CueType(judgeLabel: offers.offers[0].label, provider: .gpt), .selfPivot)
    }

    /// Trap 1, as a rule: the cues the me_reply judge decides never include self_pivot, so a host that
    /// disables not_listening still makes no cue judge calls.
    func testSelfPivotNeverSwitchesTheCueJudgeOn() {
        for provider in JudgeProviderKind.allCases {
            XCTAssertFalse(CueType.decided(by: provider).contains(.selfPivot), "\(provider)")
        }
        let core = core()
        let r = core.onText(.others, text: PivotLines.share, refT: 1, now: 1)
        XCTAssertNil(r.start)
        XCTAssertNil(core.onText(.me, text: PivotLines.pivot, refT: 2, now: 2).start, "no me_reply request with not_listening off")
    }

    /// With not_listening on (the Kit's generic config), the two judges run side by side: neither request
    /// replaces the other's, and each is counted on its own side.
    func testTheTwoJudgesDontDropEachOther() async throws {
        let generic = try ListenMoreConfig.load(overrides: ["gpt": ["judge_min_interval_s": 0]])
        let cue = FakeJudge(), selfPivot = ScriptedSelfPivotJudge()
        let snap = await runLayer(pivot(), config: generic, judge: cue, selfPivotJudge: selfPivot, until: 20,
                                  settle: { $0.selfPivotJudgeCalls >= 1 && $0.otherJudgeCalls >= 1 })
        XCTAssertEqual(cue.prompts.count, 1)
        XCTAssertTrue(cue.prompts[0].hasSuffix("TRIGGER: me_reply"))
        XCTAssertEqual(selfPivot.calls, 1)
        XCTAssertEqual(snap.judgeCalls, 2)
        XCTAssertEqual(snap.selfPivotJudgeCalls, 1)
        XCTAssertEqual(snap.otherJudgeCalls, 1)
    }

    /// The cue judge's verdicts are only its own labels: it can never raise self_pivot.
    func testTheCueJudgeCannotRaiseSelfPivot() throws {
        let generic = try ListenMoreConfig.load(overrides: [:])
        let core = GptCore(config: generic)
        let req = GptCore.JudgeRequest(refT: 1, reason: "me_reply")
        XCTAssertNil(core.finishJudge(req, result: .success((JudgeResult(cue: "self_pivot", confidence: 0.99, shortReason: ""), JudgeUsage())), now: 2))
        XCTAssertNotNil(core.finishJudge(req, result: .success((JudgeResult(cue: "not_listening", confidence: 0.99, shortReason: ""), JudgeUsage())), now: 2))
    }

    // MARK: criterion 2 and ruling 2: the switch (which also stands for "the notice was shown")

    /// The switch off: a true pivot is still counted in shadow, but nothing is sent and nothing offered.
    func testSwitchOffMakesNoSelfPivotJudgeCalls() async throws {
        let http = FakeHTTP()
        http.reply = ("self_pivot", 0.99)
        let key = try XCTUnwrap(APIKey("sk-test"))
        let snap = await runLayer(pivots(3, every: 200), judge: LiveJudge(config: config, key: key, http: http),
                                  selfPivotJudge: LiveJudge(config: config, key: key, http: http, spec: .selfPivot),
                                  me: Array(repeating: PivotLines.pivot, count: 3), others: Array(repeating: PivotLines.share, count: 3),
                                  allowed: { false }, until: 620)
        XCTAssertEqual(snap.pivotCandidates, 3)
        XCTAssertEqual(snap.selfPivotSwitchedOff, 3)
        XCTAssertEqual(snap.selfPivotJudgeCalls, 0)
        XCTAssertEqual(http.requests.count, 0, "nothing sent")
        XCTAssertTrue(offers.offers.isEmpty, "nothing shown")
    }

    /// Turned off while a call is in flight: that verdict isn't offered, and nothing more is sent.
    func testSwitchOffMidCallDropsTheVerdictInFlightAndSendsNothingMore() {
        let box = SwitchBox()
        var driver = SelfPivotDriver()
        driver.answer = { _ in
            box.set(false)
            return .success((JudgeResult(cue: "self_pivot", confidence: 0.99, shortReason: ""), JudgeUsage()))
        }
        var c = config!
        c.text.pivotRearmS = 0
        let core = core(c, allowed: { box.isOn })
        let r = driver.run(pivots(3, every: 30), core: core, until: 100)
        XCTAssertEqual(r.prompts.count, 1)
        XCTAssertTrue(r.offers.isEmpty)
        XCTAssertEqual(core.snapshot.selfPivotSwitchedOff, 3, "the verdict, then the two later candidates")
    }

    func testSwitchReadsLiveBetweenCandidates() {
        let box = SwitchBox(false)
        var c = config!
        c.text.pivotRearmS = 0
        let core = core(c, allowed: { box.isOn })
        let r = SelfPivotDriver().run(pivots(2, every: 30), core: core, until: 55) { t in
            if abs(t - 28) < 1e-9 { box.set(true) }
        }
        XCTAssertEqual(r.prompts.count, 1, "only the pivot after the switch came on")
        XCTAssertEqual(r.offers.map(\.refT), [42.0])
        XCTAssertEqual(core.snapshot.selfPivotSwitchedOff, 1)
    }

    /// The Kit-level off switch: self_pivot in `cues.disabled`, or a call cap of 0.
    func testDisabledInConfigMakesNoCalls() throws {
        for overrides: [String: Any] in [["cues": ["disabled": ["not_listening", "self_pivot"]]],
                                        ["gpt": ["self_pivot_max_judge_calls_per_call": 0]]] {
            let c = try ListenMoreConfig.load(overrides: ListenMoreConfig.deepMerge(Self.meetingCard, overrides))
            let core = core(c)
            let r = SelfPivotDriver().run(pivot(), core: core, until: 25)
            XCTAssertTrue(r.prompts.isEmpty, "\(overrides)")
            XCTAssertFalse(core.snapshot.selfPivotAvailable)
            XCTAssertEqual(core.snapshot.pivotCandidates, 1, "still counted in shadow")
        }
    }

    // MARK: ruling 4: the configured provider only

    /// TypeSafe can't ask the self-pivot question yet: no self-pivot judge, so self-pivot is off; nothing
    /// is ever sent to OpenAI's Responses API instead.
    func testTypeSafeHasNoSelfPivotJudgeAndNeverFallsBack() async throws {
        var ts = config!
        ts.judge.provider = .typesafe
        let key = try XCTUnwrap(APIKey("sk-test"))
        XCTAssertNil(JudgeProviders.selfPivotJudge(config: ts, openAIKey: key, http: FakeHTTP()))
        XCTAssertFalse(JudgeProviders.judgesSelfPivot(.typesafe))
        XCTAssertTrue(JudgeProviders.judgesSelfPivot(.gpt))
        let gptJudge = JudgeProviders.selfPivotJudge(config: config, openAIKey: key, http: FakeHTTP()) as? LiveJudge
        XCTAssertEqual(gptJudge?.spec, .selfPivot)

        let http = FakeHTTP()
        let layer = GptLayer(config: ts, key: key, judgeKey: APIKey("ts-test"),
                             transports: GptTransports(http: http, webSocket: FakeConnector(), scheduler: InstantScheduler()),
                             now: { 0 }, offer: { _, _, _, _ in })
        let snap = await layer.snapshot()
        XCTAssertFalse(snap.selfPivotAvailable)
        await layer.close()
        XCTAssertEqual(http.requests.count, 0)
        let core = GptCore(config: ts)
        XCTAssertFalse(core.snapshot.selfPivotAvailable, "unwired")
        let r = SelfPivotDriver().run(pivot(), core: core, until: 25)
        XCTAssertTrue(r.prompts.isEmpty)
        XCTAssertEqual(core.snapshot.pivotCandidates, 1)
    }

    /// The production engine under TypeSafe: its GPT layer has no self-pivot judge.
    func testTheEngineUnderTypeSafeHasSelfPivotOff() async throws {
        let engine = LocalCoachEngine(transports: GptTransports(http: FakeHTTP(), webSocket: FakeConnector(), scheduler: InstantScheduler()),
                                      judgeKeys: FakeKeys(key: APIKey("ts-test")), judgeProvider: { .typesafe })
        engine.start(config: config, apiKey: APIKey("sk-test"))
        let ts = await engine.gptSnapshot()
        XCTAssertEqual(ts?.selfPivotAvailable, false)
        engine.stop()
        let gpt = LocalCoachEngine(transports: GptTransports(http: FakeHTTP(), webSocket: FakeConnector(), scheduler: InstantScheduler()),
                                   judgeProvider: { .gpt })
        gpt.start(config: config, apiKey: APIKey("sk-test"))
        let on = await gpt.gptSnapshot()
        XCTAssertEqual(on?.selfPivotAvailable, true)
        gpt.stop()
    }

    /// No key: no GPT layer, so no gate, no judge and no calls.
    func testNoKeyMeansNoSelfPivot() async {
        let http = FakeHTTP()
        let engine = LocalCoachEngine(transports: GptTransports(http: http, webSocket: FakeConnector(), scheduler: InstantScheduler()))
        engine.start(config: config, apiKey: nil)
        XCTAssertFalse(engine.hasGptLayer)
        let snap = await engine.gptSnapshot()
        XCTAssertNil(snap)
        engine.stop()
        XCTAssertEqual(http.requests.count, 0)
    }

    // MARK: criterion 4: floor, re-arm, cap, store false, no text

    func testTheFloorIs085() {
        XCTAssertEqual(config.gpt.selfPivotMinConfidence, 0.85)
        for (confidence, offered) in [(0.849, false), (0.85, true), (0.97, true)] {
            var d = SelfPivotDriver()
            d.answer = { _ in .success((JudgeResult(cue: "self_pivot", confidence: confidence, shortReason: ""), JudgeUsage())) }
            let core = core()
            let r = d.run(pivot(), core: core, until: 25)
            XCTAssertEqual(r.offers.count, offered ? 1 : 0, "\(confidence)")
            XCTAssertEqual(core.snapshot.selfPivotBelowFloor, offered ? 0 : 1)
        }
    }

    func testANoneVerdictIsNoOffer() {
        var d = SelfPivotDriver()
        d.answer = { _ in .success((JudgeResult(cue: "none", confidence: 0.99, shortReason: ""), JudgeUsage())) }
        XCTAssertTrue(d.run(pivot(), core: core(), until: 25).offers.isEmpty)
    }

    /// The offer's onset is the end of the user's reply; a verdict more than 10 s after it is dropped.
    func testTheOfferCountsFromTheReplyEndAndAStaleOneIsDropped() throws {
        let fresh = SelfPivotDriver().run(pivot(), core: core(), until: 25)
        let o = try XCTUnwrap(fresh.offers.first)
        XCTAssertEqual(o.refT, 12.0, accuracy: 1e-9)
        XCTAssertEqual(o.label, "self_pivot")
        var late = SelfPivotDriver()
        late.latency = 9.0
        let core = core()
        XCTAssertTrue(late.run(pivot(), core: core, until: 25).offers.isEmpty, "decided 2 s after the reply, answered 9 s later")
        XCTAssertEqual(core.snapshot.selfPivotStale, 1)
    }

    /// 180 s from the last candidate's turn end, on the call's clock: a new run seeded from the ledger
    /// holds the next candidate back until then, whatever its own clock says.
    func testTheRearmCarriesAcrossEngineRuns() {
        XCTAssertEqual(config.text.pivotRearmS, 180)
        for (offset, judged) in [(100.0, false), (179.0, false), (180.0, true)] {
            let ledger = SelfPivotLedger()
            let first = core(call: CoachCallContext(selfPivot: ledger, offset: 0))
            XCTAssertEqual(SelfPivotDriver().run(pivot(), core: first, until: 25).prompts.count, 1)
            XCTAssertEqual(ledger.lastCandidateTurnEnd ?? -1, 14.0, accuracy: 1e-9)
            let second = core(call: CoachCallContext(selfPivot: ledger, offset: offset))
            let r = SelfPivotDriver().run(pivot(), core: second, until: 25)
            XCTAssertEqual(r.prompts.count, judged ? 1 : 0, "next run starts \(offset) s into the call")
            XCTAssertEqual(second.snapshot.pivotRateLimited, judged ? 0 : 1)
            XCTAssertEqual(ledger.judgeCalls, judged ? 2 : 1)
        }
    }

    /// At most 20 self-pivot judge calls per call, even when the gate's own candidate cap is higher.
    func testAtMostTwentySelfPivotJudgeCallsPerCall() throws {
        XCTAssertEqual(config.gpt.selfPivotMaxJudgeCallsPerCall, 20)
        var c = config!
        c.text.pivotRearmS = 0
        c.text.pivotMaxPerCall = 100
        let core = core(c)
        let r = SelfPivotDriver().run(pivots(30, every: 30), core: core, until: 905)
        XCTAssertEqual(core.snapshot.pivotCandidates, 30)
        XCTAssertEqual(r.prompts.count, 20)
        XCTAssertEqual(core.snapshot.selfPivotJudgeCalls, 20)
        XCTAssertEqual(core.snapshot.selfPivotCapped, 10)
        XCTAssertEqual(r.offers.count, 20)
    }

    /// The 20 are per call: Pause or the call app's mute restarts the engine, and the next run gets
    /// only what's left.
    func testTheCallCapCarriesAcrossEngineRuns() {
        var c = config!
        c.text.pivotRearmS = 0
        c.text.pivotMaxPerCall = 100
        let ledger = SelfPivotLedger()
        let first = SelfPivotDriver().run(pivots(15, every: 30), core: core(c, call: CoachCallContext(selfPivot: ledger, offset: 0)), until: 455)
        XCTAssertEqual(first.prompts.count, 15)
        let second = core(c, call: CoachCallContext(selfPivot: ledger, offset: 600))
        let r = SelfPivotDriver().run(pivots(10, every: 30), core: second, until: 305)
        XCTAssertEqual(r.prompts.count, 5)
        XCTAssertEqual(second.snapshot.selfPivotCallJudgeCalls, 20)
        XCTAssertEqual(second.snapshot.selfPivotCapped, 5)
    }

    /// The gate's candidate cap is call-wide too.
    func testTheCandidateCapCarriesAcrossEngineRuns() {
        var c = config!
        c.text.pivotRearmS = 0
        c.text.pivotMaxPerCall = 3
        let ledger = SelfPivotLedger()
        _ = SelfPivotDriver().run(pivots(2, every: 30), core: core(c, call: CoachCallContext(selfPivot: ledger)), until: 65)
        let second = core(c, call: CoachCallContext(selfPivot: ledger, offset: 100))
        _ = SelfPivotDriver().run(pivots(3, every: 30), core: second, until: 95)
        XCTAssertEqual(second.snapshot.pivotCandidates, 1)
        XCTAssertEqual(second.snapshot.pivotRateLimited, 2)
        XCTAssertEqual(ledger.candidates, 3)
    }

    func testRequestsSendStoreFalseAndTheSelfPivotSchema() async throws {
        let body = LiveJudge.requestBody(gpt: config.gpt, prompt: "x", spec: .selfPivot)
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["instructions"] as? String, SelfPivotJudgeSpec.instructions)
        let format = (body["text"] as? [String: Any])?["format"] as? [String: Any]
        XCTAssertEqual(format?["name"] as? String, "listen_more_self_pivot")
        XCTAssertEqual(format?["strict"] as? Bool, true)
        let schema = format?["schema"] as? [String: Any]
        let cue = (schema?["properties"] as? [String: Any])?["cue"] as? [String: Any]
        XCTAssertEqual(cue?["enum"] as? [String], ["none", "self_pivot"])

        let http = FakeHTTP()
        http.reply = ("self_pivot", 0.9)
        let judge = LiveJudge(config: config, key: try XCTUnwrap(APIKey("sk-test")), http: http, spec: .selfPivot)
        let (res, _) = try await judge.judge(prompt: "x")
        XCTAssertEqual(res.cue, "self_pivot")
        XCTAssertEqual(http.requests.first?.body["store"] as? Bool, false)
        XCTAssertThrowsError(try ListenMoreConfig.load(overrides: ["gpt": ["store": true]]))
    }

    /// The judge sees the two turns the gate decided on, redacted, and nothing said before them.
    func testThePromptHasOnlyTheTwoTurnsRedacted() throws {
        var c = config!
        c.text.userNames = ["Robin"]
        var s = PivotScript()
        s.them(PivotLines.release, 0.5, 4.0)
        s.you(PivotLines.releaseReply, 5.0, 10.0)
        s.them("I just got back from my sister's wedding and I was so emotional, call me on 555 123 4567 later.", 20.5, 25.5)
        s.you("Oh nice, that reminds me of when Robin and I went to my cousin's wedding last spring, I was so tired I slept all weekend.", 26.0, 32.0)
        let r = SelfPivotDriver().run(s, core: core(c), until: 45)
        let prompt = try XCTUnwrap(r.prompts.first)
        XCTAssertTrue(prompt.hasSuffix("TRIGGER: self_pivot"))
        XCTAssertTrue(prompt.contains("OTHERS: i just got back from my sister's wedding"))
        XCTAssertTrue(prompt.contains("ME: oh nice, that reminds me"))
        XCTAssertTrue(prompt.contains("[number]"))
        XCTAssertTrue(prompt.contains("[name]"))
        XCTAssertFalse(prompt.contains("555"))
        XCTAssertFalse(prompt.contains("robin"))
        XCTAssertFalse(prompt.contains("release"), "the earlier exchange isn't sent")
    }

    /// Counters, the ledger and the snapshot hold numbers and classes only, never text.
    func testNoTextInTheSnapshotOrTheLedger() {
        let ledger = SelfPivotLedger()
        let core = core(call: CoachCallContext(selfPivot: ledger))
        _ = SelfPivotDriver().run(pivot(), core: core, until: 25)
        let dumps = [String(reflecting: core.snapshot), String(reflecting: core.selfPivot.counters), String(reflecting: ledger),
                     String(reflecting: core.cost.reading)]
        for dump in dumps {
            for word in ["marathon", "charity", "nervous", "reminds", "bike"] {
                XCTAssertFalse(dump.lowercased().contains(word), dump)
            }
        }
        XCTAssertNil(core.pivot.takeSnippet(), "the snippet went to the judge once and isn't kept")
    }

    // MARK: criterion 5 and ruling 5: counted and capped on its own; a cap or an error stops self-pivot only

    func testTheCostSplitAddsUp() {
        var cost = CostTracker(prices: config.gpt.pricesUsd, budget: 1)
        cost.addJudge(JudgeUsage(inputTokens: 1000, cachedTokens: 200, outputTokens: 30))
        cost.addSelfPivotJudge(JudgeUsage(inputTokens: 500, cachedTokens: 0, outputTokens: 20))
        XCTAssertEqual(cost.judgeCalls, 2)
        XCTAssertEqual(cost.selfPivotCalls, 1)
        XCTAssertEqual(cost.selfPivotJudgeUsd, 0.00006, accuracy: 1e-12)
        XCTAssertEqual(cost.judgeUsd, 0.00008 + 0.000002 + 0.000015 + 0.00006, accuracy: 1e-12)
        XCTAssertEqual(cost.reading.selfPivotJudgeUsd, cost.selfPivotJudgeUsd)
        XCTAssertEqual(cost.reading.judgeUsd, cost.judgeUsd, "the total includes the self-pivot share")
    }

    /// $0.02 a call by default. Reaching the self-pivot spend cap stops self-pivot for the call; the layer,
    /// transcription and the cue judge go on.
    func testTheSpendCapStopsSelfPivotOnly() throws {
        XCTAssertEqual(try ListenMoreConfig.builtIn().gpt.selfPivotBudgetUsdPerCall, 0.02)
        let generic = try ListenMoreConfig.load(overrides: ["gpt": ["self_pivot_budget_usd_per_call": 0.0001], "text": ["pivot_rearm_s": 0]])
        let ledger = SelfPivotLedger()
        let core = core(generic, call: CoachCallContext(selfPivot: ledger))
        let r = SelfPivotDriver().run(pivots(4, every: 30), core: core, until: 125)
        XCTAssertEqual(r.prompts.count, 2, "$0.00006 a call: the second reaches $0.0001")
        XCTAssertEqual(core.snapshot.selfPivotStop, .budgetCap)
        XCTAssertEqual(core.snapshot.selfPivotCapped, 2)
        XCTAssertEqual(ledger.usd, 0.00012, accuracy: 1e-12)
        XCTAssertTrue(core.enabled)
        XCTAssertTrue(core.errors.isEmpty)
        XCTAssertNil(core.stopReason)
        XCTAssertTrue(core.judgeActive, "the cue judge still runs")
        let next = SelfPivotLedger()
        XCTAssertNil(next.stop, "a new call starts again")
    }

    /// The stop is call-wide: the next run of the same call doesn't judge either.
    func testAStopCarriesAcrossEngineRuns() {
        let ledger = SelfPivotLedger()
        ledger.stop(.budgetCap)
        let core = core(call: CoachCallContext(selfPivot: ledger, offset: 300))
        XCTAssertTrue(SelfPivotDriver().run(pivot(), core: core, until: 25).prompts.isEmpty)
        XCTAssertEqual(core.snapshot.selfPivotStop, .budgetCap)
    }

    /// Trap 2: a self-pivot judge error stops self-pivot judging only. The layer keeps transcribing and the
    /// cue judge keeps running; a later true pivot isn't judged.
    func testAJudgeErrorStopsSelfPivotOnly() async throws {
        let generic = try ListenMoreConfig.load(overrides: ["gpt": ["judge_min_interval_s": 0], "text": ["pivot_rearm_s": 0]])
        let cue = FakeJudge()
        let selfPivot = ScriptedSelfPivotJudge(answer: { _ in throw GptError.http(400) })
        let snap = await runLayer(pivots(2, every: 30), config: generic, judge: cue, selfPivotJudge: selfPivot,
                                  me: [PivotLines.pivot, PivotLines.pivot], others: [PivotLines.share, PivotLines.share], until: 50,
                                  settle: { $0.otherJudgeCalls >= 2 })
        XCTAssertEqual(selfPivot.calls, 1)
        XCTAssertEqual(snap.selfPivotStop, .judgeError)
        XCTAssertEqual(snap.selfPivotFailures, 1)
        XCTAssertEqual(snap.selfPivotCapped, 1, "the second pivot isn't judged")
        XCTAssertTrue(snap.enabled, "the layer keeps running")
        XCTAssertTrue(snap.errors.isEmpty)
        XCTAssertEqual(cue.prompts.count, 2, "the cue judge kept judging")
    }

    func testRepeatedTransientErrorsStopSelfPivotOnly() {
        var c = config!
        c.text.pivotRearmS = 0
        var d = SelfPivotDriver()
        d.answer = { _ in .failure(GptError.http(503)) }
        let core = core(c)
        let r = d.run(pivots(5, every: 30), core: core, until: 155)
        XCTAssertEqual(r.prompts.count, config.gpt.judgeMaxTransientErrors)
        XCTAssertEqual(core.snapshot.selfPivotStop, .judgeError)
        XCTAssertTrue(core.enabled)
    }

    /// The call's own budget cap still stops the whole layer, self-pivot included.
    func testTheCallBudgetCapStopsEverything() throws {
        let tiny = try ListenMoreConfig.load(overrides: ListenMoreConfig.deepMerge(Self.meetingCard, ["gpt": ["budget_usd_per_call": 0.0]]))
        let core = core(tiny)
        let r = SelfPivotDriver().run(pivot(), core: core, until: 25)
        XCTAssertTrue(r.prompts.isEmpty)
        XCTAssertEqual(core.stopReason, .budgetCap)
    }

    // MARK: criterion 6: group calls and acknowledge-then-story, through to the cue policy

    /// One voice shares, another reacts briefly, the user tells their own story: one judged cue. Another
    /// voice moving on to the standup instead: nothing is judged.
    func testGroupCallPivotBecomesOneCue() {
        var s = PivotScript()
        s.them(PivotLines.share, 0.5, 5.5)
        s.them("Wow, congratulations!", 6.0, 7.0)
        s.you(PivotLines.pivot, 7.5, 13.5)
        let r = SelfPivotDriver().run(s, core: core(), until: 30)
        XCTAssertEqual(r.prompts.count, 1)
        XCTAssertTrue(r.prompts[0].contains("OTHERS: wow, congratulations!"), "both voices are OTHERS")
        XCTAssertEqual(cues(r.offers).map(\.type), [.selfPivot])

        var standup = PivotScript()
        standup.them("I just got back from a week at the lake with the kids and I was so relaxed.", 0.5, 5.5)
        standup.them("Great, let's start the standup. Sam, you go first.", 6.5, 9.0)
        standup.you("Sure, yesterday I finished my part of the migration and today I am on my code reviews, then I will pick up my next ticket.", 9.5, 15.5)
        XCTAssertTrue(SelfPivotDriver().run(standup, core: core(), until: 30).prompts.isEmpty)
    }

    /// Acknowledging first and then telling your own story still counts; acknowledging and asking back doesn't.
    func testAcknowledgeThenStoryIsAPivot() {
        for (share, reply) in [(PivotLines.worried, PivotLines.acknowledgeThenStory),
                               (PivotLines.moved, "Congrats, that's great news! We just bought our first place too and I spent the whole weekend painting the walls and fixing the old floors.")] {
            let r = SelfPivotDriver().run(pivot(share: share, reply: reply), core: core(), until: 25)
            XCTAssertEqual(r.prompts.count, 1, reply)
            XCTAssertEqual(cues(r.offers).map(\.type), [.selfPivot], reply)
        }
        let ask = pivot(share: PivotLines.moved, reply: "Congrats, that's great news! How did the move go, are you all settled in now and is the new place close to work?")
        XCTAssertTrue(SelfPivotDriver().run(ask, core: core(), until: 25).prompts.isEmpty)
        let said = SelfPivotJudgeSpec.instructions.replacingOccurrences(of: "\n", with: " ").split(separator: " ").joined(separator: " ")
        XCTAssertTrue(said.contains(#"Acknowledging first ("congrats", "so sorry", "that sounds great") and then telling ME's own story still counts as self_pivot."#),
                      "the judge is told so")
    }

    /// Offers as the pipeline maps them, through MeetingCard's cue policy.
    func cues(_ offers: [GptCore.Offer]) -> [Cue] {
        let policy = CuePolicy(config: config.cues)
        return offers.compactMap { o in
            CueType(judgeLabel: o.label, provider: .gpt).flatMap {
                policy.offer($0, t: o.t, onset: o.refT, source: .gpt, confidence: o.confidence)
            }
        }
    }
}
