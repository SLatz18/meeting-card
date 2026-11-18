import XCTest
@testable import ListenMoreCore

/// One rule for both judges: a judge call makes one HTTP post, and may make exactly one more, only after a
/// `401 incorrect_hostname` that names a trusted OpenAI host, and never a third. Every post counts: in the
/// self-pivot ledger (toward its call cap and spend cap) and in the cue judge's own count. A slow or late
/// reply sends nothing more. (A paid precision run once sent 13 posts for 12 judged cases: the 13th was
/// the regional-host resend, which nothing counted.)

/// Holds a reply until the test lets it go; deterministic, no real waiting.
final class Latch: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            lock.lock()
            if isOpen {
                lock.unlock()
                c.resume()
            } else {
                waiters.append(c)
                lock.unlock()
            }
        }
    }

    func open() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            isOpen = true
            defer { waiters.removeAll() }
            return waiters
        }
        for c in all { c.resume() }
    }
}

/// A self-pivot judge whose replies wait on a latch (a slow network). Counts requests and how many were
/// in flight at once; never keeps the prompt.
final class SlowSelfPivotJudge: CueJudge, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private var inFlight = 0
    private var _maxInFlight = 0
    private let latch: Latch
    private let verdict: JudgeResult

    init(latch: Latch, verdict: JudgeResult = JudgeResult(cue: "self_pivot", confidence: 0.95, shortReason: "")) {
        self.latch = latch
        self.verdict = verdict
    }

    var calls: Int { lock.withLock { _calls } }
    var maxInFlight: Int { lock.withLock { _maxInFlight } }

    func judge(prompt: String) async throws -> (JudgeResult, JudgeUsage) {
        lock.withLock {
            _calls += 1
            inFlight += 1
            _maxInFlight = max(_maxInFlight, inFlight)
        }
        await latch.wait()
        lock.withLock { inFlight -= 1 }
        return (verdict, JudgeUsage(inputTokens: 500, cachedTokens: 0, outputTokens: 20))
    }
}

/// Answers every request with a canned status and body after the latch opens, and counts what was sent.
final class DelayedHTTP: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _hosts: [String] = []
    private let latch: Latch
    private let replies: @Sendable (Int) -> (Int, Data)

    init(latch: Latch, replies: @escaping @Sendable (Int) -> (Int, Data)) {
        self.latch = latch
        self.replies = replies
    }

    var hosts: [String] { lock.withLock { _hosts } }

    func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval) async throws -> (status: Int, body: Data) {
        let n = lock.withLock { () -> Int in
            _hosts.append(url.host ?? "?")
            return _hosts.count
        }
        await latch.wait()
        return replies(n)
    }

    static func ok(_ cue: String, confidence: Double = 0.95) -> (Int, Data) {
        let inner = #"{"cue":"\#(cue)","confidence":\#(confidence),"short_reason":"x"}"#
        let reply: [String: Any] = ["output": [["type": "message", "content": [["type": "output_text", "text": inner]]]],
                                    "usage": ["input_tokens": 400, "output_tokens": 20]]
        return (200, try! JSONSerialization.data(withJSONObject: reply))
    }

    static func wrongHost(_ host: String = "eu.api.openai.com") -> (Int, Data) {
        (401, GptClientTests.hostError("Use the regional host \(host) for this project."))
    }
}

final class SelfPivotSingleRequestTests: XCTestCase {
    var config: ListenMoreConfig!
    let clock = ManualClock(0)
    let offers = OfferBox()
    let key = APIKey("sk-test")!

    override func setUpWithError() throws {
        config = try ListenMoreConfig.load(overrides: SelfPivotLaneTests.meetingCard)
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

    /// The layer on the manual clock. `during` runs at each frame (to open a latch at a chosen moment).
    func runLayer(_ s: PivotScript, config: ListenMoreConfig? = nil, cueJudge: CueJudge = FakeJudge(), selfPivotJudge: CueJudge?,
                  count: Int = 1, until: Double, during: (TimeInterval) -> Void = { _ in },
                  settle: (GptLayer.Snapshot) -> Bool) async -> GptLayer.Snapshot {
        let clock = clock, offers = offers
        let layer = GptLayer(config: config ?? self.config, now: { clock.now() }, offer: { offers.add($0, $1, $2, $3) },
                             judge: cueJudge, selfPivotJudge: selfPivotJudge, selfPivotAllowed: { true },
                             scheduler: InstantScheduler()) { speaker, onEvent in
            FakeTranscriber(speaker: speaker, script: Array(repeating: speaker == .me ? PivotLines.pivot : PivotLines.share, count: count),
                            onEvent: onEvent)
        }
        layer.start()
        for f in s.frames(until: until) {
            clock.set(f.t)
            during(f.t)
            layer.feed(me: f.me.raw ? GptFrames.voiced : GptFrames.silent, meVad: f.me,
                       others: f.others.raw ? GptFrames.voiced : GptFrames.silent, othersVad: f.others, meRunS: 0)
            _ = await layer.snapshot()
        }
        _ = await eventually { settle(await layer.snapshot()) }
        let snap = await layer.snapshot()
        await layer.close()
        return snap
    }

    func selfPivotJudge(_ http: HTTPTransport, config: ListenMoreConfig? = nil, hosts: LearnedHosts = LearnedHosts()) -> LiveJudge {
        LiveJudge(config: config ?? self.config, key: key, http: http, hosts: hosts, spec: .selfPivot)
    }

    // MARK: the lane: a candidate has one judge call

    /// A reply still on its way, past the end of the exchange and many frames later, sends nothing more:
    /// the candidate has exactly one post, in flight, until it answers.
    func testASlowReplySendsNoSecondRequestForTheCandidate() async throws {
        let latch = Latch()
        let judge = SlowSelfPivotJudge(latch: latch)
        let snap = await runLayer(pivots(1, every: 200), selfPivotJudge: judge, until: 60,
                                  during: { t in if t >= 59.9 { latch.open() } },
                                  settle: { $0.selfPivotJudgeCalls >= 1 && $0.judgeLatenciesMs.count >= 1 })
        XCTAssertEqual(snap.pivotCandidates, 1)
        XCTAssertEqual(judge.calls, 1, "one request for the one candidate, however long the reply took")
        XCTAssertEqual(judge.maxInFlight, 1)
        XCTAssertEqual(snap.selfPivotJudgeCalls, 1)
        XCTAssertEqual(snap.selfPivotPosts, 1)
        XCTAssertEqual(snap.selfPivotCallPosts, 1)
    }

    /// A later candidate that arrives while the first reply is still out waits for it: one in flight at a
    /// time, each candidate judged once.
    func testALaterCandidateQueuesBehindASlowReplyAndEachIsSentOnce() async throws {
        var c = config!
        c.text.pivotRearmS = 0
        let latch = Latch()
        let judge = SlowSelfPivotJudge(latch: latch)
        let snap = await runLayer(pivots(2, every: 30), config: c, selfPivotJudge: judge, count: 2, until: 46,
                                  during: { t in if t >= 45.9 { latch.open() } },
                                  settle: { $0.selfPivotJudgeCalls >= 2 && $0.judgeLatenciesMs.count >= 2 })
        XCTAssertEqual(snap.pivotCandidates, 2)
        XCTAssertEqual(judge.calls, 2, "two candidates, two calls")
        XCTAssertEqual(judge.maxInFlight, 1, "never two in flight")
        XCTAssertEqual(snap.selfPivotCallPosts, 2)
    }

    // MARK: self-pivot through the layer, over a delayed HTTP stub

    /// A normal call, with a slow reply: one judge call, one post, counted once.
    func testSelfPivotNormalCallIsOnePost() async throws {
        let latch = Latch()
        let http = DelayedHTTP(latch: latch) { _ in DelayedHTTP.ok("none") }
        let snap = await runLayer(pivots(1, every: 200), selfPivotJudge: selfPivotJudge(http), until: 30,
                                  during: { t in if t >= 29.9 { latch.open() } },
                                  settle: { $0.judgeLatenciesMs.count >= 1 })
        XCTAssertEqual(http.hosts, ["api.openai.com"])
        XCTAssertEqual(snap.selfPivotJudgeCalls, 1)
        XCTAssertEqual(snap.selfPivotPosts, 1)
        XCTAssertEqual(snap.selfPivotCallPosts, http.hosts.count)
    }

    /// The 401 path: exactly two posts for the one candidate, both counted in the ledger, the run's posts and
    /// the spend (from the reply that carried usage); still one judge call.
    func testSelfPivotIncorrectHostnameIsExactlyTwoCountedPosts() async throws {
        let latch = Latch()
        let http = DelayedHTTP(latch: latch) { n in n == 1 ? DelayedHTTP.wrongHost() : DelayedHTTP.ok("none") }
        let snap = await runLayer(pivots(1, every: 200), selfPivotJudge: selfPivotJudge(http), until: 30,
                                  during: { t in if t >= 29.9 { latch.open() } },
                                  settle: { $0.judgeLatenciesMs.count >= 1 })
        XCTAssertEqual(http.hosts, ["api.openai.com", "eu.api.openai.com"])
        XCTAssertEqual(snap.selfPivotJudgeCalls, 1)
        XCTAssertEqual(snap.selfPivotPosts, 2)
        XCTAssertEqual(snap.selfPivotCallPosts, 2)
        XCTAssertEqual(snap.selfPivotCallPosts, http.hosts.count, "every post is a counted post")
        XCTAssertGreaterThan(snap.selfPivotCallUsd, 0)
        XCTAssertNil(snap.selfPivotStop)
    }

    /// A second 401 doesn't resend again: two posts and the call ends, and self-pivot stops for the call.
    func testSelfPivotSecondUnauthorizedNeverMakesAThirdPost() async throws {
        let latch = Latch()
        latch.open()
        let http = DelayedHTTP(latch: latch) { _ in DelayedHTTP.wrongHost() }
        let snap = await runLayer(pivots(1, every: 200), selfPivotJudge: selfPivotJudge(http), until: 30,
                                  settle: { $0.selfPivotFailures >= 1 })
        XCTAssertEqual(http.hosts, ["api.openai.com", "eu.api.openai.com"], "never a third")
        XCTAssertEqual(snap.selfPivotPosts, 2)
        XCTAssertEqual(snap.selfPivotCallPosts, 2)
        XCTAssertEqual(snap.selfPivotJudgeCalls, 1)
        XCTAssertEqual(snap.selfPivotStop, .judgeError)
    }

    /// The 20-call cap counts posts: with a cap of 3, a call that resends uses two, and the next call's
    /// resend would be the fourth post, so it isn't sent. A refused resend doesn't stop the lane: the cap
    /// holds the later candidates itself.
    func testTheCapCountsEveryPostIncludingResends() async throws {
        var c = config!
        c.text.pivotRearmS = 0
        c.gpt.selfPivotMaxJudgeCallsPerCall = 3
        let latch = Latch()
        latch.open()
        let http = DelayedHTTP(latch: latch) { n in
            switch n {
            case 1: DelayedHTTP.wrongHost("eu.api.openai.com")
            case 3: DelayedHTTP.wrongHost("us.api.openai.com")
            default: DelayedHTTP.ok("none")
            }
        }
        let snap = await runLayer(pivots(4, every: 30), config: c, selfPivotJudge: selfPivotJudge(http, config: c), count: 4, until: 125,
                                  settle: { $0.selfPivotFailures >= 1 && $0.selfPivotCapped >= 2 })
        XCTAssertEqual(http.hosts.count, 3, "post 1 and its resend, then post 3 whose resend would be over the cap")
        XCTAssertEqual(snap.selfPivotCallPosts, 3)
        XCTAssertEqual(snap.selfPivotJudgeCalls, 2)
        XCTAssertNil(snap.selfPivotStop, "a refused resend doesn't stop self-pivot")
        XCTAssertEqual(snap.selfPivotCapped, 2)
    }

    /// The spend cap counts the resend's usage: the one call that resends spends past a tiny cap, and
    /// nothing more is sent.
    func testTheSpendCapCountsAResendCall() async throws {
        var c = config!
        c.text.pivotRearmS = 0
        c.gpt.selfPivotBudgetUsdPerCall = 1e-9
        let latch = Latch()
        latch.open()
        let http = DelayedHTTP(latch: latch) { n in n == 1 ? DelayedHTTP.wrongHost() : DelayedHTTP.ok("none") }
        let snap = await runLayer(pivots(3, every: 30), config: c, selfPivotJudge: selfPivotJudge(http, config: c), count: 3, until: 95,
                                  settle: { $0.selfPivotStop != nil })
        XCTAssertEqual(http.hosts.count, 2)
        XCTAssertEqual(snap.selfPivotCallPosts, 2)
        XCTAssertGreaterThanOrEqual(snap.selfPivotCallUsd, 1e-9)
        XCTAssertEqual(snap.selfPivotStop, .budgetCap)
    }

    /// A redirect to a host that isn't an OpenAI API host sends nothing there: one post, a judge error, and
    /// self-pivot stops for the call.
    func testSelfPivotUntrustedRedirectIsOnePostAndAJudgeError() async throws {
        let latch = Latch()
        latch.open()
        let http = DelayedHTTP(latch: latch) { _ in DelayedHTTP.wrongHost("api.openai.com.evil.example") }
        let snap = await runLayer(pivots(1, every: 200), selfPivotJudge: selfPivotJudge(http), until: 30,
                                  settle: { $0.selfPivotFailures >= 1 })
        XCTAssertEqual(http.hosts, ["api.openai.com"])
        XCTAssertEqual(snap.selfPivotCallPosts, 1)
        XCTAssertEqual(snap.selfPivotStop, .judgeError)
    }

    // MARK: the cue judge, same rule

    func cueConfig() throws -> ListenMoreConfig {
        try ListenMoreConfig.load(overrides: ["gpt": ["judge_min_interval_s": 0]])
    }

    func cueRun(_ http: DelayedHTTP, until: Double = 25, during: (TimeInterval) -> Void = { _ in },
                settle: (GptLayer.Snapshot) -> Bool) async throws -> GptLayer.Snapshot {
        let generic = try cueConfig()
        let judge = LiveJudge(config: generic, key: key, http: http, hosts: LearnedHosts())
        return await runLayer(pivots(1, every: 200), config: generic, cueJudge: judge, selfPivotJudge: nil,
                              until: until, during: during, settle: settle)
    }

    func testCueJudgeNormalCallIsOnePostAndCounted() async throws {
        let latch = Latch()
        let http = DelayedHTTP(latch: latch) { _ in DelayedHTTP.ok("none") }
        let snap = try await cueRun(http, during: { t in if t >= 24.9 { latch.open() } }, settle: { $0.judgeLatenciesMs.count >= 1 })
        XCTAssertEqual(http.hosts, ["api.openai.com"])
        XCTAssertEqual(snap.judgeCalls, 1)
        XCTAssertEqual(snap.otherJudgePosts, 1)
    }

    func testCueJudgeIncorrectHostnameIsExactlyTwoCountedPosts() async throws {
        let latch = Latch()
        let http = DelayedHTTP(latch: latch) { n in n == 1 ? DelayedHTTP.wrongHost() : DelayedHTTP.ok("none") }
        let snap = try await cueRun(http, during: { t in if t >= 24.9 { latch.open() } }, settle: { $0.judgeLatenciesMs.count >= 1 })
        XCTAssertEqual(http.hosts, ["api.openai.com", "eu.api.openai.com"])
        XCTAssertEqual(snap.judgeCalls, 1)
        XCTAssertEqual(snap.otherJudgePosts, 2)
        XCTAssertTrue(snap.enabled)
    }

    func testCueJudgeSecondUnauthorizedNeverMakesAThirdPost() async throws {
        let latch = Latch()
        latch.open()
        let http = DelayedHTTP(latch: latch) { _ in DelayedHTTP.wrongHost() }
        let snap = try await cueRun(http, settle: { $0.judgeLatenciesMs.count >= 1 })
        XCTAssertEqual(http.hosts, ["api.openai.com", "eu.api.openai.com"], "never a third")
        XCTAssertEqual(snap.otherJudgePosts, 2)
    }

    /// An untrusted redirect on the cue judge is a judge error that stops cue judging only: the layer, its
    /// transcription and the self-pivot lane go on.
    func testCueJudgeUntrustedRedirectStopsOnlyCueJudging() async throws {
        let latch = Latch()
        latch.open()
        let http = DelayedHTTP(latch: latch) { _ in DelayedHTTP.wrongHost("api.openai.com.evil.example") }
        let snap = try await cueRun(http, settle: { !$0.judgeActive })
        XCTAssertEqual(http.hosts, ["api.openai.com"])
        XCTAssertEqual(snap.otherJudgePosts, 1)
        XCTAssertFalse(snap.judgeActive)
        XCTAssertTrue(snap.enabled, "transcription and captions go on")
        XCTAssertEqual(snap.judgeStopReason, .untrustedHost)
    }

    // MARK: LiveJudge, both specs, with a delayed stub

    /// For each judge: one post for a normal call (and none more while a slow reply is out), exactly two on
    /// the 401 path with both counted, never a third on a second 401, and none when the owner's gate says no.
    func testBothJudgesFollowTheOneRule() async throws {
        for spec in [JudgeSpec.cue, JudgeSpec.selfPivot] {
            let name = spec.name
            func judge(_ http: HTTPTransport) -> LiveJudge {
                LiveJudge(config: config, key: key, http: http, hosts: LearnedHosts(), spec: spec)
            }

            let slowLatch = Latch()
            let slow = DelayedHTTP(latch: slowLatch) { _ in DelayedHTTP.ok("none") }
            let slowPosts = JudgePosts()
            let slowCall = Task { try await judge(slow).judge(prompt: "x", posts: slowPosts) }
            _ = await eventually { slow.hosts.count >= 1 }
            for _ in 0..<20 { await Task.yield() }
            XCTAssertEqual(slow.hosts.count, 1, "\(name): a slow reply is not resent")
            slowLatch.open()
            _ = try await slowCall.value
            XCTAssertEqual(slow.hosts.count, 1, name)
            XCTAssertEqual(slowPosts.sent, 1, name)

            let open = Latch()
            open.open()
            let redirected = DelayedHTTP(latch: open) { n in n == 1 ? DelayedHTTP.wrongHost() : DelayedHTTP.ok("none") }
            let redirectedPosts = JudgePosts()
            _ = try await judge(redirected).judge(prompt: "x", posts: redirectedPosts)
            XCTAssertEqual(redirected.hosts, ["api.openai.com", "eu.api.openai.com"], name)
            XCTAssertEqual(redirectedPosts.sent, 2, "\(name): both posts counted")

            let twice = DelayedHTTP(latch: open) { _ in DelayedHTTP.wrongHost() }
            let twicePosts = JudgePosts()
            do {
                _ = try await judge(twice).judge(prompt: "x", posts: twicePosts)
                XCTFail("\(name): expected an error")
            } catch {
                XCTAssertEqual(error as? GptError, .hostRejected(first: "api.openai.com", regional: "eu.api.openai.com", inner: "HTTP 401"), name)
            }
            XCTAssertEqual(twice.hosts.count, 2, "\(name): a second 401 does not resend again")
            XCTAssertEqual(twicePosts.sent, 2, name)

            let denied = DelayedHTTP(latch: open) { _ in DelayedHTTP.wrongHost() }
            let deniedPosts = JudgePosts(resendGate: { false })
            do {
                _ = try await judge(denied).judge(prompt: "x", posts: deniedPosts)
                XCTFail("\(name): expected an error")
            } catch {
                XCTAssertEqual(error as? GptError, .resendRefused, name)
            }
            XCTAssertEqual(denied.hosts.count, 1, "\(name): the owner's gate stops the resend")
            XCTAssertEqual(deniedPosts.sent, 1, name)

            let sameHost = DelayedHTTP(latch: open) { _ in DelayedHTTP.wrongHost("api.openai.com") }
            do {
                _ = try await judge(sameHost).judge(prompt: "x")
                XCTFail("\(name): expected an error")
            } catch {
                XCTAssertEqual(error as? GptError, .redirectToSameHost, name)
            }
            XCTAssertEqual(sameHost.hosts.count, 1, "\(name): no resend to the host that just answered")
        }
    }

    /// The resend keeps the regional host for the next call, so only that one call paid for it.
    func testTheRegionalHostIsLearnedFromASuccessfulResendOnly() async throws {
        let hosts = LearnedHosts()
        let open = Latch()
        open.open()
        let failing = DelayedHTTP(latch: open) { _ in DelayedHTTP.wrongHost() }
        _ = try? await LiveJudge(config: config, key: key, http: failing, hosts: hosts, spec: .selfPivot).judge(prompt: "x")
        XCTAssertNil(hosts.url(for: config.gpt.responsesUrl, scope: KeyScope(key)), "a failed resend teaches nothing")
        let working = DelayedHTTP(latch: open) { n in n == 1 ? DelayedHTTP.wrongHost() : DelayedHTTP.ok("none") }
        let judge = LiveJudge(config: config, key: key, http: working, hosts: hosts, spec: .selfPivot)
        _ = try await judge.judge(prompt: "x")
        XCTAssertEqual(hosts.url(for: config.gpt.responsesUrl, scope: KeyScope(key)), "https://eu.api.openai.com/v1/responses")
        _ = try await judge.judge(prompt: "y")
        XCTAssertEqual(working.hosts, ["api.openai.com", "eu.api.openai.com", "eu.api.openai.com"])
    }

    // MARK: host validation

    func testOnlyHttpsOpenAIApiHostsAreTrusted() {
        for ok in ["https://api.openai.com/v1/responses", "https://eu.api.openai.com/v1/responses", "https://us.api.openai.com",
                   "HTTPS://EU.API.OPENAI.COM/v1/responses", "https://a-b.api.openai.com/v1/responses", "https://api.openai.com:443/v1/responses"] {
            XCTAssertTrue(OpenAIHost.isTrusted(ok), ok)
        }
        for other in ["https://api.example.com/v1/responses", "https://openai.com/v1/responses", "https://evil.example/api.openai.com",
                      "https://example.com/?h=api.openai.com"] {
            XCTAssertFalse(OpenAIHost.isTrusted(other), "other domain: \(other)")
        }
        for plain in ["http://api.openai.com/v1/responses", "http://eu.api.openai.com/v1/responses", "ftp://api.openai.com/", "api.openai.com/v1"] {
            XCTAssertFalse(OpenAIHost.isTrusted(plain), "not https: \(plain)")
        }
        for lookalike in ["https://api.openai.com.evil.example/v1/responses", "https://evilapi.openai.com/v1/responses",
                          "https://xapi.openai.com", "https://api.openai.com.evil.example", "https://eu.api.openai.com.cn/v1/responses",
                          "https://api.openai.com@evil.example/v1/responses", "https://api.openai.com:8443/v1/responses",
                          "https://.api.openai.com/v1", "https://-.api.openai.com/v1", "https://api.openai.com./v1"] {
            XCTAssertFalse(OpenAIHost.isTrusted(lookalike), "look-alike: \(lookalike)")
        }
        for deeper in ["https://a.b.api.openai.com/v1/responses", "https://a.b.c.api.openai.com", "https://eu.us.api.openai.com/v1/responses"] {
            XCTAssertFalse(OpenAIHost.isTrusted(deeper), "deeper subdomain: \(deeper)")
            XCTAssertFalse(OpenAIHost.isTrustedHost(URL(string: deeper)?.host ?? ""), deeper)
        }
        for odd in ["https://a_b.api.openai.com/v1", "https://api.openai.com%2eevil.example/v1", "https://eu .api.openai.com/v1",
                    "https://API.OPENAI.COM.evil.example/v1", "https://a.api.openai.com.evil.example/",
                    "https://openai.com.api.openai.com.cn/", "https://api.openai.com:0/v1"] {
            XCTAssertFalse(OpenAIHost.isTrusted(odd), "odd host: \(odd)")
        }
        XCTAssertTrue(OpenAIHost.isTrustedHost("eu.api.openai.com"))
        XCTAssertFalse(OpenAIHost.isTrustedHost("a.b.api.openai.com"))
        XCTAssertFalse(OpenAIHost.isTrustedHost("api.openai.com.evil.example"))
    }

    func testLearnedHostsKeepOnlyTrustedHosts() {
        let hosts = LearnedHosts()
        let configured = config.gpt.responsesUrl
        for bad in ["http://eu.api.openai.com/v1/responses", "https://api.openai.com.evil.example/v1/responses", "https://evil.example/v1/responses"] {
            hosts.learn(bad, for: configured, scope: KeyScope(key))
            XCTAssertNil(hosts.url(for: configured, scope: KeyScope(key)), bad)
        }
        hosts.learn("https://eu.api.openai.com/v1/responses", for: configured, scope: KeyScope(key))
        XCTAssertEqual(hosts.url(for: configured, scope: KeyScope(key)), "https://eu.api.openai.com/v1/responses")
    }

    /// What a 401 incorrect_hostname names: a trusted host, a look-alike (untrusted), or no API host at all.
    func testNamedHostIsTrustedUntrustedOrNone() {
        func named(_ message: String, status: Int = 401) -> LiveJudge.NamedHost {
            LiveJudge.namedHost(status: status, body: GptClientTests.hostError(message))
        }
        XCTAssertEqual(named("Use the regional host EU.api.openai.com for this project."), .trusted("eu.api.openai.com"))
        XCTAssertEqual(named("Use api.openai.com."), .trusted("api.openai.com"))
        XCTAssertEqual(named("Use api.openai.com.evil.example instead"), .untrusted)
        XCTAssertEqual(named("Use evilapi.openai.com instead"), .untrusted)
        XCTAssertEqual(named("Use api.example.com"), .none)
        XCTAssertEqual(named("Use the regional host", status: 401), .none)
        XCTAssertEqual(named("Use eu.api.openai.com", status: 403), .none)
        XCTAssertEqual(named("Use a.b.api.openai.com instead"), .untrusted, "a deeper subdomain isn't trusted")
    }

    /// The first trusted host named that differs from the host just used; the host just used is never the target,
    /// and a look-alike beside a trusted host doesn't block it.
    func testNamedHostPicksTheFirstTrustedHostThatDiffers() {
        func named(_ message: String, current: String?) -> LiveJudge.NamedHost {
            LiveJudge.namedHost(status: 401, body: GptClientTests.hostError(message), current: current)
        }
        XCTAssertEqual(named("Use eu.api.openai.com or us.api.openai.com", current: "api.openai.com"), .trusted("eu.api.openai.com"))
        XCTAssertEqual(named("Not api.openai.com, use us.api.openai.com", current: "api.openai.com"), .trusted("us.api.openai.com"))
        XCTAssertEqual(named("Use eu.api.openai.com or us.api.openai.com", current: "eu.api.openai.com"), .trusted("us.api.openai.com"))
        XCTAssertEqual(named("Use api.openai.com.evil.example, or eu.api.openai.com", current: "api.openai.com"), .trusted("eu.api.openai.com"))
        XCTAssertEqual(named("Use eu.api.openai.com", current: "eu.api.openai.com"), .sameHost)
        XCTAssertEqual(named("Use EU.api.openai.com", current: "eu.api.openai.com"), .sameHost)
        XCTAssertEqual(named("Use api.openai.com.evil.example", current: "api.openai.com"), .untrusted)
    }

    /// The one resend goes only to an https OpenAI API host; otherwise it is a judge error with one post.
    func testRejectedRedirectsSendNothing() async throws {
        let open = Latch()
        open.open()
        func attempt(_ message: String, configuredUrl: String? = nil) async -> (posts: Int, error: Error?) {
            var c = config!
            if let configuredUrl { c.gpt.responsesUrl = configuredUrl }
            let http = DelayedHTTP(latch: open) { _ in (401, GptClientTests.hostError(message)) }
            do {
                _ = try await LiveJudge(config: c, key: key, http: http, hosts: LearnedHosts()).judge(prompt: "x")
                return (http.hosts.count, nil)
            } catch {
                return (http.hosts.count, error)
            }
        }
        let accepted = DelayedHTTP(latch: open) { n in n == 1 ? DelayedHTTP.wrongHost("eu.api.openai.com") : DelayedHTTP.ok("none") }
        _ = try await LiveJudge(config: config, key: key, http: accepted, hosts: LearnedHosts()).judge(prompt: "x")
        XCTAssertEqual(accepted.hosts, ["api.openai.com", "eu.api.openai.com"], "accepted")

        let otherDomain = await attempt("Use the host api.openai.com.evil.example")
        XCTAssertEqual(otherDomain.posts, 1, "rejected: look-alike")
        XCTAssertEqual(otherDomain.error as? GptError, .untrustedHost)
        let other = await attempt("Use the host evilapi.openai.com")
        XCTAssertEqual(other.posts, 1, "rejected: other domain")
        XCTAssertEqual(other.error as? GptError, .untrustedHost)
        let http = await attempt("Use the regional host eu.api.openai.com", configuredUrl: "http://api.openai.com/v1/responses")
        XCTAssertEqual(http.posts, 1, "rejected: http")
        XCTAssertEqual(http.error as? GptError, .untrustedHost)
        let port = await attempt("Use the regional host eu.api.openai.com", configuredUrl: "https://api.openai.com:8443/v1/responses")
        XCTAssertEqual(port.posts, 1, "rejected: a port other than 443")
        XCTAssertEqual(port.error as? GptError, .untrustedHost)
        XCTAssertFalse(GptError.isTransient(GptError.untrustedHost))
    }
}
