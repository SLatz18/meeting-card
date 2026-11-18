import Foundation
import XCTest
@testable import ListenMoreCore

// MARK: fakes (no network)

/// TypeSafe System One transport double: records each request and answers from `mode`.
final class FakeTypeSafeTransport: HTTPTransport, @unchecked Sendable {
    enum Mode {
        case reply(Int, Data)
        case fail(Error)
        /// Never answers; ends only when the call is cancelled.
        case hang
    }

    struct Request {
        var url: URL
        var headers: [String: String]
        var body: [String: Any]
        var raw: Data
        var timeout: TimeInterval
    }

    private let lock = NSLock()
    private var _requests: [Request] = []
    private var _mode: Mode
    /// Runs inside each call (e.g. to advance a clock).
    var onPost: (@Sendable () -> Void)?

    init(_ mode: Mode = .reply(200, FakeTypeSafeTransport.answers([:]))) {
        _mode = mode
    }

    var requests: [Request] { lock.withLock { _requests } }
    var mode: Mode {
        get { lock.withLock { _mode } }
        set { lock.withLock { _mode = newValue } }
    }

    func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval) async throws -> (status: Int, body: Data) {
        let parsed = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let mode = lock.withLock { () -> Mode in
            _requests.append(Request(url: url, headers: headers, body: parsed, raw: body, timeout: timeout))
            return _mode
        }
        onPost?()
        switch mode {
        case let .reply(status, data): return (status, data)
        case let .fail(error): throw error
        case .hang:
            try await Task.sleep(nanoseconds: 120_000_000_000)
            throw URLError(.timedOut)
        }
    }

    /// A System One reply: question id -> (choice, confidence; nil leaves confidence out).
    static func answers(_ answers: [String: (String, Double?)], usage: (input: Int, output: Int) = (120, 9)) -> Data {
        var out: [String: Any] = [:]
        for (id, a) in answers {
            var answer: [String: Any] = ["type": "choice", "choice": a.0,
                                         "probabilities": ["fire": a.0 == "fire" ? 0.9 : 0.1, "no_fire": a.0 == "fire" ? 0.1 : 0.9]]
            if let c = a.1 { answer["confidence"] = c }
            out[id] = answer
        }
        return try! JSONSerialization.data(withJSONObject: [
            "model": "jev-test", "answers": out, "usage": ["input_tokens": usage.input, "output_tokens": usage.output],
        ])
    }
}

/// Deadline clock for `TypeSafeJudge`: when `fires`, the timeout elapses at once; otherwise it never
/// elapses on its own (the sleep ends only when cancelled).
final class DeadlineClock: GptScheduler, @unchecked Sendable {
    let fires: Bool
    init(fires: Bool) { self.fires = fires }
    func monotonic() -> TimeInterval { 0 }
    func sleep(seconds: Double) async throws {
        if fires { return }
        try await Task.sleep(nanoseconds: 120_000_000_000)
    }
}

/// The reply from the one real System One call (11/17), verbatim.
enum SystemOneFixture {
    static let confirmedResponse = #"{"model":"jev-1.14.0","answers":{"missed_question":{"type":"choice","choice":"fire","confidence":1.0,"probabilities":{"fire":1.0,"no_fire":0.0}}},"usage":{"input_tokens":408,"output_tokens":34}}"#
}

// MARK: provider

final class TypeSafeJudgeTests: XCTestCase {
    static let secret = "ts-secret-value-0123456789"
    var config: ListenMoreConfig!
    let key = APIKey(TypeSafeJudgeTests.secret)!
    let window = [JudgeLine(speaker: .others, secondsAgo: 6.24, text: "How would we roll this out?"),
                  JudgeLine(speaker: .me, secondsAgo: 1.04, text: "Anyway, about the other thing.")]

    override func setUpWithError() throws {
        config = try TestConfig.load()
    }

    func judge(_ http: HTTPTransport, fires: Bool = false, _ ts: ListenMoreConfig.Judge.TypeSafe? = nil) -> TypeSafeJudge {
        TypeSafeJudge(config: ts ?? config.judge.typesafe, key: key, http: http, clock: DeadlineClock(fires: fires))
    }

    func decide(_ j: TypeSafeJudge, _ window: [JudgeLine]? = nil) async throws -> JudgeDecision {
        guard case .decided(let d) = try await j.judge(JudgeInput(prompt: "", window: window ?? self.window)) else {
            XCTFail("TypeSafe replies with a decision")
            return JudgeDecision()
        }
        return d
    }

    func testDefaultsAreGptWithTheTypeSafeSectionReady() throws {
        let built = try ListenMoreConfig.builtIn()
        XCTAssertEqual(built.judge.provider, .gpt, "GPT stays the default")
        let ts = built.judge.typesafe
        XCTAssertEqual(ts.url, "https://api.typesafe.ai/v1/systemone")
        XCTAssertEqual(ts.model, "jev-latest")
        XCTAssertEqual(ts.minConfidence, 0.7)
        XCTAssertNil(ts.costUsdPerCall, "no price is assumed")
        XCTAssertEqual(ts.questions.asked.map(\.type), CueType.judged)
    }

    func testRequestShape() async throws {
        let http = FakeTypeSafeTransport()
        _ = try await decide(judge(http))
        let req = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(http.requests.count, 1)
        XCTAssertEqual(req.url.absoluteString, "https://api.typesafe.ai/v1/systemone")
        XCTAssertEqual(req.headers, ["Authorization": "Bearer \(Self.secret)", "Content-Type": "application/json"])
        XCTAssertEqual(req.timeout, config.judge.typesafe.timeoutS)
        XCTAssertEqual(Set(req.body.keys), ["model", "state", "questions"])
        XCTAssertEqual(req.body["model"] as? String, "jev-latest")

        let state = try XCTUnwrap(req.body["state"] as? [String: Any])
        XCTAssertEqual(Set(state.keys), ["transcript"], "the state is the transcript window only")
        let lines = try XCTUnwrap(state["transcript"] as? [[String: Any]])
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines.allSatisfy { Set($0.keys) == ["speaker", "seconds_ago", "text"] })
        XCTAssertEqual(lines.map { $0["speaker"] as? String }, ["OTHERS", "ME"])
        XCTAssertEqual(lines.map { ($0["seconds_ago"] as? NSNumber)?.doubleValue }, [6.2, 1.0])
        XCTAssertEqual(lines.map { $0["text"] as? String }, ["How would we roll this out?", "Anyway, about the other thing."])

        let questions = try XCTUnwrap(req.body["questions"] as? [String: [String: Any]])
        XCTAssertEqual(Set(questions.keys), ["aggressive", "not_listening", "missed_question"])
        for (type, q) in config.judge.typesafe.questions.asked {
            let sent = try XCTUnwrap(questions[type.rawValue])
            XCTAssertEqual(Set(sent.keys), ["type", "instructions", "criteria"])
            XCTAssertEqual(sent["type"] as? String, "choice")
            XCTAssertEqual(sent["instructions"] as? String, config.judge.typesafe.context + " " + q.instructions)
            XCTAssertEqual(sent["criteria"] as? [String: String], ["fire": q.fire, "no_fire": q.noFire])
        }
        let raw = String(decoding: req.raw, as: UTF8.self)
        XCTAssertFalse(raw.contains(Self.secret), "the key goes in the header only")
        XCTAssertFalse(raw.contains("LOCAL_FLAGS") || raw.contains("prosody") || raw.contains("TRIGGER"))
    }

    func testConfirmedResponseDecodes() throws {
        let reply = try SystemOne.decode(Data(SystemOneFixture.confirmedResponse.utf8))
        XCTAssertEqual(reply, SystemOne.Response(
            model: "jev-1.14.0",
            answers: ["missed_question": SystemOne.Answer(type: "choice", choice: "fire", confidence: 1.0,
                                                          probabilities: ["fire": 1.0, "no_fire": 0.0])],
            usage: SystemOne.Usage(inputTokens: 408, outputTokens: 34)))
        XCTAssertTrue(reply.answers["missed_question"]?.fires == true)
    }

    func testConfirmedResponseThroughTheJudge() async throws {
        let http = FakeTypeSafeTransport(.reply(200, Data(SystemOneFixture.confirmedResponse.utf8)))
        let d = try await decide(judge(http))
        XCTAssertNil(d.failure)
        XCTAssertEqual(d.verdicts, [JudgeVerdict(label: "missed_question", confidence: 1.0)],
                       "the missing aggressive and not_listening answers give no cue")
        XCTAssertEqual(d.belowFloor, 0)
        XCTAssertEqual(d.inputTokens, 408)
        XCTAssertEqual(d.outputTokens, 34)
        XCTAssertEqual(d.model, "jev-1.14.0")
    }

    /// `questions` is an object keyed by question id; each value is {type: choice, instructions,
    /// criteria: {fire, no_fire}}. Byte for byte, sorted keys.
    func testRequestEncodesTheConfirmedShape() throws {
        var ts = config.judge.typesafe
        ts.context = "Context."
        ts.questions = .init(aggressive: nil, notListening: nil,
                             missedQuestion: .init(instructions: "Was a question missed?", fire: "It was missed.", noFire: "It was answered."))
        let body = try SystemOne.encode(SystemOne.request(ts, window: [JudgeLine(speaker: .others, secondsAgo: 6.24, text: "one two three?"),
                                                                       JudgeLine(speaker: .me, secondsAgo: 1.04, text: "four five.")]))
        XCTAssertEqual(String(decoding: body, as: UTF8.self), #"{"model":"jev-latest","questions":{"missed_question":{"criteria":{"fire":"It was missed.","no_fire":"It was answered."},"instructions":"Context. Was a question missed?","type":"choice"}},"state":{"transcript":[{"seconds_ago":6.2,"speaker":"OTHERS","text":"one two three?"},{"seconds_ago":1,"speaker":"ME","text":"four five."}]}}"#)
        let parsed = try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertNotNil(parsed["questions"] as? [String: Any], "questions is an object, not an array")
    }

    func testUnknownOrMissingAnswersGiveNoCue() async throws {
        let body = #"{"model":"jev-1.14.0","answers":{"missed_question":{"type":"noul","noul":0.97},"not_listening":{"type":"choice","choice":"maybe","confidence":1.0},"talk_over":{"type":"choice","choice":"fire","confidence":1.0},"aggressive":{"type":"choice","choice":"fire","confidence":0.9,"probabilities":"odd"}}}"#
        let d = try await decide(judge(FakeTypeSafeTransport(.reply(200, Data(body.utf8)))))
        XCTAssertNil(d.failure, "unknown answers are not an error")
        XCTAssertEqual(d.verdicts, [JudgeVerdict(label: "aggressive", confidence: 0.9)], "an odd extra field doesn't drop a valid answer")
        XCTAssertEqual(d.inputTokens, 0, "no usage reported")
        let empty = try await decide(judge(FakeTypeSafeTransport(.reply(200, Data(#"{"model":"jev-1.14.0","answers":{}}"#.utf8)))))
        XCTAssertNil(empty.failure)
        XCTAssertEqual(empty.verdicts, [])
        let fireNoType = try await decide(judge(FakeTypeSafeTransport(.reply(200, Data(#"{"answers":{"aggressive":{"choice":"fire","confidence":1.0}}}"#.utf8)))))
        XCTAssertEqual(fireNoType.verdicts, [], "only a choice answer counts")
    }

    func testFailureKinds() {
        XCTAssertEqual([401, 403, 402, 429, 500, 503, 400, 404].map { JudgeFailure.http($0).kind },
                       [.auth, .auth, .balance, .rateLimited, .server, .server, .rejected, .rejected])
        XCTAssertEqual(JudgeFailure.timeout.kind, .timeout)
        XCTAssertEqual(JudgeFailure.transport.kind, .unreachable)
        XCTAssertEqual(JudgeFailure.badResponse.kind, .badReply)
    }

    func testEndpointModelFloorAndQuestionsAreConfigurable() async throws {
        var ts = config.judge.typesafe
        ts.url = "https://judge.example.test/v2/decide"
        ts.model = "jev-test"
        ts.minConfidence = 0.9
        ts.questions.aggressive = nil
        let http = FakeTypeSafeTransport(.reply(200, FakeTypeSafeTransport.answers([
            "not_listening": ("fire", 0.89), "missed_question": ("fire", 0.9), "aggressive": ("fire", 1.0),
        ])))
        let d = try await decide(judge(http, ts))
        let req = try XCTUnwrap(http.requests.first)
        XCTAssertEqual(req.url.absoluteString, "https://judge.example.test/v2/decide")
        XCTAssertEqual(req.body["model"] as? String, "jev-test")
        XCTAssertEqual(Set((req.body["questions"] as? [String: Any] ?? [:]).keys), ["not_listening", "missed_question"])
        XCTAssertEqual(d.verdicts, [JudgeVerdict(label: "missed_question", confidence: 0.9)], "an unasked question's answer is ignored")
        XCTAssertEqual(d.belowFloor, 1)
    }

    func testConfidenceFloor() async throws {
        let http = FakeTypeSafeTransport(.reply(200, FakeTypeSafeTransport.answers([
            "aggressive": ("fire", 0.69), "not_listening": ("fire", 0.7), "missed_question": ("no_fire", 0.99),
            "talk_over": ("fire", 1.0),
        ], usage: (321, 12))))
        let d = try await decide(judge(http))
        XCTAssertEqual(d.verdicts, [JudgeVerdict(label: "not_listening", confidence: 0.7)])
        XCTAssertEqual(d.belowFloor, 1)
        XCTAssertNil(d.failure)
        XCTAssertEqual(d.inputTokens, 321)
        XCTAssertEqual(d.outputTokens, 12)
        XCTAssertNil(d.costUsd)

        http.mode = .reply(200, FakeTypeSafeTransport.answers(["aggressive": ("fire", nil)]))
        let noConfidence = try await decide(judge(http))
        XCTAssertEqual(noConfidence.verdicts, [], "a fire with no confidence is under the floor")
        XCTAssertEqual(noConfidence.belowFloor, 1)
    }

    func testErrorsGiveNoCue() async throws {
        for status in [400, 401, 402, 429, 500, 503] {
            let d = try await decide(judge(FakeTypeSafeTransport(.reply(status, Data()))))
            XCTAssertEqual(d.failure, .http(status))
            XCTAssertEqual(d.verdicts, [])
        }
        let bad = try await decide(judge(FakeTypeSafeTransport(.reply(200, Data("not json".utf8)))))
        XCTAssertEqual(bad.failure, .badResponse)
        let noAnswers = try await decide(judge(FakeTypeSafeTransport(.reply(200, Data(#"{"model":"jev"}"#.utf8)))))
        XCTAssertEqual(noAnswers.failure, .badResponse)
        let offline = try await decide(judge(FakeTypeSafeTransport(.fail(URLError(.notConnectedToInternet)))))
        XCTAssertEqual(offline.failure, .transport)
        XCTAssertEqual(offline.verdicts, [])
    }

    func testTimeoutGivesNoCue() async throws {
        let hung = try await decide(judge(FakeTypeSafeTransport(.hang), fires: true))
        XCTAssertEqual(hung.failure, .timeout, "a reply that never comes is cut off at timeout_s")
        XCTAssertEqual(hung.verdicts, [])
        let timedOut = try await decide(judge(FakeTypeSafeTransport(.fail(URLError(.timedOut)))))
        XCTAssertEqual(timedOut.failure, .timeout)
    }

    func testPerCallCostIsTheConfiguredFieldOnly() async throws {
        var ts = config.judge.typesafe
        ts.costUsdPerCall = 0.004
        let d = try await decide(judge(FakeTypeSafeTransport(.reply(500, Data())), ts))
        XCTAssertEqual(d.costUsd, 0.004)
    }

    func testKeyNeverInErrorsOrDescriptions() async throws {
        struct Leaky: Error, CustomStringConvertible {
            var description: String { "Bearer \(TypeSafeJudgeTests.secret)" }
        }
        let echo = Data(#"{"error":{"message":"bad key \#(Self.secret)"}}"#.utf8)
        let echoed200 = Data(#"{"answers":{"aggressive":{"choice":"\#(Self.secret)"}},"note":"\#(Self.secret)"}"#.utf8)
        for mode in [FakeTypeSafeTransport.Mode.fail(Leaky()), .reply(401, echo), .reply(200, echoed200)] {
            let j = judge(FakeTypeSafeTransport(mode))
            let d = try await decide(j)
            var dumped = ""
            dump(j, to: &dumped)
            dump(d, to: &dumped)
            for text in [String(describing: d), String(reflecting: d), d.failure?.description ?? "", String(describing: j),
                         String(reflecting: j), dumped] {
                XCTAssertFalse(text.contains(Self.secret), text)
            }
        }
        XCTAssertEqual(JudgeFailure.classify(Leaky()).description, "transport error")
        XCTAssertEqual(GptError.safe(Leaky()), "Leaky")
    }

    func testRedactor() {
        let r = JudgeRedactor.redact(
            "Ping me at someone@example.com or join https://meet.example.com/abc-defg?pwd=x1y2, also example.org/j/987, dial +1 (555) 010-0199, pin 123456, and Avery said hi to avery-lane.",
            names: ["Avery", " "])
        XCTAssertEqual(r, "Ping me at [email] or join [link] also [link] dial [number], pin [number], and [name] said hi to [name]-lane.")
        XCTAssertEqual(JudgeRedactor.redact("We need 3 options by 2027, maybe 12.5 percent.", names: []),
                       "We need 3 options by 2027, maybe 12.5 percent.", "short numbers stay")
    }

    func testConfigRejectsBadTypeSafeSections() throws {
        func load(_ ts: [String: Any]) throws -> ListenMoreConfig { try ListenMoreConfig.load(overrides: ["judge": ["typesafe": ts]]) }
        XCTAssertThrowsError(try load(["url": "http://api.typesafe.ai/v1/systemone"]), "https only")
        XCTAssertThrowsError(try load(["min_confidence": 1.5]))
        XCTAssertThrowsError(try load(["timeout_s": 0]))
        XCTAssertThrowsError(try load(["cost_usd_per_call": -1]))
        XCTAssertThrowsError(try load(["questions": ["aggressive": NSNull(), "not_listening": NSNull(), "missed_question": NSNull()]]))
        XCTAssertThrowsError(try ListenMoreConfig.load(overrides: ["judge": ["provider": "other"]]))
        let picked = try ListenMoreConfig.load(overrides: ["judge": ["provider": "typesafe", "typesafe": ["questions": ["aggressive": NSNull()]]]])
        XCTAssertEqual(picked.judge.provider, .typesafe)
        XCTAssertEqual(picked.judge.typesafe.questions.asked.map(\.type), [.notListening, .missedQuestion])
    }

    func testProviderFactory() throws {
        var c = config!
        let make = { (c: ListenMoreConfig, judgeKey: APIKey?) in
            JudgeProviders.make(config: c, openAIKey: APIKey("openai-test")!, judgeKey: judgeKey, http: FakeHTTP(), scheduler: InstantScheduler())
        }
        XCTAssertTrue(make(c, nil) is GptJudgeProvider)
        XCTAssertTrue(make(c, key) is GptJudgeProvider, "a stored TypeSafe key changes nothing while gpt is selected")
        c.judge.provider = .typesafe
        XCTAssertNil(make(c, nil), "typesafe without its key judges nothing; no fallback")
        XCTAssertEqual(make(c, key)?.kind, .typesafe)
    }

    func testJudgeLabelsPerProvider() {
        XCTAssertEqual(CueType(judgeLabel: "not_listening", provider: .gpt), .notListening)
        for label in ["aggressive", "missed_question", "interrupt", "none"] {
            XCTAssertNil(CueType(judgeLabel: label, provider: .gpt), "the GPT judge maps as before: \(label)")
        }
        XCTAssertEqual(CueType.judged.compactMap { CueType(judgeLabel: $0.rawValue, provider: .typesafe) }, CueType.judged)
        for label in ["interrupt", "talk_over", "monologue", "talk_share", "none"] {
            XCTAssertNil(CueType(judgeLabel: label, provider: .typesafe), label)
        }
    }
}

// MARK: GPT layer with each provider

final class JudgeProviderCoreTests: XCTestCase {
    var config: ListenMoreConfig!

    override func setUpWithError() throws {
        config = try TestConfig.load()
    }

    /// Same transcript, same local flags, same requests and replies: the GPT path through the provider
    /// seam matches the original GptCore calls exactly.
    func testGptPathParity() {
        let usage = JudgeUsage(inputTokens: 900, cachedTokens: 100, outputTokens: 25)
        let results: [Result<(JudgeResult, JudgeUsage), Error>] = [
            .success((JudgeResult(cue: "not_listening", confidence: 0.9, shortReason: "x"), usage)),
            .success((JudgeResult(cue: "not_listening", confidence: 0.84, shortReason: "x"), usage)),
            .success((JudgeResult(cue: "none", confidence: 0.99, shortReason: "x"), usage)),
            .failure(GptError.http(429)),
            .failure(URLError(.timedOut)),
            .success((JudgeResult(cue: "not_listening", confidence: 0.97, shortReason: "x"), usage)),
            .failure(GptError.http(401)),
        ]
        let old = GptCore(config: config), new = GptCore(config: config)
        for core in [old, new] {
            core.onLocal(LocalEvent(kind: .prosody, t: 9, onset: 9,
                                    prosody: ProsodyReading(t: 9, baselineReady: true, flagged: true, loudnessJumpDb: 6.2, rateJumpPct: 3.0)))
            core.onLocal(LocalEvent(kind: .interrupt, t: 8, onset: 7.5))
            _ = core.onText(.others, text: "what do you think about the option", refT: 8, now: 8)
        }
        let a = old.onText(.me, text: "anyway the other thing", refT: 9, now: 9.5)
        let b = new.onText(.me, text: "anyway the other thing", refT: 9, now: 9.5)
        XCTAssertEqual(a.start, b.start)
        for (i, result) in results.enumerated() {
            let req = GptCore.JudgeRequest(refT: 9, reason: "me_reply"), t = 10 + Double(i)
            let prompt = old.beginJudge(req, now: t)
            let input = new.beginJudge(req, now: t, for: .gpt)
            XCTAssertEqual(input, prompt.map { JudgeInput(prompt: $0, window: []) })
            let reply: Result<JudgeReply, Error> = result.map { JudgeReply.gpt($0.0, $0.1) }
            XCTAssertEqual(new.finishJudge(req, reply: reply, now: t), old.finishJudge(req, result: result, now: t).map { [$0] } ?? [])
            XCTAssertEqual(new.snapshot.droppedVerdicts, old.snapshot.droppedVerdicts)
            XCTAssertEqual(new.snapshot.transientErrors, old.snapshot.transientErrors)
            XCTAssertEqual(new.snapshot.errors, old.snapshot.errors)
            XCTAssertEqual(new.snapshot.enabled, old.snapshot.enabled)
            XCTAssertEqual(new.cost, old.cost)
        }
        XCTAssertEqual(new.cost.totalUsd, new.cost.transcribeUsd + new.cost.judgeUsd, "no per-call price on the GPT path")
        XCTAssertNil(new.snapshot.judgeCallUsd)
        XCTAssertEqual(new.snapshot.judgeProvider, .gpt)
    }

    /// The GPT provider sends LiveJudge's request byte for byte.
    func testGptProviderSendsLiveJudgesRequest() async throws {
        let direct = FakeHTTP(), wrapped = FakeHTTP()
        direct.reply = ("not_listening", 0.91)
        wrapped.reply = ("not_listening", 0.91)
        let prompt = "TRANSCRIPT (oldest first):\n[- 2.0s] OTHERS: one two three\nTRIGGER: me_reply"
        let r1 = try await LiveJudge(config: config, key: APIKey("openai-test")!, http: direct, hosts: LearnedHosts()).judge(prompt: prompt)
        let provider = try XCTUnwrap(JudgeProviders.make(config: config, openAIKey: APIKey("openai-test")!, judgeKey: APIKey("ts-test")!,
                                                         http: wrapped, scheduler: InstantScheduler()))
        let reply = try await provider.judge(JudgeInput(prompt: prompt, window: [JudgeLine(speaker: .me, secondsAgo: 1, text: "ignored")]))
        guard case let .gpt(res, usage) = reply else { return XCTFail("the GPT provider replies with the GPT result") }
        XCTAssertEqual(res, r1.0)
        XCTAssertEqual(usage, r1.1)
        let a = try XCTUnwrap(direct.requests.first), b = try XCTUnwrap(wrapped.requests.first)
        XCTAssertEqual(a.url, b.url)
        XCTAssertEqual(a.headers, b.headers)
        XCTAssertEqual(a.timeout, b.timeout)
        let sorted = { (o: [String: Any]) in try JSONSerialization.data(withJSONObject: o, options: [.sortedKeys]) }
        XCTAssertEqual(try sorted(a.body), try sorted(b.body))
        XCTAssertEqual(try sorted(b.body), try sorted(LiveJudge.requestBody(gpt: config.gpt, prompt: prompt)))
    }

    func testTypeSafeWindowIsMinimalAndRedacted() {
        config.judge.provider = .typesafe
        config.judge.typesafe.maxLines = 3
        config.judge.typesafe.windowS = 30
        config.text.userNames = ["Avery"]
        let core = GptCore(config: config)
        core.onLocal(LocalEvent(kind: .prosody, t: 39, onset: 39,
                                prosody: ProsodyReading(t: 39, baselineReady: true, flagged: true, loudnessJumpDb: 6.2, rateJumpPct: 30)))
        core.onLocal(LocalEvent(kind: .interrupt, t: 38, onset: 37.5))
        _ = core.onText(.others, text: "too old for the window", refT: 5, now: 5)
        _ = core.onText(.others, text: "first in the window", refT: 15, now: 15)
        _ = core.onText(.me, text: "second", refT: 25, now: 25)
        _ = core.onText(.others, text: "Avery, can you send it to someone@example.com?", refT: 34, now: 34)
        _ = core.onText(.me, text: "Call 555 010 0199 or see https://example.com/x", refT: 38, now: 38.5)
        let input = core.beginJudge(GptCore.JudgeRequest(refT: 38, reason: "me_reply"), now: 40, for: .typesafe)
        XCTAssertEqual(input?.prompt, "", "no GPT prompt, flags or trigger go to a state-based judge")
        XCTAssertEqual(input?.window, [
            JudgeLine(speaker: .me, secondsAgo: 15, text: "second"),
            JudgeLine(speaker: .others, secondsAgo: 6, text: "[name], can you send it to [email]?"),
            JudgeLine(speaker: .me, secondsAgo: 1.5, text: "Call [number] or see [link]"),
        ])
        XCTAssertEqual(core.judgeGap(now: 40), config.gpt.judgeMinIntervalS, "the minimum interval applies to every provider")
    }

    func testTypeSafeVerdictsBecomeOffersAndFailuresStopOnlyJudging() {
        config.judge.provider = .typesafe
        let core = GptCore(config: config)
        let req = GptCore.JudgeRequest(refT: 3, reason: "me_reply")
        let offers = core.finishJudge(req, reply: .success(.decided(JudgeDecision(verdicts: [
            JudgeVerdict(label: "aggressive", confidence: 0.8), JudgeVerdict(label: "missed_question", confidence: 0.9),
        ], belowFloor: 1))), now: 4)
        XCTAssertEqual(offers, [GptCore.Offer(label: "aggressive", t: 4, refT: 3, confidence: 0.8),
                                GptCore.Offer(label: "missed_question", t: 4, refT: 3, confidence: 0.9)])
        XCTAssertEqual(core.snapshot.belowFloorVerdicts, 1)
        core.setMeRun(config.gpt.judgeSkipRunS + 1)
        XCTAssertEqual(core.finishJudge(req, reply: .success(.decided(JudgeDecision(verdicts: [JudgeVerdict(label: "not_listening", confidence: 0.99)]))), now: 5), [],
                       "not_listening is never offered during a long run")
        core.setMeRun(0)

        let fail = Result<JudgeReply, Error>.success(.decided(JudgeDecision(failure: .http(402))))
        XCTAssertEqual(core.finishJudge(req, reply: fail, now: 6), [])
        XCTAssertEqual(core.finishJudge(req, reply: fail, now: 7), [])
        XCTAssertEqual(core.finishJudge(req, reply: .success(.decided(JudgeDecision())), now: 8), [], "a good call resets the run")
        XCTAssertEqual(core.finishJudge(req, reply: .success(.decided(JudgeDecision(failure: .timeout))), now: 9), [])
        XCTAssertEqual(core.finishJudge(req, reply: fail, now: 10), [])
        XCTAssertTrue(core.judgeActive)
        XCTAssertEqual(core.finishJudge(req, reply: fail, now: 11), [])
        XCTAssertFalse(core.judgeActive, "max_consecutive_errors in a row stop judging")
        XCTAssertTrue(core.enabled, "transcription keeps running")
        XCTAssertNil(core.stopReason)
        XCTAssertEqual(core.snapshot.judgeFailures, 5)
        XCTAssertEqual(core.snapshot.lastJudgeFailure, "HTTP 402")
        XCTAssertNil(core.request(req), "no further judge calls this session")
    }

    func testPerCallCostCountsTowardTheBudgetOnlyWhenConfigured() {
        config.judge.provider = .typesafe
        let unpriced = GptCore(config: config)
        let req = GptCore.JudgeRequest(refT: 1, reason: "me_reply")
        _ = unpriced.finishJudge(req, reply: .success(.decided(JudgeDecision(costUsd: nil))), now: 2)
        XCTAssertEqual(unpriced.cost.judgeCalls, 1)
        XCTAssertEqual(unpriced.cost.totalUsd, 0)
        XCTAssertNil(unpriced.snapshot.judgeCallUsd, "no price configured: none reported")

        config.judge.typesafe.costUsdPerCall = 0.25
        config.gpt.budgetUsdPerCall = 0.4
        let priced = GptCore(config: config)
        _ = priced.finishJudge(req, reply: .success(.decided(JudgeDecision(costUsd: 0.25))), now: 2)
        XCTAssertFalse(priced.cost.exhausted)
        _ = priced.finishJudge(req, reply: .success(.decided(JudgeDecision(failure: .http(500), costUsd: 0.25))), now: 3)
        XCTAssertEqual(priced.snapshot.judgeCallUsd, 0.5)
        XCTAssertTrue(priced.cost.exhausted)
        XCTAssertNil(priced.beginJudge(req, now: 4, for: .typesafe))
        XCTAssertEqual(priced.stopReason, .budgetCap)
    }

    func testUsageTokensAreSummedAndReportedPerCallHour() {
        config.judge.provider = .typesafe
        let core = GptCore(config: config)
        XCTAssertNil(core.snapshot.judgeTokensPerCallHour, "no audio yet")
        let req = GptCore.JudgeRequest(refT: 1, reason: "me_reply")
        _ = core.finishJudge(req, reply: .success(.decided(JudgeDecision(inputTokens: 408, outputTokens: 34, model: "jev-1.14.0"))), now: 2)
        _ = core.finishJudge(req, reply: .success(.decided(JudgeDecision(failure: .timeout))), now: 3)
        _ = core.finishJudge(req, reply: .success(.decided(JudgeDecision(inputTokens: 392, outputTokens: 30))), now: 4)
        _ = core.feed(.me, frame: GptFrames.silent, vad: GptFrames.quiet, now: 1800)
        let snap = core.snapshot
        XCTAssertEqual(snap.judgeInputTokens, 800)
        XCTAssertEqual(snap.judgeOutputTokens, 64)
        XCTAssertEqual(snap.judgeModel, "jev-1.14.0")
        XCTAssertEqual(snap.callSeconds, 1800)
        XCTAssertEqual(snap.judgeTokensPerCallHour?.input, 1600)
        XCTAssertEqual(snap.judgeTokensPerCallHour?.output, 128)
        XCTAssertEqual(snap.judgeCalls, 3)
        XCTAssertNil(snap.judgeCallUsd, "tokens only: no dollar rate is assumed")
    }

    func testJudgeStopReasonIsTheFailureThatStoppedIt() {
        config.judge.provider = .typesafe
        let core = GptCore(config: config)
        let req = GptCore.JudgeRequest(refT: 1, reason: "me_reply")
        for (i, f) in [JudgeFailure.timeout, .timeout, .http(401)].enumerated() {
            XCTAssertNil(core.snapshot.judgeStopReason)
            _ = core.finishJudge(req, reply: .success(.decided(JudgeDecision(failure: f))), now: Double(i))
        }
        XCTAssertEqual(core.snapshot.judgeStopReason, .http(401))
        XCTAssertFalse(core.judgeActive)
        _ = core.finishJudge(req, reply: .success(.decided(JudgeDecision(failure: .timeout))), now: 9)
        XCTAssertEqual(core.snapshot.judgeStopReason, .http(401), "a late reply doesn't change why it stopped")
    }

    func testLatencyKeepsTheMostRecentCalls() {
        let core = GptCore(config: config)
        for ms in 0..<(GptCore.latencyKept + 5) { core.recordJudgeLatency(ms: ms) }
        XCTAssertEqual(core.snapshot.judgeLatenciesMs.count, GptCore.latencyKept)
        XCTAssertEqual(core.snapshot.judgeLatenciesMs.first, 5)
    }

    func testPipelineMapsLabelsForTheSelectedProvider() throws {
        let silence = [Float](repeating: 0, count: 480)
        let gptStub = StubPipelineGpt()
        let gptPipeline = CoachPipeline(config: config, gpt: gptStub)
        gptStub.queued = [.offer(label: "aggressive", t: 9.9, refT: 9.5, confidence: 0.95)]
        XCTAssertEqual(gptPipeline.process(t: 10, mic: silence[...], call: silence[...]), [], "GPT labels map as before")

        config.judge.provider = .typesafe
        for label in ["aggressive", "missed_question", "not_listening"] {
            let stub = StubPipelineGpt()
            let p = CoachPipeline(config: config, gpt: stub)
            stub.queued = [.offer(label: label, t: 9.9, refT: 9.5, confidence: 0.75)]
            let cue = try XCTUnwrap(p.process(t: 10, mic: silence[...], call: silence[...]).first)
            XCTAssertEqual(cue.type.rawValue, label)
            XCTAssertEqual(cue.source, .gpt)
            XCTAssertEqual(cue.confidence, 0.75)
        }
    }
}

final class TypeSafeLayerTests: XCTestCase {
    var config: ListenMoreConfig!
    let clock = ManualClock(0)
    let offers = OfferBox()
    let stops = StopBox()
    let segments = SegmentBox()
    let judgeStops = JudgeStopBox()
    let v = GptFrames.voiced, z = GptFrames.silent

    override func setUpWithError() throws {
        config = try TestConfig.load()
        config.gpt.judgeMinIntervalS = 0
        config.judge.provider = .typesafe
    }

    func makeLayer(me: [String], others: [String], provider: JudgeProvider?, scheduler: InstantScheduler = InstantScheduler()) -> GptLayer {
        let clock = clock, offers = offers, stops = stops, segments = segments, judgeStops = judgeStops
        let layer = GptLayer(config: config, now: { clock.now() }, offer: { offers.add($0, $1, $2, $3) },
                             onSegment: { s, t, r, _ in segments.add(s, t, r) }, onStopped: { stops.add($0) },
                             onJudgeStopped: { judgeStops.add($0) }, provider: provider, scheduler: scheduler) { speaker, onEvent in
            FakeTranscriber(speaker: speaker, script: speaker == .me ? me : others, onEvent: onEvent)
        }
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

    func testMyReplyIsJudgedByTypeSafeWithLatencyRecorded() async throws {
        clock.set(12)
        let scheduler = InstantScheduler()
        let http = FakeTypeSafeTransport(.reply(200, FakeTypeSafeTransport.answers([
            "aggressive": ("fire", 0.8), "not_listening": ("no_fire", 0.9), "missed_question": ("fire", 0.92),
        ])))
        http.onPost = { scheduler.advance(0.25) }
        let judge = TypeSafeJudge(config: config.judge.typesafe, key: APIKey(TypeSafeJudgeTests.secret)!, http: http,
                                  clock: DeadlineClock(fires: false))
        let layer = makeLayer(me: ["Anyway, about the other thing."], others: ["How would we roll this out?"], provider: judge,
                              scheduler: scheduler)
        utterance(layer, .others, onset: 9, offset: 10)
        utterance(layer, .me, onset: 11, offset: 11.5)
        let offered = await eventually { self.offers.offers.count == 2 }
        XCTAssertTrue(offered)
        XCTAssertEqual(offers.offers.map(\.label), ["aggressive", "missed_question"])
        XCTAssertEqual(offers.offers.map(\.refT), [11.5, 11.5])
        let req = try XCTUnwrap(http.requests.first)
        let lines = try XCTUnwrap((req.body["state"] as? [String: Any])?["transcript"] as? [[String: Any]])
        XCTAssertEqual(lines.map { $0["speaker"] as? String }, ["OTHERS", "ME"])
        XCTAssertEqual(lines.map { $0["text"] as? String }, ["How would we roll this out?", "Anyway, about the other thing."])
        let snap = await layer.snapshot()
        XCTAssertEqual(snap.judgeProvider, .typesafe)
        XCTAssertEqual(snap.judgeLatenciesMs, [250])
        XCTAssertEqual(snap.judgeCalls, 1)
        XCTAssertNil(snap.judgeCallUsd)
        XCTAssertEqual(segments.segments.map { $0.0 }, [.others, .me], "transcripts reach the transcript rules as before")
        await layer.close()
    }

    func testProviderFailuresNeverStopTheLayerAndNeverCarryTheKey() async {
        config.judge.typesafe.maxConsecutiveErrors = 2
        let echo = Data(#"{"error":"\#(TypeSafeJudgeTests.secret)"}"#.utf8)
        let judge = TypeSafeJudge(config: config.judge.typesafe, key: APIKey(TypeSafeJudgeTests.secret)!,
                                  http: FakeTypeSafeTransport(.reply(402, echo)), clock: DeadlineClock(fires: false))
        let layer = makeLayer(me: ["one", "two", "three"], others: ["what do you all think here", "and what about the rest", "any other ideas"],
                              provider: judge)
        for i in 0..<3 {
            let t = Double(i) * 4
            utterance(layer, .others, onset: t + 1, offset: t + 2)
            utterance(layer, .me, onset: t + 3, offset: t + 4)
            _ = await eventually { await layer.snapshot().judgeFailures == min(i + 1, 2) }
        }
        let snap = await layer.snapshot()
        XCTAssertTrue(snap.enabled)
        XCTAssertFalse(snap.judgeActive)
        XCTAssertEqual(snap.judgeFailures, 2, "judging stopped after two failures in a row")
        XCTAssertEqual(snap.lastJudgeFailure, "HTTP 402")
        XCTAssertEqual(snap.judgeStopReason, .http(402))
        XCTAssertEqual(judgeStops.failures, [.http(402)], "reported once, with the failure that stopped it")
        XCTAssertEqual(snap.errors, [])
        XCTAssertEqual(stops.reasons, [])
        XCTAssertEqual(offers.offers.count, 0)
        XCTAssertEqual(segments.segments.count, 6, "transcription keeps going")
        XCTAssertFalse(String(describing: snap).contains(TypeSafeJudgeTests.secret))
        await layer.close()
    }

    func testTimeoutThroughTheLayerGivesNoCue() async {
        let judge = TypeSafeJudge(config: config.judge.typesafe, key: APIKey(TypeSafeJudgeTests.secret)!,
                                  http: FakeTypeSafeTransport(.hang), clock: DeadlineClock(fires: true))
        let layer = makeLayer(me: ["anything at all"], others: ["what do you all think here"], provider: judge)
        utterance(layer, .others, onset: 1, offset: 2)
        utterance(layer, .me, onset: 3, offset: 4)
        let failed = await eventually { await layer.snapshot().judgeFailures == 1 }
        XCTAssertTrue(failed)
        let snap = await layer.snapshot()
        XCTAssertEqual(snap.lastJudgeFailure, "timeout")
        XCTAssertTrue(snap.enabled)
        XCTAssertEqual(offers.offers.count, 0)
        await layer.close()
    }

    func testNoProviderMeansNoJudgeCalls() async {
        let layer = makeLayer(me: ["anything at all"], others: ["what do you all think here"], provider: nil)
        utterance(layer, .others, onset: 1, offset: 2)
        utterance(layer, .me, onset: 3, offset: 4)
        _ = await eventually { self.segments.segments.count == 2 }
        let snap = await layer.snapshot()
        XCTAssertEqual(segments.segments.count, 2)
        XCTAssertFalse(snap.judgeActive)
        XCTAssertEqual(snap.judgeCalls, 0)
        XCTAssertTrue(snap.enabled)
        await layer.close()
    }

    func testEngineAppliesTheHostPickAndReadsTheTypeSafeKeyOnlyWhenSelected() async throws {
        let base = try TestConfig.load()
        let transports = GptTransports(http: FakeHTTP(), webSocket: FakeConnector(), scheduler: InstantScheduler())
        let gpt = LocalCoachEngine(transports: transports, judgeKeys: FakeKeys(fails: true))
        gpt.start(config: base, apiKey: APIKey("openai-test"))
        var snap = await gpt.gptSnapshot()
        XCTAssertEqual(snap?.judgeProvider, .gpt, "the default never reads the TypeSafe key (a failing read would show here)")
        XCTAssertEqual(snap?.judgeActive, true)
        gpt.stop()

        let noKey = LocalCoachEngine(transports: transports, judgeKeys: FakeKeys(key: nil), judgeProvider: { .typesafe })
        noKey.start(config: base, apiKey: APIKey("openai-test"))
        snap = await noKey.gptSnapshot()
        XCTAssertEqual(snap?.judgeProvider, .typesafe)
        XCTAssertEqual(snap?.judgeActive, false, "TypeSafe without its key: nothing is judged")
        XCTAssertEqual(snap?.enabled, true, "transcription still runs")
        noKey.stop()

        let withKey = LocalCoachEngine(transports: transports, judgeKeys: FakeKeys(key: APIKey("ts-test")), judgeProvider: { .typesafe })
        withKey.start(config: base, apiKey: APIKey("openai-test"))
        snap = await withKey.gptSnapshot()
        XCTAssertEqual(snap?.judgeActive, true)
        withKey.stop()

        let hostDefault = LocalCoachEngine(transports: transports, judgeProvider: { nil })
        XCTAssertEqual(hostDefault.sessionConfig(base).judge.provider, .gpt, "no pick keeps the config value")
    }
}

final class JudgeStopBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _failures: [JudgeFailure] = []
    var failures: [JudgeFailure] { lock.withLock { _failures } }
    func add(_ f: JudgeFailure) { lock.withLock { _failures.append(f) } }
}
