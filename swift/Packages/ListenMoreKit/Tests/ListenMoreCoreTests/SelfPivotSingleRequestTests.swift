import XCTest
@testable import ListenMoreCore

/// One self-pivot judge request per candidate, never a resend, and every request sent counts against the
/// per-call cap. A slow or late reply must not send anything more (the rule after a paid precision run
/// sent 13 requests for 12 judged cases: the 13th was the judge's own retry on another host).

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

    static let wrongHost = (401, GptClientTests.hostError("Use the regional host eu.api.openai.com for this project."))
}

final class SelfPivotSingleRequestTests: XCTestCase {
    var config: ListenMoreConfig!
    let clock = ManualClock(0)
    let offers = OfferBox()

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
    func runLayer(_ s: PivotScript, config: ListenMoreConfig? = nil, selfPivotJudge: CueJudge, count: Int = 1, until: Double,
                  during: (TimeInterval) -> Void = { _ in }, settle: (GptLayer.Snapshot) -> Bool) async -> GptLayer.Snapshot {
        let clock = clock, offers = offers
        let layer = GptLayer(config: config ?? self.config, now: { clock.now() }, offer: { offers.add($0, $1, $2, $3) },
                             judge: FakeJudge(), selfPivotJudge: selfPivotJudge, selfPivotAllowed: { true },
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

    /// A reply still on its way, past the end of the exchange and many frames later, sends nothing more:
    /// the candidate has exactly one request, in flight, until it answers.
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
        XCTAssertEqual(snap.selfPivotCallJudgeCalls, 1)
    }

    /// A later candidate that arrives while the first reply is still out waits for it: one request in
    /// flight at a time, each candidate sent exactly once, and the cap counts both.
    func testALaterCandidateQueuesBehindASlowReplyAndEachIsSentOnce() async throws {
        var c = config!
        c.text.pivotRearmS = 0
        let latch = Latch()
        let judge = SlowSelfPivotJudge(latch: latch)
        let snap = await runLayer(pivots(2, every: 30), config: c, selfPivotJudge: judge, count: 2, until: 46,
                                  during: { t in if t >= 45.9 { latch.open() } },
                                  settle: { $0.selfPivotJudgeCalls >= 2 && $0.judgeLatenciesMs.count >= 2 })
        XCTAssertEqual(snap.pivotCandidates, 2)
        XCTAssertEqual(judge.calls, 2, "two candidates, two requests")
        XCTAssertEqual(judge.maxInFlight, 1, "never two in flight")
        XCTAssertEqual(snap.selfPivotCallJudgeCalls, 2, "the cap counts each request sent")
    }

    /// The paid run's 13th request: a judge call that gets `401 incorrect_hostname` used to go out a second
    /// time on the regional host. Now the self-pivot judge sends it once, the call counts once, and the
    /// error stops self-pivot for the call (a failed call is not retried).
    func testIncorrectHostnameIsNotResentForASelfPivotCandidate() async throws {
        let latch = Latch()
        let http = DelayedHTTP(latch: latch) { _ in DelayedHTTP.wrongHost }
        let key = try XCTUnwrap(APIKey("sk-test"))
        let judge = LiveJudge(config: config, key: key, http: http, hosts: LearnedHosts(), spec: .selfPivot)
        let snap = await runLayer(pivots(1, every: 200), selfPivotJudge: judge, until: 30,
                                  during: { t in if t >= 29.9 { latch.open() } },
                                  settle: { $0.selfPivotFailures >= 1 })
        XCTAssertEqual(http.hosts, ["api.openai.com"], "one request, to the configured host, no regional retry")
        XCTAssertEqual(snap.selfPivotJudgeCalls, 1)
        XCTAssertEqual(snap.selfPivotCallJudgeCalls, http.hosts.count, "every request sent is a counted call")
        XCTAssertEqual(snap.selfPivotStop, .judgeError)
        XCTAssertTrue(offers.offers.isEmpty)
    }

    /// The 20-call cap counts the requests that go out: with a cap of 2 and four candidates, the wire sees
    /// exactly 2 requests and the ledger says 2.
    func testTheCapCountsEveryRequestSent() async throws {
        var c = config!
        c.text.pivotRearmS = 0
        c.gpt.selfPivotMaxJudgeCallsPerCall = 2
        let latch = Latch()
        latch.open()
        let http = DelayedHTTP(latch: latch) { _ in DelayedHTTP.ok("none") }
        let key = try XCTUnwrap(APIKey("sk-test"))
        let judge = LiveJudge(config: c, key: key, http: http, hosts: LearnedHosts(), spec: .selfPivot)
        let snap = await runLayer(pivots(4, every: 30), config: c, selfPivotJudge: judge, count: 4, until: 125,
                                  settle: { $0.selfPivotJudgeCalls >= 2 && $0.selfPivotCapped >= 2 })
        XCTAssertEqual(snap.pivotCandidates, 4)
        XCTAssertEqual(http.hosts.count, 2)
        XCTAssertEqual(snap.selfPivotCallJudgeCalls, 2)
        XCTAssertEqual(snap.selfPivotCapped, 2)
    }

    // MARK: LiveJudge

    /// The self-pivot judge never resends: not on `401 incorrect_hostname`, not when a learned host rejects
    /// the key. It still learns the regional host the error names (no request), so the next judge starts there.
    func testSelfPivotLiveJudgeSendsOneRequestPerJudgeCall() async throws {
        let key = try XCTUnwrap(APIKey("sk-test"))
        let hosts = LearnedHosts()
        let http = FakeHTTP()
        http.queued = [(401, GptClientTests.hostError("Use the regional host eu.api.openai.com for this project."))]
        let judge = LiveJudge(config: config, key: key, http: http, hosts: hosts, spec: .selfPivot)
        do {
            _ = try await judge.judge(prompt: "x")
            XCTFail("expected the first reply's error")
        } catch {
            XCTAssertEqual(error as? GptError, .http(401))
        }
        XCTAssertEqual(http.requests.map { $0.url.host }, ["api.openai.com"])
        XCTAssertEqual(hosts.url(for: config.gpt.responsesUrl), "https://eu.api.openai.com/v1/responses")

        let next = LiveJudge(config: config, key: key, http: http, hosts: hosts, spec: .selfPivot)
        _ = try await next.judge(prompt: "y")
        XCTAssertEqual(http.requests.map { $0.url.host }, ["api.openai.com", "eu.api.openai.com"], "the next call goes straight to the regional host")

        for status in [401, 403] {
            let learned = LearnedHosts()
            learned.learn("https://eu.api.openai.com/v1/responses", for: config.gpt.responsesUrl)
            let rejecting = FakeHTTP()
            rejecting.queued = [(status, Data())]
            do {
                _ = try await LiveJudge(config: config, key: key, http: rejecting, hosts: learned, spec: .selfPivot).judge(prompt: "x")
                XCTFail("expected an error")
            } catch {
                XCTAssertEqual(error as? GptError, .http(status))
            }
            XCTAssertEqual(rejecting.requests.count, 1, "a rejection from a learned host is not retried on the configured host")
        }
    }

    /// The cue judge keeps its once-per-judge regional fallback (the ruling is about self-pivot candidates).
    func testTheCueJudgeKeepsItsRegionalFallback() async throws {
        let http = FakeHTTP()
        http.queued = [(401, GptClientTests.hostError("Use the regional host eu.api.openai.com for this project."))]
        _ = try await LiveJudge(config: config, key: try XCTUnwrap(APIKey("sk-test")), http: http, hosts: LearnedHosts()).judge(prompt: "x")
        XCTAssertEqual(http.requests.map { $0.url.host }, ["api.openai.com", "eu.api.openai.com"])
    }
}
