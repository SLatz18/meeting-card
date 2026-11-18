import XCTest
@testable import ListenMoreCore

/// The redirect path of both judges, end to end through the layer: what a failed or refused resend does to the
/// cue judge (stops cue judging only, never the layer or its captions) and to the self-pivot lane; the resend
/// gates reading the layer's state; learned hosts scoped to the key; the ledger's one-step post count; and the
/// posts counted as they go out.

/// The transcriber callbacks a test can push events through (a transcriber error, a usage report).
final class EventPorts: @unchecked Sendable {
    private let lock = NSLock()
    private var ports: [Speaker: @Sendable (TranscriptEvent) -> Void] = [:]

    func set(_ speaker: Speaker, _ port: @escaping @Sendable (TranscriptEvent) -> Void) { lock.withLock { ports[speaker] = port } }
    func emit(_ speaker: Speaker, _ event: TranscriptEvent) { lock.withLock { ports[speaker] }?(event) }
}

/// Counts the layer's reports that judging stopped (and keeps the reason).
final class RedirectStopLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _reasons: [JudgeFailure] = []

    func add(_ failure: JudgeFailure) { lock.withLock { _reasons.append(failure) } }
    var reasons: [JudgeFailure] { lock.withLock { _reasons } }
}

/// Posts `replies(n)` for the n-th post, or throws what `throwing(n)` returns for it.
final class ScriptedHTTP: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _hosts: [String] = []
    private let script: @Sendable (Int) throws -> (Int, Data)

    init(_ script: @escaping @Sendable (Int) throws -> (Int, Data)) { self.script = script }

    var hosts: [String] { lock.withLock { _hosts } }

    func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval) async throws -> (status: Int, body: Data) {
        let n = lock.withLock { () -> Int in
            _hosts.append(url.host ?? "?")
            return _hosts.count
        }
        return try script(n)
    }
}

final class CaptionBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _finals: [Speaker] = []

    func add(_ event: CaptionEvent) {
        if case .final(let speaker, _) = event { lock.withLock { _finals.append(speaker) } }
    }

    /// Final captions so far (speakers only; the text is never kept).
    var finals: Int { lock.withLock { _finals.count } }
}

final class JudgeRedirectRulesTests: XCTestCase {
    var config: ListenMoreConfig!
    let clock = ManualClock(0)
    let offers = OfferBox()
    let key = APIKey("sk-test")!

    override func setUpWithError() throws {
        config = try ListenMoreConfig.load(overrides: SelfPivotLaneTests.meetingCard)
    }

    func cueConfig() throws -> ListenMoreConfig {
        try ListenMoreConfig.load(overrides: ["gpt": ["judge_min_interval_s": 0]])
    }

    func pivots(_ n: Int, every: Double) -> PivotScript {
        var s = PivotScript()
        for k in 0..<n {
            let b = Double(k) * every
            s.them(PivotLines.share, b + 0.5, b + 5.5)
            s.you(PivotLines.pivot, b + 6.0, b + 12.0)
        }
        return s
    }

    struct Ran {
        /// Taken after the last frame, before anything is let go or waited for.
        var inFlight: GptLayer.Snapshot
        var final: GptLayer.Snapshot
    }

    func runLayer(_ s: PivotScript, config: ListenMoreConfig? = nil, cueJudge: CueJudge = FakeJudge(), selfPivotJudge: CueJudge? = nil,
                  allowed: @escaping @Sendable () -> Bool = { true }, count: Int = 1, until: Double, ports: EventPorts = EventPorts(),
                  captions: CaptionBox = CaptionBox(), stops: RedirectStopLog = RedirectStopLog(), during: (TimeInterval, GptLayer) async -> Void = { _, _ in },
                  afterClose: () -> Void = {}, settle: (GptLayer.Snapshot) -> Bool) async -> Ran {
        let clock = clock, offers = offers
        let layer = GptLayer(config: config ?? self.config, now: { clock.now() }, offer: { offers.add($0, $1, $2, $3) },
                             onJudgeStopped: { stops.add($0) }, onCaption: { captions.add($0) },
                             provider: GptJudgeProvider(cueJudge), selfPivotJudge: selfPivotJudge,
                             selfPivotAllowed: allowed, scheduler: InstantScheduler()) { speaker, onEvent in
            ports.set(speaker, onEvent)
            return FakeTranscriber(speaker: speaker, script: Array(repeating: speaker == .me ? PivotLines.pivot : PivotLines.share, count: count),
                                   onEvent: onEvent)
        }
        layer.start()
        for f in s.frames(until: until) {
            clock.set(f.t)
            await during(f.t, layer)
            layer.feed(me: f.me.raw ? GptFrames.voiced : GptFrames.silent, meVad: f.me,
                       others: f.others.raw ? GptFrames.voiced : GptFrames.silent, othersVad: f.others, meRunS: 0)
            _ = await layer.snapshot()
        }
        let inFlight = await layer.snapshot()
        _ = await eventually { settle(await layer.snapshot()) }
        let final = await layer.snapshot()
        await layer.close()
        afterClose()
        return Ran(inFlight: inFlight, final: final)
    }

    func selfPivotJudge(_ http: HTTPTransport, config: ListenMoreConfig? = nil) -> LiveJudge {
        LiveJudge(config: config ?? self.config, key: key, http: http, hosts: LearnedHosts(), spec: .selfPivot)
    }

    func cueJudge(_ http: HTTPTransport, config: ListenMoreConfig) -> LiveJudge {
        LiveJudge(config: config, key: key, http: http, hosts: LearnedHosts())
    }

    func opened() -> Latch {
        let l = Latch()
        l.open()
        return l
    }

    // MARK: R1: the cue judge's redirect-path errors stop cue judging only

    /// 401 incorrect_hostname, then a regional 401: the redirect failed. Cue judging stops; the layer stays
    /// enabled and its captions keep flowing (the second exchange is captioned after the stop).
    func testARegional401StopsOnlyCueJudging() async throws {
        let generic = try cueConfig()
        let http = DelayedHTTP(latch: opened()) { n in n == 1 ? DelayedHTTP.wrongHost() : (401, Data()) }
        let captions = CaptionBox()
        let ran = await runLayer(pivots(2, every: 30), config: generic, cueJudge: cueJudge(http, config: generic), count: 2, until: 60,
                                 captions: captions, settle: { !$0.judgeActive })
        XCTAssertEqual(http.hosts, ["api.openai.com", "eu.api.openai.com"])
        XCTAssertTrue(ran.final.enabled, "the layer is not stopped")
        XCTAssertTrue(ran.final.errors.isEmpty)
        XCTAssertFalse(ran.final.judgeActive)
        XCTAssertEqual(ran.final.judgeStopReason, .hostRejected, "a trusted regional host that didn't work, not an untrusted one")
        XCTAssertEqual(ran.final.otherJudgePosts, 2)
        XCTAssertEqual(captions.finals, 4, "captions keep flowing after the stop")
    }

    /// 401 incorrect_hostname that names only the host just used: nowhere to go. Same outcome: cue judging stops,
    /// one post, the layer goes on.
    func testARedirectToTheSameHostStopsOnlyCueJudging() async throws {
        let generic = try cueConfig()
        let http = DelayedHTTP(latch: opened()) { _ in DelayedHTTP.wrongHost("api.openai.com") }
        let captions = CaptionBox()
        let ran = await runLayer(pivots(2, every: 30), config: generic, cueJudge: cueJudge(http, config: generic), count: 2, until: 60,
                                 captions: captions, settle: { !$0.judgeActive })
        XCTAssertEqual(http.hosts, ["api.openai.com"])
        XCTAssertTrue(ran.final.enabled)
        XCTAssertFalse(ran.final.judgeActive)
        XCTAssertEqual(ran.final.judgeStopReason, .hostRejected)
        XCTAssertEqual(captions.finals, 4)
    }

    /// 401 incorrect_hostname, then a regional 500: a transient error, not a rejected host. Two posts, the verdict
    /// is skipped, the layer and cue judging both stay on.
    func testARegional500IsTransientForTheCueJudge() async throws {
        let generic = try cueConfig()
        let http = DelayedHTTP(latch: opened()) { n in n == 1 ? DelayedHTTP.wrongHost() : (500, Data()) }
        let ran = await runLayer(pivots(1, every: 200), config: generic, cueJudge: cueJudge(http, config: generic), until: 25,
                                 settle: { $0.judgeLatenciesMs.count >= 1 })
        XCTAssertEqual(http.hosts, ["api.openai.com", "eu.api.openai.com"])
        XCTAssertTrue(ran.final.enabled)
        XCTAssertTrue(ran.final.judgeActive)
        XCTAssertEqual(ran.final.transientErrors, 1)
        XCTAssertTrue(ran.final.errors.isEmpty)
        XCTAssertNil(ran.final.judgeStopReason)
    }

    /// The same three replies in order, one after the other, on one judge: the first call's redirect fails (cue
    /// judging stops); a later regional 500 would only have been transient.
    func testRedirectErrorsAreNeverNonTransientForTheLayer() {
        let hostRejected = GptError.hostRejected(first: "api.openai.com", regional: "eu.api.openai.com", inner: "HTTP 401")
        for error in [hostRejected, .untrustedHost, .redirectToSameHost, .resendRefused] {
            XCTAssertTrue(error.isRedirectProblem, "\(error)")
            XCTAssertFalse(GptError.isTransient(error))
        }
        XCTAssertFalse(GptError.http(500).isRedirectProblem)
        XCTAssertTrue(GptError.isTransient(GptError.http(500)))
        XCTAssertEqual(JudgeFailure.untrustedHost.kind, .untrustedHost)
        XCTAssertEqual(JudgeFailure.hostRejected.kind, .hostRejected)
        XCTAssertNotEqual(JudgeFailure.untrustedHost, JudgeFailure.hostRejected)
        for failure in [JudgeFailure.untrustedHost, .hostRejected] {
            XCTAssertFalse(failure.description.contains("401"))
            XCTAssertFalse(failure.description.lowercased().contains("typesafe"))
        }
    }

    // MARK: R1: the self-pivot lane

    /// A 500 on the resend is transient for self-pivot: it counts toward `judge_max_transient_errors` and stops
    /// nothing before that; at the limit it stops self-pivot for the call.
    func testARegional500IsTransientForSelfPivot() async throws {
        let http = DelayedHTTP(latch: opened()) { n in n == 1 ? DelayedHTTP.wrongHost() : (500, Data()) }
        let ran = await runLayer(pivots(1, every: 200), selfPivotJudge: selfPivotJudge(http), until: 30,
                                 settle: { $0.selfPivotFailures >= 1 })
        XCTAssertEqual(http.hosts, ["api.openai.com", "eu.api.openai.com"])
        XCTAssertEqual(ran.final.selfPivotFailures, 1)
        XCTAssertNil(ran.final.selfPivotStop, "one transient error stops nothing (the limit is \(config.gpt.judgeMaxTransientErrors))")
        XCTAssertEqual(ran.final.selfPivotCallPosts, 2)

        var one = config!
        one.gpt.judgeMaxTransientErrors = 1
        let again = DelayedHTTP(latch: opened()) { n in n == 1 ? DelayedHTTP.wrongHost() : (500, Data()) }
        let atLimit = await runLayer(pivots(1, every: 200), config: one, selfPivotJudge: selfPivotJudge(again, config: one), until: 30,
                                     settle: { $0.selfPivotFailures >= 1 })
        XCTAssertEqual(atLimit.final.selfPivotStop, .judgeError, "at the limit it stops")
    }

    /// A regional 401 is a rejected redirect: the lane stops for the call, the layer does not.
    func testARegional401StopsSelfPivot() async throws {
        let http = DelayedHTTP(latch: opened()) { n in n == 1 ? DelayedHTTP.wrongHost() : (401, Data()) }
        let ran = await runLayer(pivots(1, every: 200), selfPivotJudge: selfPivotJudge(http), until: 30,
                                 settle: { $0.selfPivotFailures >= 1 })
        XCTAssertEqual(http.hosts.count, 2)
        XCTAssertEqual(ran.final.selfPivotStop, .judgeError)
        XCTAssertTrue(ran.final.enabled)
    }

    /// A resend refused because the switch went off while the first post was in flight does not stop the lane:
    /// switched back on, the next candidate is judged.
    func testARefusedResendDoesNotStopTheLane() async throws {
        var c = config!
        c.text.pivotRearmS = 0
        let box = SwitchBox()
        let latch = Latch()
        let http = DelayedHTTP(latch: latch) { n in n == 1 ? DelayedHTTP.wrongHost() : DelayedHTTP.ok("none") }
        var released = false
        let ran = await runLayer(pivots(2, every: 30), config: c, selfPivotJudge: selfPivotJudge(http, config: c), allowed: { box.isOn },
                                 count: 2, until: 46,
                                 during: { t, layer in
                                     if t >= 20 && !released {
                                         released = true
                                         box.set(false)
                                         latch.open()
                                         _ = await eventually { await layer.snapshot().selfPivotFailures >= 1 }
                                         box.set(true)
                                     }
                                 },
                                 settle: { $0.selfPivotJudgeCalls >= 2 && $0.judgeLatenciesMs.count >= 2 })
        XCTAssertNil(ran.final.selfPivotStop, "a refused resend is not a judge error")
        XCTAssertEqual(ran.final.selfPivotFailures, 1)
        XCTAssertEqual(ran.final.selfPivotJudgeCalls, 2, "switched back on, the next candidate is judged")
        XCTAssertEqual(http.hosts.count, 2, "the refused call's one post, then the next call's one post")
        XCTAssertEqual(ran.final.selfPivotCallPosts, 2)
    }

    // MARK: R2: both resend gates read the layer

    enum Trigger: CaseIterable { case fail, budget }

    func stop(_ trigger: Trigger, _ ports: EventPorts) {
        switch trigger {
        case .fail: ports.emit(.me, .error("boom"))
        case .budget: ports.emit(.me, .usage(.me, 10_000_000))
        }
    }

    /// The layer stops (a hard error, or the layer budget spent) while the first post is in flight: the reply
    /// is a 401 incorrect_hostname, and the resend is not sent. Exactly one post, for each judge.
    func testNoResendAfterTheLayerStopsWhileThePostIsInFlight() async throws {
        for trigger in Trigger.allCases {
            let selfLatch = Latch()
            let selfHttp = DelayedHTTP(latch: selfLatch) { n in n == 1 ? DelayedHTTP.wrongHost() : DelayedHTTP.ok("none") }
            var fired = false
            let selfPorts = EventPorts()
            let selfRan = await runLayer(pivots(1, every: 200), selfPivotJudge: selfPivotJudge(selfHttp), until: 30, ports: selfPorts,
                                         during: { t, layer in
                                             if t >= 20 && !fired {
                                                 fired = true
                                                 self.stop(trigger, selfPorts)
                                                 _ = await layer.snapshot()
                                                 selfLatch.open()
                                                 _ = await eventually { await layer.snapshot().judgeLatenciesMs.count >= 1 }
                                             }
                                         },
                                         settle: { $0.judgeLatenciesMs.count >= 1 })
            XCTAssertEqual(selfHttp.hosts.count, 1, "self-pivot, \(trigger): no resend once the layer has stopped")
            XCTAssertEqual(selfRan.final.selfPivotCallPosts, 1, "\(trigger)")

            let generic = try cueConfig()
            let cueLatch = Latch()
            let cueHttp = DelayedHTTP(latch: cueLatch) { n in n == 1 ? DelayedHTTP.wrongHost() : DelayedHTTP.ok("none") }
            var cueFired = false
            let cuePorts = EventPorts()
            let cueStops = RedirectStopLog()
            let cueRan = await runLayer(pivots(1, every: 200), config: generic, cueJudge: cueJudge(cueHttp, config: generic), until: 30,
                                        ports: cuePorts, stops: cueStops,
                                        during: { t, layer in
                                            if t >= 20 && !cueFired {
                                                cueFired = true
                                                self.stop(trigger, cuePorts)
                                                _ = await layer.snapshot()
                                                cueLatch.open()
                                                _ = await eventually { await layer.snapshot().judgeLatenciesMs.count >= 1 }
                                            }
                                        },
                                        settle: { $0.judgeLatenciesMs.count >= 1 })
            XCTAssertEqual(cueHttp.hosts.count, 1, "cue judge, \(trigger): no resend once the layer has stopped")
            XCTAssertEqual(cueRan.final.otherJudgePosts, 1, "\(trigger)")
            XCTAssertNil(cueRan.final.judgeStopReason, "a refused resend reports nothing, \(trigger)")
            XCTAssertEqual(cueRan.final.judgeFailures, 0, "\(trigger)")
            XCTAssertNil(cueRan.final.lastJudgeFailure, "\(trigger)")
            XCTAssertTrue(cueStops.reasons.isEmpty, "onJudgeStopped is never called, \(trigger)")
        }
    }

    /// Cue judging stopped (not the layer) while the first post is in flight: the cue judge's own gate refuses too.
    func testNoCueResendAfterCueJudgingStops() async throws {
        let generic = try cueConfig()
        let core = GptCore(config: generic)
        let posts = core.cuePosts()
        XCTAssertTrue(posts.mayResend())
        core.stopJudging()
        XCTAssertFalse(posts.mayResend(), "judging stopped")

        let live = GptCore(config: generic)
        let gate = live.cuePosts()
        live.fail("boom")
        XCTAssertFalse(gate.mayResend(), "the layer stopped")
        let selfGate = GptCore(config: generic)
        let selfPosts = selfGate.selfPivotPosts()
        selfGate.fail("boom")
        XCTAssertFalse(selfPosts.mayResend())
        let closing = GptCore(config: generic)
        let closingPosts = closing.cuePosts()
        closing.closeGates()
        XCTAssertFalse(closingPosts.mayResend(), "the layer is closing")
    }

    // MARK: a resend that answers 200 with a body that isn't the expected JSON

    /// 401 incorrect_hostname, then 200 `not json` on the resend: the parse failure is a regional host that didn't
    /// work (stops cue judging only), not an error that reaches `fail()`. Exactly two posts; the layer stays on and
    /// its captions keep arriving.
    func testANonJSONResendStopsOnlyCueJudging() async throws {
        let generic = try cueConfig()
        let http = DelayedHTTP(latch: opened()) { n in n == 1 ? DelayedHTTP.wrongHost() : (200, Data("not json".utf8)) }
        let captions = CaptionBox()
        let stops = RedirectStopLog()
        let ran = await runLayer(pivots(2, every: 30), config: generic, cueJudge: cueJudge(http, config: generic), count: 2, until: 60,
                                 captions: captions, stops: stops, settle: { !$0.judgeActive })
        XCTAssertEqual(http.hosts, ["api.openai.com", "eu.api.openai.com"], "exactly two posts")
        XCTAssertTrue(ran.final.enabled, "the layer is still on")
        XCTAssertTrue(ran.final.errors.isEmpty, "no layer error")
        XCTAssertFalse(ran.final.judgeActive)
        XCTAssertEqual(ran.final.judgeStopReason, .hostRejected)
        XCTAssertEqual(stops.reasons, [.hostRejected])
        XCTAssertEqual(captions.finals, 4, "captions keep arriving after the stop")
    }

    /// The same for the self-pivot lane: it stops for the call, the layer stays on and captions keep arriving.
    func testANonJSONResendStopsOnlySelfPivot() async throws {
        let http = DelayedHTTP(latch: opened()) { n in n == 1 ? DelayedHTTP.wrongHost() : (200, Data("not json".utf8)) }
        let captions = CaptionBox()
        let ran = await runLayer(pivots(2, every: 30), selfPivotJudge: selfPivotJudge(http), count: 2, until: 60,
                                 captions: captions, settle: { $0.selfPivotStop != nil })
        XCTAssertEqual(http.hosts, ["api.openai.com", "eu.api.openai.com"], "exactly two posts")
        XCTAssertEqual(ran.final.selfPivotStop, .judgeError)
        XCTAssertTrue(ran.final.enabled)
        XCTAssertTrue(ran.final.errors.isEmpty)
        XCTAssertEqual(ran.final.selfPivotCallPosts, 2)
        XCTAssertEqual(captions.finals, 4, "captions keep arriving after the stop")
    }

    /// On the resend, a network error and a cancellation stay what they are; a body that isn't JSON is a
    /// `hostRejected`.
    func testTheResendKeepsNetworkErrorsAndWrapsTheRest() async throws {
        func outcome(_ script: @escaping @Sendable (Int) throws -> (Int, Data)) async -> (Error?, Int) {
            let http = ScriptedHTTP(script)
            do {
                _ = try await LiveJudge(config: config, key: key, http: http, hosts: LearnedHosts()).judge(prompt: "x")
                return (nil, http.hosts.count)
            } catch {
                return (error, http.hosts.count)
            }
        }
        let (timeout, timeoutPosts) = await outcome { n in
            if n == 1 { return DelayedHTTP.wrongHost() }
            throw URLError(.timedOut)
        }
        XCTAssertEqual((timeout as? URLError)?.code, .timedOut)
        XCTAssertTrue(GptError.isTransient(try XCTUnwrap(timeout)))
        XCTAssertEqual(timeoutPosts, 2)
        let (cancelled, cancelledPosts) = await outcome { n in
            if n == 1 { return DelayedHTTP.wrongHost() }
            throw CancellationError()
        }
        XCTAssertTrue(cancelled is CancellationError)
        XCTAssertEqual(cancelledPosts, 2)
        let (garbled, garbledPosts) = await outcome { n in n == 1 ? DelayedHTTP.wrongHost() : (200, Data("not json".utf8)) }
        guard case .hostRejected? = garbled as? GptError else { return XCTFail("expected hostRejected, got \(String(describing: garbled))") }
        XCTAssertEqual(garbledPosts, 2, "never a third")
        let (empty, _) = await outcome { n in n == 1 ? DelayedHTTP.wrongHost() : (200, Data()) }
        guard case .hostRejected? = empty as? GptError else { return XCTFail("expected hostRejected, got \(String(describing: empty))") }
    }

    /// What finishJudge reports for each redirect-path error: its own reason, or nothing for a refused resend.
    func testFinishJudgeMapsRedirectErrorsToTheirReasons() throws {
        let req = GptCore.JudgeRequest(refT: 1, reason: "me_reply")
        let cases: [(GptError, JudgeFailure?)] = [
            (.untrustedHost, .untrustedHost), (.redirectToSameHost, .hostRejected),
            (.hostRejected(first: "api.openai.com", regional: "eu.api.openai.com", inner: "HTTP 401"), .hostRejected),
            (.resendRefused, nil),
        ]
        for (error, reason) in cases {
            let core = GptCore(config: try cueConfig())
            XCTAssertNil(core.finishJudge(req, result: .failure(error), now: 5))
            let snap = core.snapshot
            XCTAssertTrue(snap.enabled, "\(error)")
            XCTAssertEqual(snap.judgeStopReason, reason, "\(error)")
            XCTAssertEqual(snap.judgeActive, reason == nil, "\(error)")
            XCTAssertEqual(snap.judgeFailures, reason == nil ? 0 : 1, "\(error)")
            XCTAssertEqual(snap.lastJudgeFailure, reason?.description, "\(error)")
        }
    }

    /// A refused self-pivot resend doesn't stop the lane, but the learned host that answered 401 is forgotten.
    func testARefusedResendForgetsTheLearnedHost() async throws {
        let hosts = LearnedHosts()
        let scope = KeyScope(key)
        hosts.learn("https://eu.api.openai.com/v1/responses", for: config.gpt.responsesUrl, scope: scope)
        let http = DelayedHTTP(latch: opened()) { _ in DelayedHTTP.wrongHost("api.openai.com") }
        let judge = LiveJudge(config: config, key: key, http: http, hosts: hosts, spec: .selfPivot)
        do {
            _ = try await judge.judge(prompt: "x", posts: JudgePosts(resendGate: { false }))
            XCTFail("expected the refusal")
        } catch {
            XCTAssertEqual(error as? GptError, .resendRefused)
        }
        XCTAssertEqual(http.hosts, ["eu.api.openai.com"], "one post")
        XCTAssertNil(hosts.url(for: config.gpt.responsesUrl, scope: scope))
        XCTAssertEqual(judge.currentURL, config.gpt.responsesUrl)
    }

    // MARK: R3: learned hosts belong to the key

    func okHTTP(_ replies: @escaping @Sendable (Int) -> (Int, Data) = { _ in DelayedHTTP.ok("none") }) -> DelayedHTTP {
        DelayedHTTP(latch: opened(), replies: replies)
    }

    /// Key A learns a regional host; a judge on key B starts on the configured host (one post, no extra resend);
    /// a judge on key A starts on the regional one.
    func testAKeyChangeStartsCleanOnTheConfiguredHost() async throws {
        let hosts = LearnedHosts()
        let keyA = APIKey("sk-key-a")!, keyB = APIKey("sk-key-b")!
        let a = okHTTP { n in n == 1 ? DelayedHTTP.wrongHost() : DelayedHTTP.ok("none") }
        _ = try await LiveJudge(config: config, key: keyA, http: a, hosts: hosts).judge(prompt: "x")
        XCTAssertEqual(a.hosts, ["api.openai.com", "eu.api.openai.com"])

        let b = okHTTP()
        let judgeB = LiveJudge(config: config, key: keyB, http: b, hosts: hosts)
        XCTAssertEqual(judgeB.currentURL, config.gpt.responsesUrl, "key B knows nothing key A learned")
        _ = try await judgeB.judge(prompt: "x")
        XCTAssertEqual(b.hosts, ["api.openai.com"], "exactly one post, to the default host")

        let again = okHTTP()
        _ = try await LiveJudge(config: config, key: keyA, http: again, hosts: hosts).judge(prompt: "x")
        XCTAssertEqual(again.hosts, ["eu.api.openai.com"], "key A still has its own")
    }

    /// Key B is rejected by a learned host: one post, the host is forgotten for B and reset to the configured
    /// URL with no resend, and the next call goes to the configured host.
    func testARejectedKeyOnALearnedHostResetsToTheConfiguredHost() async throws {
        let hosts = LearnedHosts()
        let keyB = APIKey("sk-key-b")!
        hosts.learn("https://eu.api.openai.com/v1/responses", for: config.gpt.responsesUrl, scope: KeyScope(keyB))
        let http = okHTTP { n in n == 1 ? (401, Data(#"{"error":{"code":"invalid_api_key","message":"x"}}"#.utf8)) : DelayedHTTP.ok("none") }
        let judge = LiveJudge(config: config, key: keyB, http: http, hosts: hosts)
        XCTAssertEqual(judge.currentURL, "https://eu.api.openai.com/v1/responses")
        do {
            _ = try await judge.judge(prompt: "x")
            XCTFail("expected the rejection")
        } catch {
            XCTAssertEqual(error as? GptError, .http(401))
        }
        XCTAssertEqual(http.hosts, ["eu.api.openai.com"], "one post, no resend")
        XCTAssertNil(hosts.url(for: config.gpt.responsesUrl, scope: KeyScope(keyB)))
        XCTAssertEqual(judge.currentURL, config.gpt.responsesUrl)
        _ = try await judge.judge(prompt: "y")
        XCTAssertEqual(http.hosts, ["eu.api.openai.com", "api.openai.com"], "the next call goes to the configured host")
    }

    /// The fingerprint is salted, one-way and never shown: it isn't the key, doesn't contain it, differs per key,
    /// and no description, mirror, error text or snapshot carries it.
    func testTheKeyFingerprintIsNeverShown() async throws {
        let key = APIKey("sk-fingerprint-probe-0123456789")!
        let scope = KeyScope(key)
        XCTAssertEqual(scope, KeyScope(key))
        XCTAssertNotEqual(scope, KeyScope(APIKey("sk-fingerprint-probe-other")!))
        XCTAssertEqual(scope.fingerprint.count, 16)
        XCTAssertFalse(scope.fingerprint.contains(key.value) || key.value.contains(scope.fingerprint))
        XCTAssertEqual(scope.fingerprint, scope.fingerprint.lowercased())
        for shown in [scope.description, scope.debugDescription, String(describing: scope), String(reflecting: scope),
                      "\(scope)", String(describing: Mirror(reflecting: scope).children.map { "\($0)" })] {
            XCTAssertFalse(shown.contains(scope.fingerprint), shown)
            XCTAssertFalse(shown.contains(key.value), shown)
        }
        let hosts = LearnedHosts()
        hosts.learn("https://eu.api.openai.com/v1/responses", for: config.gpt.responsesUrl, scope: scope)
        XCTAssertFalse(String(describing: hosts).contains(scope.fingerprint))
        XCTAssertFalse(String(reflecting: hosts).contains(scope.fingerprint))

        let http = DelayedHTTP(latch: opened()) { _ in DelayedHTTP.wrongHost("api.openai.com.evil.example") }
        let judge = LiveJudge(config: config, key: key, http: http, hosts: hosts, spec: .selfPivot)
        let ran = await runLayer(pivots(1, every: 200), selfPivotJudge: judge, until: 30, settle: { $0.selfPivotFailures >= 1 })
        var outputs = [String(describing: ran.final), ran.final.errors.joined(separator: "\n"), ran.final.lastJudgeFailure ?? ""]
        for error in [GptError.http(401), .untrustedHost, .redirectToSameHost, .resendRefused,
                      .hostRejected(first: "api.openai.com", regional: "eu.api.openai.com", inner: "HTTP 401")] {
            outputs.append(GptError.safe(error))
            outputs.append(String(describing: error))
        }
        for text in outputs {
            XCTAssertFalse(text.contains(scope.fingerprint), text)
            XCTAssertFalse(text.contains(key.value), text)
        }
    }

    func testSHA256MatchesTheStandardVectors() {
        func hex(_ s: String) -> String { SHA256.hash(Array(s.utf8)).map { String(format: "%02x", $0) }.joined() }
        XCTAssertEqual(hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(hex(String(repeating: "a", count: 1000)), "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3")
    }

    // MARK: nits

    /// The ledger counts a post in the same step as it checks the caps: with 19 of 20 posts used, any number of
    /// concurrent callers get exactly one more.
    func testTheLastPostGoesToExactlyOneConcurrentCaller() {
        let ledger = SelfPivotLedger()
        for _ in 0..<19 { XCTAssertTrue(ledger.tryRecordPost(cap: 20, usdCap: 1)) }
        let wins = PostTally()
        DispatchQueue.concurrentPerform(iterations: 64) { _ in
            if ledger.tryRecordPost(cap: 20, usdCap: 1) { wins.add() }
        }
        XCTAssertEqual(wins.value, 1)
        XCTAssertEqual(ledger.posts, 20)
        XCTAssertFalse(ledger.tryRecordPost(cap: 20, usdCap: 1))

        let spent = SelfPivotLedger()
        spent.addUsd(0.02)
        XCTAssertFalse(spent.tryRecordPost(cap: 20, usdCap: 0.02), "at the spend cap")
        let stopped = SelfPivotLedger()
        stopped.stop(.judgeError)
        XCTAssertFalse(stopped.tryRecordPost(cap: 20, usdCap: 1), "judging stopped")
    }

    /// A cue judge request that was already scheduled can't post once cue judging has stopped.
    func testBeginJudgeRefusesAfterStopJudging() throws {
        let generic = try cueConfig()
        let core = GptCore(config: generic)
        let req = GptCore.JudgeRequest(refT: 1, reason: "me_reply")
        XCTAssertNotNil(core.beginJudge(req, now: 5))
        XCTAssertNotNil(core.beginJudge(req, now: 5, for: .gpt))
        core.stopJudging()
        XCTAssertNil(core.beginJudge(req, now: 6), "the prompt form")
        XCTAssertNil(core.beginJudge(req, now: 6, for: .gpt), "the provider form")
        let failed = GptCore(config: generic)
        failed.fail("boom")
        XCTAssertNil(failed.beginJudge(req, now: 5), "nor after the layer stopped")
    }

    /// The cue judge's posts are counted as each goes out, not when the call finishes: a snapshot with the first
    /// post still in flight already has it, and closing the layer mid-call loses nothing.
    func testCuePostsCountEvenIfTheSessionClosesMidCall() async throws {
        let core = GptCore(config: try cueConfig())
        let posts = core.cuePosts()
        posts.recordSent()
        XCTAssertEqual(core.snapshot.otherJudgePosts, 1, "counted at the send")

        let generic = try cueConfig()
        let latch = Latch()
        let http = DelayedHTTP(latch: latch) { n in n == 1 ? DelayedHTTP.wrongHost() : DelayedHTTP.ok("none") }
        let ran = await runLayer(pivots(1, every: 200), config: generic, cueJudge: cueJudge(http, config: generic), until: 25,
                                 afterClose: { latch.open() }, settle: { _ in true })
        XCTAssertEqual(http.hosts.count, 1)
        XCTAssertEqual(ran.inFlight.otherJudgePosts, 1, "the post in flight is counted before the call ends")
        XCTAssertEqual(ran.final.otherJudgePosts, 1)
        _ = await eventually { true }
        XCTAssertEqual(http.hosts.count, 1, "released after the close: no resend")
    }
}
