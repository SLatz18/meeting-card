import Foundation
import XCTest
@testable import ListenMoreCore

final class GptClientTests: XCTestCase {
    var config: ListenMoreConfig!

    override func setUpWithError() throws {
        config = try TestConfig.load()
    }

    func testJudgeRequestUsesAliasStoreFalseAndStrictSchema() async throws {
        let http = FakeHTTP()
        http.reply = ("aggressive", 0.92)
        let judge = LiveJudge(config: config, key: APIKey("sk-test-judge")!, http: http, hosts: LearnedHosts())
        let (res, usage) = try await judge.judge(prompt: "TRANSCRIPT")
        XCTAssertEqual(res, JudgeResult(cue: "aggressive", confidence: 0.92, shortReason: "test reason"))
        XCTAssertEqual(usage, JudgeUsage(inputTokens: 1000, cachedTokens: 200, outputTokens: 30))
        let req = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(req.url.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(req.headers["Authorization"], "Bearer sk-test-judge")
        XCTAssertEqual(req.timeout, config.gpt.judgeTimeoutS)
        XCTAssertEqual(req.body["model"] as? String, "gpt-6-luna")
        XCTAssertEqual(req.body["store"] as? Bool, false)
        XCTAssertEqual(req.body["max_output_tokens"] as? Int, 200)
        XCTAssertEqual(req.body["input"] as? String, "TRANSCRIPT")
        XCTAssertEqual(req.body["instructions"] as? String, GptJudgeSpec.instructions)
        XCTAssertEqual((req.body["reasoning"] as? [String: Any])?["effort"] as? String, "none")
        let format = (req.body["text"] as? [String: Any])?["format"] as? [String: Any]
        XCTAssertEqual(format?["type"] as? String, "json_schema")
        XCTAssertEqual(format?["strict"] as? Bool, true)
        let props = (format?["schema"] as? [String: Any])?["properties"] as? [String: Any]
        XCTAssertEqual((props?["cue"] as? [String: Any])?["enum"] as? [String], GptJudgeSpec.labels)
    }

    func testJudgeUsesConfiguredAlias() async throws {
        var c = config!
        c.gpt.judgeModel = "gpt-7-terra"
        c.gpt.judgeReasoningEffort = nil
        let http = FakeHTTP()
        _ = try await LiveJudge(config: c, key: APIKey("k")!, http: http, hosts: LearnedHosts()).judge(prompt: "x")
        XCTAssertEqual(http.requests.first?.body["model"] as? String, "gpt-7-terra")
        XCTAssertNil(http.requests.first?.body["reasoning"])
    }

    func testJudgeHttpErrorCarriesStatusOnly() async {
        let http = FakeHTTP()
        http.status = 401
        do {
            _ = try await LiveJudge(config: config, key: APIKey("sk-secret-value")!, http: http, hosts: LearnedHosts()).judge(prompt: "x")
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(GptError.safe(error), "HTTP 401")
            XCTAssertFalse(String(describing: error).contains("sk-secret-value"))
        }
    }

    func testIncorrectHostnameRetriesOnceOnTheRegionalHostAndKeepsIt() async throws {
        let http = FakeHTTP()
        http.queued = [(401, Self.hostError("Use the regional host EU.api.openai.com for this project."))]
        let judge = LiveJudge(config: config, key: APIKey("sk-test-host")!, http: http, hosts: LearnedHosts())
        _ = try await judge.judge(prompt: "x")
        XCTAssertEqual(http.requests.map { $0.url.host }, ["api.openai.com", "eu.api.openai.com"])
        XCTAssertEqual(judge.currentURL, "https://eu.api.openai.com/v1/responses")
        _ = try await judge.judge(prompt: "y")
        XCTAssertEqual(http.requests.last?.url.host, "eu.api.openai.com")
        XCTAssertEqual(http.requests.count, 3)
    }

    func testIncorrectHostnameFailingTwiceNamesBothHostsOnly() async {
        let http = FakeHTTP()
        http.queued = [(401, Self.hostError("use eu.api.openai.com")), (401, Data())]
        do {
            _ = try await LiveJudge(config: config, key: APIKey("sk-secret-value")!, http: http, hosts: LearnedHosts()).judge(prompt: "x")
            XCTFail("expected error")
        } catch {
            XCTAssertEqual(error as? GptError, .hostRejected(first: "api.openai.com", regional: "eu.api.openai.com", inner: "HTTP 401"))
            XCTAssertFalse(GptError.safe(error).contains("sk-secret-value"))
            XCTAssertFalse(GptError.isTransient(error))
        }
    }

    func testIncorrectHostnameIgnoresNonOpenAIHostsAndOtherCodes() async {
        for body in [Self.hostError("use api.example.com"), Data(#"{"error":{"code":"invalid_api_key","message":"eu.api.openai.com"}}"#.utf8)] {
            let http = FakeHTTP()
            http.queued = [(401, body)]
            do {
                _ = try await LiveJudge(config: config, key: APIKey("k")!, http: http, hosts: LearnedHosts()).judge(prompt: "x")
                XCTFail("expected error")
            } catch {
                XCTAssertEqual(error as? GptError, .http(401))
                XCTAssertEqual(http.requests.count, 1)
            }
        }
    }

    /// Each engine start builds a new judge: the next one starts on the regional host the first learned,
    /// so only the first call after launch pays for the fallback.
    func testNextJudgeStartsOnTheLearnedRegionalHost() async throws {
        let hosts = LearnedHosts()
        let http = FakeHTTP()
        http.queued = [(401, Self.hostError("Use the regional host eu.api.openai.com for this project."))]
        _ = try await LiveJudge(config: config, key: APIKey("sk-test-host")!, http: http, hosts: hosts).judge(prompt: "x")
        XCTAssertEqual(hosts.url(for: config.gpt.responsesUrl), "https://eu.api.openai.com/v1/responses")
        let next = LiveJudge(config: config, key: APIKey("sk-test-host")!, http: http, hosts: hosts)
        XCTAssertEqual(next.currentURL, "https://eu.api.openai.com/v1/responses")
        _ = try await next.judge(prompt: "y")
        XCTAssertEqual(http.requests.map { $0.url.host }, ["api.openai.com", "eu.api.openai.com", "eu.api.openai.com"],
                       "one failed call in all, not one per judge")
    }

    /// A learned host that stops working (another key) answers 401 incorrect_hostname naming the key's host:
    /// the one resend goes there (the configured host), and the learned host is forgotten.
    func testStaleLearnedHostIsRedirectedToTheConfiguredHost() async throws {
        let hosts = LearnedHosts()
        hosts.learn("https://eu.api.openai.com/v1/responses", for: config.gpt.responsesUrl)
        let http = FakeHTTP()
        http.queued = [(401, Self.hostError("Use the regional host api.openai.com for this project."))]
        let judge = LiveJudge(config: config, key: APIKey("sk-other")!, http: http, hosts: hosts)
        _ = try await judge.judge(prompt: "x")
        XCTAssertEqual(http.requests.map { $0.url.host }, ["eu.api.openai.com", "api.openai.com"])
        XCTAssertEqual(judge.currentURL, config.gpt.responsesUrl)
        XCTAssertNil(hosts.url(for: config.gpt.responsesUrl))
    }

    /// Only 401 incorrect_hostname resends. Any other reply from a learned host (a rejected key, a rate limit,
    /// an outage) is one post and its own error, and the host is kept.
    func testOnlyIncorrectHostnameResends() async {
        let learned = "https://eu.api.openai.com/v1/responses"
        for (status, body) in [(401, Data(#"{"error":{"code":"invalid_api_key","message":"x"}}"#.utf8)), (403, Data()), (429, Data()), (500, Data())] {
            let hosts = LearnedHosts()
            hosts.learn(learned, for: config.gpt.responsesUrl)
            let http = FakeHTTP()
            http.queued = [(status, body)]
            do {
                _ = try await LiveJudge(config: config, key: APIKey("k")!, http: http, hosts: hosts).judge(prompt: "x")
                XCTFail("expected error")
            } catch {
                XCTAssertEqual(error as? GptError, .http(status))
                XCTAssertEqual(http.requests.count, 1, "HTTP \(status)")
                XCTAssertEqual(hosts.url(for: config.gpt.responsesUrl), learned)
            }
        }
    }

    static func hostError(_ message: String) -> Data {
        try! JSONSerialization.data(withJSONObject: ["error": ["code": "incorrect_hostname", "message": message]])
    }

    func testParseRejectsMalformedReplies() {
        XCTAssertThrowsError(try LiveJudge.parse(Data("{}".utf8)))
        XCTAssertThrowsError(try LiveJudge.parse(Data("not json".utf8)))
    }

    func testSafeErrorNeverIncludesMessageText() {
        struct Leaky: Error, CustomStringConvertible { var description: String { "Bearer sk-leak" } }
        XCTAssertEqual(GptError.safe(Leaky()), "Leaky")
        XCTAssertEqual(GptError.safe(URLError(.timedOut)), "URLError -1001")
    }

    func testTranscriberSessionUpdateAndMessages() async throws {
        let connector = FakeConnector()
        let events = EventBox()
        let tx = LiveTranscriber(config: config, key: APIKey("sk-test-rt")!, speaker: .others, connector: connector) { events.append($0) }
        try await tx.start()
        let conn = try XCTUnwrap(connector.connections.first)
        XCTAssertEqual(conn.url.absoluteString, "wss://api.openai.com/v1/realtime?intent=transcription")
        XCTAssertEqual(conn.headers["Authorization"], "Bearer sk-test-rt")
        let update = try XCTUnwrap(conn.socket.sent.first.flatMap { try JSONSerialization.jsonObject(with: Data($0.utf8)) as? [String: Any] })
        XCTAssertEqual(update["type"] as? String, "session.update")
        let session = update["session"] as? [String: Any]
        XCTAssertEqual(session?["type"] as? String, "transcription")
        let input = (session?["audio"] as? [String: Any])?["input"] as? [String: Any]
        XCTAssertEqual((input?["format"] as? [String: Any])?["rate"] as? Int, 24000)
        XCTAssertEqual((input?["transcription"] as? [String: Any])?["model"] as? String, "gpt-live-transcribe")
        XCTAssertTrue(input?["turn_detection"] is NSNull)

        try await tx.sendAudio(Data([1, 2, 3, 4]))
        try await tx.commit(refT: 4.2)
        XCTAssertTrue(conn.socket.sent[1].contains("input_audio_buffer.append"))
        XCTAssertTrue(conn.socket.sent[1].contains(Data([1, 2, 3, 4]).base64EncodedString()))
        XCTAssertTrue(conn.socket.sent[2].contains("input_audio_buffer.commit"))

        conn.socket.push(#"{"type":"input_audio_buffer.committed","item_id":"i1"}"#)
        conn.socket.push(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"i1","transcript":"can you send it?","usage":{"type":"duration","seconds":2.5}}"#)
        let gotText = await eventually { events.texts.count == 1 }
        XCTAssertTrue(gotText)
        XCTAssertEqual(events.texts.first?.0, .others)
        XCTAssertEqual(events.texts.first?.1, "can you send it?")
        XCTAssertEqual(events.texts.first?.2, 4.2)
        XCTAssertEqual(events.usage.first?.0, .others)
        XCTAssertEqual(events.usage.first?.1, 2.5)

        conn.socket.push(#"{"type":"error","error":{"type":"invalid_request_error","code":"bad_key"}}"#)
        let gotError = await eventually { !events.errors.isEmpty }
        XCTAssertTrue(gotError)
        XCTAssertEqual(events.errors.first, "realtime error invalid_request_error/bad_key")
        await tx.close()
        do {
            try await tx.sendAudio(Data([0]))
            XCTFail("closed transcriber must not send")
        } catch {
            XCTAssertEqual(error as? GptError, .notConnected)
        }
    }

    func testBilledMeterRoundsEachSegmentUpAndPrefersApiSeconds() {
        var c = CostTracker(prices: config.gpt.pricesUsd, budget: nil)
        c.addAudio(seconds: 0.5, speaker: .me)
        c.commit(speaker: .me)
        XCTAssertEqual(c.estimatedUnreportedS, 1)
        c.addAudio(seconds: 2.2, speaker: .others)
        XCTAssertEqual(c.billedAudioS, 4)
        c.addApiAudio(seconds: 0.6, speaker: .me)
        XCTAssertEqual(c.billedAudioS, 3.6, accuracy: 1e-12)
        c.commit(speaker: .others)
        XCTAssertEqual(c.segments, 2)
        XCTAssertEqual(c.audioS, 2.7, accuracy: 1e-12)
        XCTAssertEqual(c.transcribeUsd, 3.6 / 60 * 0.017, accuracy: 1e-12)
    }

    func testCostTrackerBudgetAndTranscript() {
        var c = CostTracker(prices: config.gpt.pricesUsd, budget: 0.05)
        c.addAudio(seconds: 60, speaker: .me)
        XCTAssertEqual(c.transcribeUsd, 0.017, accuracy: 1e-12)
        XCTAssertFalse(c.exhausted)
        c.addAudio(seconds: 180, speaker: .me)
        XCTAssertTrue(c.exhausted)
        c.addJudge(JudgeUsage(inputTokens: 1_000_000, cachedTokens: 0, outputTokens: 0))
        XCTAssertEqual(c.judgeUsd, 0.10, accuracy: 1e-12)

        var r = RollingTranscript(windowS: 90)
        r.add(t: 0, speaker: .others, text: "hello")
        r.add(t: 50, speaker: .me, text: "hi")
        r.add(t: 100, speaker: .others, text: "  still there?  ")
        r.add(t: 100, speaker: .me, text: "   ")
        XCTAssertEqual(r.render(now: 100), "[-50.0s] ME: hi\n[- 0.0s] OTHERS: still there?")
    }
}

final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _texts: [(Speaker, String, TimeInterval)] = []
    private var _errors: [String] = []
    private var _usage: [(Speaker, Double)] = []
    private var _deltas: [(Speaker, String, String)] = []
    private var _clearRejections: [Speaker] = []

    var clearRejections: [Speaker] { lock.withLock { _clearRejections } }
    var texts: [(Speaker, String, TimeInterval)] { lock.withLock { _texts } }
    var deltas: [(Speaker, String, String)] { lock.withLock { _deltas } }
    var errors: [String] { lock.withLock { _errors } }
    var usage: [(Speaker, Double)] { lock.withLock { _usage } }

    func append(_ e: TranscriptEvent) {
        lock.withLock {
            switch e {
            case let .text(s, t, ref): _texts.append((s, t, ref))
            case let .delta(s, t, item): _deltas.append((s, t, item))
            case let .usage(s, sec): _usage.append((s, sec))
            case let .clearRejected(s): _clearRejections.append(s)
            case let .error(m): _errors.append(m)
            }
        }
    }
}

final class OfferBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _offers: [(label: String, t: TimeInterval, refT: TimeInterval, confidence: Double)] = []
    var offers: [(label: String, t: TimeInterval, refT: TimeInterval, confidence: Double)] { lock.withLock { _offers } }

    func add(_ label: String, _ t: TimeInterval, _ refT: TimeInterval, _ c: Double) {
        lock.withLock { _offers.append((label, t, refT, c)) }
    }
}

/// Voiced/silent frames and VAD states for driving the GPT layer by hand.
enum GptFrames {
    static let voiced = [Float](repeating: 0.1, count: 480)
    static let silent = [Float](repeating: 0, count: 480)

    static func vad(raw: Bool, onset: TimeInterval? = nil, offset: TimeInterval? = nil) -> VadState {
        VadState(raw: raw, active: raw, onset: onset, offset: offset, dbfs: raw ? -20 : -90)
    }

    static let quiet = vad(raw: false)
}

final class GptCoreTests: XCTestCase {
    var config: ListenMoreConfig!
    let v = GptFrames.voiced, z = GptFrames.silent
    let frameS = 0.02

    override func setUpWithError() throws {
        config = try TestConfig.load()
    }

    func sent(_ actions: [GptCore.TxAction]) -> Int {
        actions.reduce(0) { n, a in
            if case let .send(_, s) = a { return n + s.count }
            return n
        }
    }

    func commits(_ actions: [GptCore.TxAction]) -> [TimeInterval] {
        actions.compactMap { if case let .commit(_, ref) = $0 { return ref } else { return nil } }
    }

    func testSendsOnlyVoicedAudioWithPreroll() {
        let core = GptCore(config: config)
        var actions: [GptCore.TxAction] = []
        for i in 0..<10 { actions += core.feed(.me, frame: v, vad: GptFrames.quiet, now: Double(i) * frameS) }
        XCTAssertEqual(sent(actions), 0)
        actions = core.feed(.me, frame: v, vad: GptFrames.vad(raw: true, onset: 0.2), now: 0.22)
        XCTAssertEqual(sent(actions), 3600 + 480, "150 ms pre-roll + the onset frame")
        actions = []
        for i in 0..<3 { actions += core.feed(.me, frame: z, vad: GptFrames.vad(raw: false), now: 0.24 + Double(i) * frameS) }
        XCTAssertEqual(sent(actions), 0, "a pause inside the utterance is held")
        actions = core.feed(.me, frame: v, vad: GptFrames.vad(raw: true), now: 0.30)
        XCTAssertEqual(sent(actions), 4 * 480, "speech resumed: the held pause goes out with it")
        actions = []
        for i in 0..<4 { actions += core.feed(.me, frame: z, vad: GptFrames.vad(raw: false), now: 0.32 + Double(i) * frameS) }
        actions += core.feed(.me, frame: z, vad: GptFrames.vad(raw: false, offset: 0.30), now: 0.40)
        XCTAssertEqual(sent(actions), 0, "the VAD hangover never goes out")
        XCTAssertEqual(commits(actions), [0.30])
        XCTAssertEqual(core.cost.audioS, Double(3600 + 5 * 480) / 24000, accuracy: 1e-9)
    }

    func testCommitGapSharesOneCommitAcrossCloseUtterances() {
        config.gpt.transcribeCommitGapMs = 300
        let core = GptCore(config: config)
        _ = core.feed(.others, frame: v, vad: GptFrames.vad(raw: true, onset: 0.5), now: 0.52)
        XCTAssertEqual(commits(core.feed(.others, frame: z, vad: GptFrames.vad(raw: false, offset: 1.0), now: 1.0)), [])
        XCTAssertEqual(commits(core.feed(.others, frame: z, vad: GptFrames.quiet, now: 1.1)), [])
        _ = core.feed(.others, frame: v, vad: GptFrames.vad(raw: true, onset: 1.2), now: 1.2)
        XCTAssertEqual(commits(core.feed(.others, frame: z, vad: GptFrames.quiet, now: 1.3)), [], "speech resumed inside the gap")
        XCTAssertEqual(commits(core.feed(.others, frame: z, vad: GptFrames.vad(raw: false, offset: 2.0), now: 2.0)), [])
        XCTAssertEqual(commits(core.feed(.others, frame: z, vad: GptFrames.quiet, now: 2.28)), [])
        XCTAssertEqual(commits(core.feed(.others, frame: z, vad: GptFrames.quiet, now: 2.30)), [2.0])
        XCTAssertEqual(core.cost.segments, 1)
    }

    func testLongSegmentCommitsAtItsNextPause() {
        config.gpt.transcribeCommitGapMs = 300
        config.gpt.transcribeMaxSegmentS = 1
        let core = GptCore(config: config)
        _ = core.feed(.me, frame: v, vad: GptFrames.vad(raw: true, onset: 0), now: 0.02)
        for i in 2...60 { _ = core.feed(.me, frame: v, vad: GptFrames.vad(raw: true), now: Double(i) * frameS) }
        XCTAssertEqual(commits(core.feed(.me, frame: z, vad: GptFrames.vad(raw: false, offset: 1.2), now: 1.22)), [1.2])
    }

    func testBudgetCapStopsCleanly() {
        config.gpt.budgetUsdPerCall = 0.0001
        let core = GptCore(config: config)
        XCTAssertGreaterThan(sent(core.feed(.me, frame: v, vad: GptFrames.vad(raw: true, onset: 0), now: 0.02)), 0)
        XCTAssertTrue(core.cost.exhausted, "one open second is billed as a whole second")
        XCTAssertEqual(core.feed(.me, frame: v, vad: GptFrames.vad(raw: true), now: 0.04), [])
        XCTAssertFalse(core.enabled)
        XCTAssertEqual(core.stopReason, .budgetCap)
        XCTAssertTrue(core.closeTranscribersRequested)
        XCTAssertEqual(core.errors, ["budget cap reached"])
        XCTAssertEqual(core.feed(.others, frame: v, vad: GptFrames.vad(raw: true, onset: 0), now: 0.06), [])
        XCTAssertNil(core.request(GptCore.JudgeRequest(refT: 0, reason: "me_reply")))
    }

    func testBudgetCapCheckedBeforeAJudgeCall() {
        config.gpt.budgetUsdPerCall = 0.0001
        let core = GptCore(config: config)
        let req = GptCore.JudgeRequest(refT: 1, reason: "me_reply")
        XCTAssertEqual(core.request(req), req)
        core.addApiAudio(seconds: 1, speaker: .me)
        XCTAssertNil(core.beginJudge(req, now: 2))
        XCTAssertEqual(core.stopReason, .budgetCap)
    }

    func testJudgesOnlyMyFirstLineAfterASubstantiveOtherTurn() {
        let core = GptCore(config: config)
        XCTAssertNil(core.onText(.others, text: "sure okay", refT: 1, now: 1.5).start)
        XCTAssertNil(core.onText(.me, text: "so the plan is", refT: 2, now: 2.5).start, "short acknowledgements don't count")
        XCTAssertNil(core.onText(.others, text: "how would that work in practice", refT: 3, now: 3.5).start)
        let r = core.onText(.me, text: "it depends", refT: 4, now: 4.5)
        XCTAssertEqual(r.start, GptCore.JudgeRequest(refT: 4, reason: "me_reply"))
        XCTAssertEqual(r.refT, 4)
        _ = core.judgeEnded()
        XCTAssertNil(core.onText(.me, text: "and another thing", refT: 5, now: 5.5).start, "only the first line of the reply")
        XCTAssertEqual(core.onText(.others, text: "x", refT: -1, now: 6).refT, 6, "a missing reference time falls back to arrival")
    }

    /// With not_listening disabled (MeetingCard's default) nothing is judged: the judge decides only
    /// not_listening, so a call would cost money for verdicts that never show.
    func testNoJudgeWhileNotListeningIsDisabled() throws {
        let core = GptCore(config: try ListenMoreConfig.load(overrides: ["cues": ["disabled": ["not_listening"]]]))
        XCTAssertNil(core.onText(.others, text: "how would that work in practice", refT: 3, now: 3.5).start)
        XCTAssertNil(core.onText(.me, text: "it depends", refT: 4, now: 4.5).start)
        XCTAssertEqual(core.snapshot.judgeCalls, 0)
    }

    /// A TypeSafe judge also decides aggressive and missed_question, so it still judges with not_listening
    /// off; it stops only when every cue it decides is off.
    func testTypeSafeStillJudgesWithNotListeningDisabled() throws {
        let some = GptCore(config: try ListenMoreConfig.load(overrides: ["cues": ["disabled": ["not_listening"]],
                                                                          "judge": ["provider": "typesafe"]]))
        XCTAssertNil(some.onText(.others, text: "how would that work in practice", refT: 3, now: 3.5).start)
        XCTAssertEqual(some.onText(.me, text: "it depends", refT: 4, now: 4.5).start, GptCore.JudgeRequest(refT: 4, reason: "me_reply"))
        let all = GptCore(config: try ListenMoreConfig.load(overrides: ["cues": ["disabled": ["not_listening", "aggressive", "missed_question"]],
                                                                         "judge": ["provider": "typesafe"]]))
        XCTAssertNil(all.onText(.others, text: "how would that work in practice", refT: 3, now: 3.5).start)
        XCTAssertNil(all.onText(.me, text: "it depends", refT: 4, now: 4.5).start)
        XCTAssertEqual(CueType.decided(by: .gpt), [.notListening])
        XCTAssertEqual(CueType.decided(by: .typesafe), Set(CueType.judged))
    }

    func testNoJudgeMidMonologue() {
        let core = GptCore(config: config)
        core.setMeRun(config.gpt.judgeSkipRunS)
        _ = core.onText(.others, text: "could you say more about that", refT: 1, now: 1)
        XCTAssertNil(core.onText(.me, text: "right so", refT: 2, now: 2).start)
    }

    func testNotListeningNeedsHighConfidenceAndNeverDuringAMonologue() {
        let core = GptCore(config: config)
        let req = GptCore.JudgeRequest(refT: 3, reason: "me_reply")
        let usage = JudgeUsage(inputTokens: 10, cachedTokens: 0, outputTokens: 2)
        XCTAssertNil(core.finishJudge(req, result: .success((JudgeResult(cue: "not_listening", confidence: 0.84, shortReason: ""), usage)), now: 4))
        XCTAssertEqual(core.droppedVerdicts, 1)
        let offer = core.finishJudge(req, result: .success((JudgeResult(cue: "not_listening", confidence: 0.85, shortReason: ""), usage)), now: 4)
        XCTAssertEqual(offer, GptCore.Offer(label: "not_listening", t: 4, refT: 3, confidence: 0.85))
        XCTAssertNil(core.finishJudge(req, result: .success((JudgeResult(cue: "none", confidence: 0.99, shortReason: ""), usage)), now: 4))
        core.setMeRun(config.gpt.judgeSkipRunS + 1)
        XCTAssertNil(core.finishJudge(req, result: .success((JudgeResult(cue: "not_listening", confidence: 0.99, shortReason: ""), usage)), now: 4))
        XCTAssertEqual(core.droppedVerdicts, 2)
        XCTAssertEqual(core.cost.judgeCalls, 4)
    }

    func testTransientJudgeErrorsSkipUntilTheLimit() {
        let core = GptCore(config: config)
        let req = GptCore.JudgeRequest(refT: 1, reason: "me_reply")
        XCTAssertNil(core.finishJudge(req, result: .failure(GptError.http(429)), now: 2))
        XCTAssertNil(core.finishJudge(req, result: .failure(URLError(.timedOut)), now: 3))
        XCTAssertTrue(core.enabled)
        XCTAssertEqual(core.transientErrors, 2)
        _ = core.finishJudge(req, result: .failure(GptError.http(503)), now: 4)
        XCTAssertFalse(core.enabled)
        XCTAssertEqual(core.stopReason, .error)
    }

    func testHardJudgeErrorStopsAtOnce() {
        let core = GptCore(config: config)
        _ = core.finishJudge(GptCore.JudgeRequest(refT: 1, reason: "me_reply"), result: .failure(GptError.http(401)), now: 2)
        XCTAssertFalse(core.enabled)
        XCTAssertEqual(core.errors, ["judge: HTTP 401"])
    }

    func testOneJudgeInFlightKeepsOnlyTheLatestQueued() {
        let core = GptCore(config: config)
        let a = GptCore.JudgeRequest(refT: 1, reason: "me_reply")
        let b = GptCore.JudgeRequest(refT: 2, reason: "me_reply")
        let c = GptCore.JudgeRequest(refT: 3, reason: "me_reply")
        XCTAssertEqual(core.request(a), a)
        XCTAssertNil(core.request(b))
        XCTAssertNil(core.request(c))
        XCTAssertEqual(core.judgeEnded(), c)
        XCTAssertNil(core.judgeEnded())
    }

    func testPromptCarriesTranscriptFlagsAndTrigger() {
        let core = GptCore(config: config)
        core.onLocal(LocalEvent(kind: .prosody, t: 9, onset: 9,
                                prosody: ProsodyReading(t: 9, baselineReady: true, flagged: true, loudnessJumpDb: 6.2, rateJumpPct: 3.0)))
        core.onLocal(LocalEvent(kind: .interrupt, t: 8, onset: 7.5))
        _ = core.onText(.others, text: "what do you think about the option", refT: 8, now: 8)
        _ = core.onText(.me, text: "anyway the other thing", refT: 9, now: 9.5)
        let prompt = core.buildPrompt(GptCore.JudgeRequest(refT: 9, reason: "me_reply"), now: 10)
        XCTAssertTrue(prompt.contains("OTHERS: what do you think about the option"))
        XCTAssertTrue(prompt.contains("ME: anyway the other thing"))
        XCTAssertTrue(prompt.contains("prosody_enabled=yes prosody_flagged=yes loudness_jump_db=6.2 rate_jump_pct=3.0"))
        XCTAssertTrue(prompt.contains("recent_overlaps=interrupt@-2.5s"))
        XCTAssertTrue(prompt.hasSuffix("TRIGGER: me_reply"))
        core.clearTranscript()
        XCTAssertFalse(core.buildPrompt(GptCore.JudgeRequest(refT: 9, reason: "me_reply"), now: 10).contains("anyway"))
    }
}

final class StopBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _reasons: [GptStopReason] = []
    var reasons: [GptStopReason] { lock.withLock { _reasons } }
    func add(_ r: GptStopReason) { lock.withLock { _reasons.append(r) } }
}

final class SegmentBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _segments: [(Speaker, String, TimeInterval)] = []
    var segments: [(Speaker, String, TimeInterval)] { lock.withLock { _segments } }
    func add(_ s: Speaker, _ t: String, _ r: TimeInterval) { lock.withLock { _segments.append((s, t, r)) } }
}

final class GptLayerTests: XCTestCase {
    var config: ListenMoreConfig!
    let clock = ManualClock(0)
    let offers = OfferBox()
    let stops = StopBox()
    let segments = SegmentBox()
    var transcribers: [Speaker: FakeTranscriber] = [:]
    let v = GptFrames.voiced, z = GptFrames.silent

    override func setUpWithError() throws {
        config = try TestConfig.load()
        config.gpt.judgeMinIntervalS = 0
    }

    func makeLayer(me: [String] = [], others: [String] = [], billed: Double? = nil, judge: FakeJudge,
                   scheduler: InstantScheduler = InstantScheduler()) -> GptLayer {
        let clock = clock, offers = offers, stops = stops, segments = segments
        var made: [Speaker: FakeTranscriber] = [:]
        let layer = GptLayer(config: config, now: { clock.now() }, offer: { offers.add($0, $1, $2, $3) },
                             onSegment: { s, t, r, _ in segments.add(s, t, r) }, onStopped: { stops.add($0) },
                             judge: judge, scheduler: scheduler) { speaker, onEvent in
            let t = FakeTranscriber(speaker: speaker, script: speaker == .me ? me : others, onEvent: onEvent)
            t.billedPerCommit = billed
            made[speaker] = t
            return t
        }
        transcribers = made
        layer.start()
        return layer
    }

    func utterance(_ layer: GptLayer, _ speaker: Speaker, onset: TimeInterval, offset: TimeInterval) {
        let on = GptFrames.vad(raw: true, onset: onset), off = GptFrames.vad(raw: false, offset: offset)
        if speaker == .me {
            layer.feed(me: v, meVad: on, others: z, othersVad: GptFrames.quiet, meRunS: 0)
            layer.feed(me: z, meVad: off, others: z, othersVad: GptFrames.quiet, meRunS: 0)
        } else {
            layer.feed(me: z, meVad: GptFrames.quiet, others: v, othersVad: on, meRunS: 0)
            layer.feed(me: z, meVad: GptFrames.quiet, others: z, othersVad: off, meRunS: 0)
        }
    }

    func testMyReplyAfterTheirTurnIsJudgedAndSegmentsReachTheTextRules() async {
        clock.set(12)
        let judge = FakeJudge(answers: [JudgeResult(cue: "not_listening", confidence: 0.9, shortReason: "changed topic")])
        let layer = makeLayer(me: ["Anyway, about the other thing."], others: ["How would we roll this out?"], judge: judge)
        utterance(layer, .others, onset: 9, offset: 10)
        utterance(layer, .me, onset: 11, offset: 11.5)
        let offered = await eventually { self.offers.offers.count == 1 }
        XCTAssertTrue(offered)
        XCTAssertEqual(offers.offers.first?.label, "not_listening")
        XCTAssertEqual(offers.offers.first?.refT, 11.5)
        XCTAssertTrue(judge.prompts[0].contains("OTHERS: How would we roll this out?"))
        XCTAssertTrue(judge.prompts[0].contains("ME: Anyway, about the other thing."))
        XCTAssertTrue(judge.prompts[0].contains("TRIGGER: me_reply"))
        XCTAssertEqual(segments.segments.map { $0.0 }, [.others, .me])
        XCTAssertEqual(segments.segments.map { $0.2 }, [10, 11.5])
        await layer.close()
        XCTAssertTrue(transcribers[.me]!.closed)
        XCTAssertTrue(transcribers[.others]!.closed)
    }

    func testOnlyVoicedFramesAreSent() async {
        let layer = makeLayer(judge: FakeJudge())
        for _ in 0..<5 { layer.feed(me: v, meVad: GptFrames.quiet, others: z, othersVad: GptFrames.quiet, meRunS: 0) }
        utterance(layer, .others, onset: 1, offset: 1.2)
        _ = await layer.snapshot()
        XCTAssertEqual(transcribers[.me]!.bytesSent, 0)
        XCTAssertEqual(transcribers[.others]!.bytesSent, (5 * 480 + 480) * 2, "pre-roll + the onset frame; the silent offset frame is held")
        XCTAssertEqual(transcribers[.others]!.commits, [1.2])
        await layer.close()
    }

    func testApiReportedSecondsFeedTheMeter() async {
        let layer = makeLayer(billed: 1.5, judge: FakeJudge())
        utterance(layer, .me, onset: 1, offset: 2)
        utterance(layer, .others, onset: 3, offset: 4)
        let billed = await eventually { await layer.snapshot().billedAudioSeconds == 3.0 }
        XCTAssertTrue(billed)
        await layer.close()
    }

    func testBudgetCapClosesTranscribersAndReportsOnce() async {
        config.gpt.budgetUsdPerCall = 0.0001
        let layer = makeLayer(judge: FakeJudge())
        utterance(layer, .me, onset: 1, offset: 2)
        for _ in 0..<5 { layer.feed(me: v, meVad: GptFrames.vad(raw: true, onset: 3), others: z, othersVad: GptFrames.quiet, meRunS: 0) }
        let snap = await layer.snapshot()
        XCTAssertFalse(snap.enabled)
        XCTAssertTrue(snap.budgetExhausted)
        XCTAssertEqual(snap.errors, ["budget cap reached"])
        XCTAssertTrue(transcribers[.me]!.closed)
        XCTAssertTrue(transcribers[.others]!.closed)
        XCTAssertEqual(stops.reasons, [.budgetCap])
        await layer.close()
    }

    func testJudgeErrorStopsWithStatusOnly() async {
        let judge = FakeJudge()
        judge.fail = true
        let layer = makeLayer(me: ["anything at all"], others: ["what do you all think here"], judge: judge)
        utterance(layer, .others, onset: 1, offset: 2)
        utterance(layer, .me, onset: 3, offset: 4)
        let stopped = await eventually { await !layer.snapshot().enabled }
        XCTAssertTrue(stopped)
        let snap = await layer.snapshot()
        XCTAssertEqual(snap.errors, ["judge: HTTP 401"])
        XCTAssertEqual(stops.reasons, [.error])
        await layer.close()
    }

    func testTransientJudgeErrorSkipsOneVerdict() async {
        let judge = FakeJudge()
        judge.errors = [URLError(.timedOut)]
        let layer = makeLayer(me: ["one", "two"], others: ["what do you all think here", "and what about the rest"], judge: judge)
        utterance(layer, .others, onset: 1, offset: 2)
        utterance(layer, .me, onset: 3, offset: 4)
        _ = await eventually { await layer.snapshot().transientErrors == 1 }
        utterance(layer, .others, onset: 5, offset: 6)
        utterance(layer, .me, onset: 7, offset: 8)
        let judged = await eventually { judge.prompts.count == 1 }
        XCTAssertTrue(judged)
        let snap = await layer.snapshot()
        XCTAssertTrue(snap.enabled)
        XCTAssertEqual(snap.transientErrors, 1)
        await layer.close()
    }

    func testSendFailureStops() async {
        let layer = makeLayer(judge: FakeJudge())
        transcribers[.others]!.failSend = true
        layer.feed(me: z, meVad: GptFrames.quiet, others: v, othersVad: GptFrames.vad(raw: true, onset: 1), meRunS: 0)
        let snap = await layer.snapshot()
        XCTAssertEqual(snap.errors, ["realtime send: URLError -1005"])
        await layer.close()
    }

    func testMinIntervalSleepsBeforeTheNextJudge() async {
        config.gpt.judgeMinIntervalS = 1.5
        let scheduler = InstantScheduler()
        let judge = FakeJudge()
        let layer = makeLayer(me: ["one", "two"], others: ["what do you all think here", "and what about the rest"],
                              judge: judge, scheduler: scheduler)
        utterance(layer, .others, onset: 1, offset: 2)
        utterance(layer, .me, onset: 3, offset: 4)
        _ = await eventually { judge.prompts.count == 1 }
        utterance(layer, .others, onset: 5, offset: 6)
        utterance(layer, .me, onset: 7, offset: 8)
        let second = await eventually { judge.prompts.count == 2 }
        XCTAssertTrue(second)
        XCTAssertTrue(scheduler.sleeps.contains { abs($0 - 1.5) < 1e-9 })
        await layer.close()
    }

    func testProductionInitUsesTransports() async throws {
        let http = FakeHTTP(), connector = FakeConnector()
        let layer = GptLayer(config: config, key: APIKey("sk-test-prod")!,
                             transports: GptTransports(http: http, webSocket: connector, scheduler: InstantScheduler()),
                             now: { 0 }, offer: { _, _, _, _ in })
        layer.start()
        let both = await eventually { connector.connections.count == 2 }
        XCTAssertTrue(both)
        XCTAssertTrue(connector.connections.allSatisfy { $0.headers["Authorization"] == "Bearer sk-test-prod" })
        await layer.close()
    }

    func testConnectFailureStops() async {
        let connector = FakeConnector()
        connector.fail = true
        let stops = stops
        let layer = GptLayer(config: config, key: APIKey("k")!,
                             transports: GptTransports(http: FakeHTTP(), webSocket: connector, scheduler: InstantScheduler()),
                             now: { 0 }, offer: { _, _, _, _ in }, onStopped: { stops.add($0) })
        layer.start()
        let snap = await layer.snapshot()
        XCTAssertEqual(snap.errors, ["realtime connect: URLError -1004"])
        XCTAssertEqual(stops.reasons, [.error])
        await layer.close()
    }
}

/// The self-pivot gate inside the GPT layer: it runs in shadow with a key, counts candidates in the
/// snapshot, and adds no judge call. Without a key there is no GPT layer, so no gate and no counts.
final class PivotShadowTests: XCTestCase {
    var config: ListenMoreConfig!
    let clock = ManualClock(0)
    let offers = OfferBox()

    override func setUpWithError() throws {
        config = try TestConfig.load()
        config.gpt.judgeMinIntervalS = 0
    }

    func pivot() -> PivotScript {
        var s = PivotScript()
        s.them(PivotLines.share, 0.5, 5.5)
        s.you(PivotLines.pivot, 6.0, 12.0)
        return s
    }

    func testTheCoreCountsATruePivotInItsSnapshot() {
        let core = GptCore(config: config)
        pivot().play(into: core, until: 30)
        let snap = core.snapshot
        XCTAssertEqual(snap.pivotCandidates, 1)
        XCTAssertEqual(snap.pivotRateLimited, 0)
        XCTAssertEqual(snap.pivotLateTranscripts, 0)
        XCTAssertEqual(core.pivot.candidates.map(\.turnEnd), [14.0])
    }

    func testMuteMidTurnIsNoneInTheCore() {
        var s = pivot()
        s.mute(true, at: 13.0)
        s.mute(false, at: 20.0)
        let core = GptCore(config: config)
        s.play(into: core, until: 30)
        XCTAssertEqual(core.snapshot.pivotCandidates, 0)
    }

    func testUnmuteDropsAShareHeardBeforeTheMute() {
        var s = PivotScript()
        s.them(PivotLines.share, 0.5, 5.5)
        s.mute(true, at: 6.0)
        s.mute(false, at: 6.5)
        s.you(PivotLines.pivot, 7.0, 13.0)
        let core = GptCore(config: config)
        s.play(into: core, until: 30)
        XCTAssertEqual(core.snapshot.pivotCandidates, 0)
    }

    /// Pause stops the engine, which closes the layer (`clearTranscript`); Resume builds a new one.
    func testClosingTheLayerMidTurnDropsTheTurn() {
        let core = GptCore(config: config)
        pivot().play(into: core, until: 30) { t in
            if abs(t - 13.0) < 1e-9 { core.clearTranscript() }
        }
        XCTAssertEqual(core.snapshot.pivotCandidates, 0)
        XCTAssertEqual(GptCore(config: config).snapshot.pivotCandidates, 0)
    }

    /// A stopped layer (an error or the budget cap) drops the gate's text at once and decides nothing.
    func testAStoppedLayerDropsTheTextAndDecidesNothing() {
        let core = GptCore(config: config)
        var held: [Int] = []
        pivot().play(into: core, until: 30) { t in
            if abs(t - 13.0) < 1e-9 {
                held.append(core.pivot.heldLines)
                core.fail("judge: HTTP 401")
                held.append(core.pivot.heldLines)
            }
        }
        XCTAssertEqual(held, [2, 0])
        XCTAssertEqual(core.snapshot.pivotCandidates, 0)
    }

    /// Steps the layer one frame at a time on the manual clock; transcripts come from the fake
    /// transcribers at each commit.
    func runLayer(_ s: PivotScript, judge: FakeJudge, until: Double, awaitJudgeCalls: Int = 0) async -> GptLayer.Snapshot {
        let clock = clock, offers = offers
        let layer = GptLayer(config: config, now: { clock.now() }, offer: { offers.add($0, $1, $2, $3) },
                             judge: judge, scheduler: InstantScheduler()) { speaker, onEvent in
            FakeTranscriber(speaker: speaker, script: speaker == .me ? [PivotLines.pivot] : [PivotLines.share], onEvent: onEvent)
        }
        layer.start()
        for f in s.frames(until: until) {
            clock.set(f.t)
            layer.feed(me: f.me.raw ? GptFrames.voiced : GptFrames.silent, meVad: f.me,
                       others: f.others.raw ? GptFrames.voiced : GptFrames.silent, othersVad: f.others, meRunS: 0)
            _ = await layer.snapshot()
        }
        if awaitJudgeCalls > 0 { _ = await eventually { await layer.snapshot().judgeCalls >= awaitJudgeCalls } }
        let snap = await layer.snapshot()
        await layer.close()
        return snap
    }

    /// MeetingCard's default (not_listening off): nothing is judged, and the candidate is only counted.
    func testACandidateAddsNoJudgeCallWithTheJudgeOff() async throws {
        config = try ListenMoreConfig.load(overrides: ["cues": ["disabled": ["not_listening"]], "gpt": ["judge_min_interval_s": 0]])
        let judge = FakeJudge()
        let snap = await runLayer(pivot(), judge: judge, until: 20)
        XCTAssertEqual(snap.pivotCandidates, 1)
        XCTAssertEqual(snap.judgeCalls, 0)
        XCTAssertEqual(judge.prompts, [])
        XCTAssertTrue(offers.offers.isEmpty)
    }

    /// With the judge on, the only call is the existing one on the user's first line after their turn.
    func testACandidateAddsNoJudgeCallWithTheJudgeOn() async {
        let judge = FakeJudge()
        let snap = await runLayer(pivot(), judge: judge, until: 20, awaitJudgeCalls: 1)
        XCTAssertEqual(snap.pivotCandidates, 1)
        XCTAssertEqual(snap.judgeCalls, 1)
        XCTAssertEqual(judge.prompts.count, 1)
        XCTAssertTrue(judge.prompts.allSatisfy { $0.hasSuffix("TRIGGER: me_reply") })
        XCTAssertTrue(offers.offers.isEmpty)
    }

    func testNoKeyMeansNoGateAndNoCounts() async {
        let engine = LocalCoachEngine(transports: GptTransports(http: FakeHTTP(), webSocket: FakeConnector(), scheduler: InstantScheduler()))
        engine.start(config: config, apiKey: nil)
        XCTAssertFalse(engine.hasGptLayer)
        let snap = await engine.gptSnapshot()
        XCTAssertNil(snap)
        XCTAssertNil(CoachPipeline(config: config, gpt: nil).text)
        engine.stop()
    }
}
