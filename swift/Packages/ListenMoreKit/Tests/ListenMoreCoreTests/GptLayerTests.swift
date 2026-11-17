import XCTest
@testable import ListenMoreCore

/// Ports of the reference engine's tests/test_cues_gpt.py (GPT parts), plus wire-format checks.
final class GptLayerTests: XCTestCase {
    var config: ListenMoreConfig!

    override func setUpWithError() throws {
        config = try TestConfig.load()
    }

    func testRollingTranscriptPrunes() {
        var r = RollingTranscript(windowS: 90)
        r.add(t: 0, speaker: .others, text: "token-a")
        r.add(t: 50, speaker: .me, text: "token-b")
        r.add(t: 100, speaker: .others, text: "token-c")
        let text = r.render(now: 100)
        XCTAssertFalse(text.contains("token-a"))
        XCTAssertTrue(text.contains("ME: token-b"))
        r.clear()
        XCTAssertTrue(r.lines.isEmpty)
    }

    func testCostAndBudget() {
        var c = CostTracker(prices: config.gpt.pricesUsd, budgetUsd: 0.05)
        c.addAudio(seconds: 60)
        XCTAssertEqual(c.transcribeUsd, 0.017, accuracy: 1e-9)
        XCTAssertFalse(c.exhausted)
        c.addAudio(seconds: 180)
        XCTAssertTrue(c.exhausted)
    }

    func testJudgeCost() {
        var c = CostTracker(prices: config.gpt.pricesUsd, budgetUsd: 1)
        c.addJudge(JudgeUsage(inputTokens: 1_000_000, cachedTokens: 500_000, outputTokens: 100_000))
        XCTAssertEqual(c.judgeUsd, 0.05 + 0.005 + 0.05, accuracy: 1e-9)
        XCTAssertEqual(c.judgeCalls, 1)
    }

    func testSchemaAndStoreFalse() throws {
        XCTAssertEqual(OpenAIWire.judgeLabels, ["none", "interrupting", "aggressive", "not_listening", "missed_question"])
        XCTAssertFalse(config.gpt.store)
        let body = try XCTUnwrap(JSONSerialization.jsonObject(with: OpenAIWire.judgeBody(config.gpt, prompt: "p")) as? [String: Any])
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["model"] as? String, "gpt-6-luna")
        XCTAssertEqual((body["reasoning"] as? [String: Any])?["effort"] as? String, "none")
        let format = try XCTUnwrap((body["text"] as? [String: Any])?["format"] as? [String: Any])
        XCTAssertEqual(format["type"] as? String, "json_schema")
        XCTAssertEqual(format["strict"] as? Bool, true)
    }

    func testStoreTrueIsRejected() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lm-\(UUID().uuidString).json")
        try Data(#"{"gpt": {"store": true}}"#.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        XCTAssertThrowsError(try ListenMoreConfig.load(overrideURL: url))
    }

    func testSessionUpdateIsTranscriptionWithoutServerVad() throws {
        let s = try XCTUnwrap(JSONSerialization.jsonObject(with: OpenAIWire.sessionUpdate(config.gpt, sampleRate: 24000)) as? [String: Any])
        XCTAssertEqual(s["type"] as? String, "session.update")
        let session = try XCTUnwrap(s["session"] as? [String: Any])
        XCTAssertEqual(session["type"] as? String, "transcription")
        let input = try XCTUnwrap((session["audio"] as? [String: Any])?["input"] as? [String: Any])
        XCTAssertTrue(input["turn_detection"] is NSNull)
        XCTAssertEqual((input["format"] as? [String: Any])?["rate"] as? Int, 24000)
        XCTAssertEqual((input["transcription"] as? [String: Any])?["model"] as? String, "gpt-live-transcribe")
    }

    func testAppendAudioIsBase64Pcm16() throws {
        let pcm = PCM.pcm16([0, 1, -1])
        XCTAssertEqual(pcm.count, 6)
        let m = try XCTUnwrap(JSONSerialization.jsonObject(with: OpenAIWire.appendAudio(pcm)) as? [String: Any])
        XCTAssertEqual(m["type"] as? String, "input_audio_buffer.append")
        XCTAssertEqual(Data(base64Encoded: m["audio"] as? String ?? ""), pcm)
    }

    func testParseRealtimeEvents() {
        XCTAssertEqual(OpenAIWire.parseRealtime(Data(#"{"type":"input_audio_buffer.committed","item_id":"a"}"#.utf8)), .committed(itemId: "a"))
        XCTAssertEqual(OpenAIWire.parseRealtime(Data(#"{"type":"conversation.item.input_audio_transcription.completed","item_id":"a","transcript":"token","usage":{"type":"duration","seconds":1.5}}"#.utf8)),
                       .transcript(itemId: "a", text: "token", audioSeconds: 1.5))
        XCTAssertEqual(OpenAIWire.parseRealtime(Data(#"{"type":"error","error":{"code":"x"}}"#.utf8)), .error)
        XCTAssertEqual(OpenAIWire.parseRealtime(Data("not json".utf8)), .other)
    }

    func testParseJudge() throws {
        let resp = #"{"output":[{"type":"message","content":[{"type":"output_text","text":"{\"cue\":\"aggressive\",\"confidence\":0.82,\"short_reason\":\"x\"}"}]}],"usage":{"input_tokens":120,"output_tokens":9,"input_tokens_details":{"cached_tokens":100}}}"#
        let (r, u) = try OpenAIWire.parseJudge(Data(resp.utf8))
        XCTAssertEqual(r, JudgeResult(cue: "aggressive", confidence: 0.82))
        XCTAssertEqual(u, JudgeUsage(inputTokens: 120, cachedTokens: 100, outputTokens: 9))
        XCTAssertThrowsError(try OpenAIWire.parseJudge(Data(#"{"output":[]}"#.utf8)))
        let bad = #"{"output":[{"type":"message","content":[{"type":"output_text","text":"{\"cue\":\"shout\",\"confidence\":1}"}]}]}"#
        XCTAssertThrowsError(try OpenAIWire.parseJudge(Data(bad.utf8)))
    }

    /// Port of test_safe_err_never_has_headers: errors carry a kind and a status, nothing else.
    func testErrorsNeverCarryContent() {
        let e = GptError(.judgeHTTP, httpStatus: 401)
        XCTAssertEqual(e.description, "judgeHTTP(401)")
        XCTAssertEqual(String(describing: GptError(.budgetCap)), "budgetCap")
        var dumped = ""
        dump(e, to: &dumped)
        XCTAssertFalse(dumped.contains("Bearer"))
    }

    func testMockJudge() {
        XCTAssertEqual(MockJudge.decide("[-1.0s] ME: token \(MockJudge.hostileMarker)").cue, "aggressive")
        XCTAssertEqual(MockJudge.decide("PENDING_QUESTION: yes ME_ANSWERED_SINCE: no").cue, "missed_question")
        XCTAssertEqual(MockJudge.decide("[-1.0s] ME: token").cue, "none")
    }

    // MARK: GptLayer

    final class FailingJudge: Judge {
        func judge(prompt: String, completion: @escaping (Result<(JudgeResult, JudgeUsage), GptError>) -> Void) {
            completion(.failure(GptError(.judgeHTTP, httpStatus: 401)))
        }
    }

    func makeLayer(judge: Judge, budget: Double = 1, now: Double = 10, queue: DispatchQueue,
                   offers: @escaping (String) -> Void = { _ in }, disabled: @escaping (GptErrorKind) -> Void = { _ in }) -> (GptLayer, [Speaker: MockTranscriber]) {
        var c = config!
        c.gpt.judgeMinIntervalS = 0
        c.gpt.budgetUsdPerCall = budget
        let tx: [Speaker: MockTranscriber] = [.me: MockTranscriber(script: [], speaker: .me), .others: MockTranscriber(script: [], speaker: .others)]
        let layer = GptLayer(config: c, queue: queue, now: { now }, transcribers: tx, judge: judge,
                             offer: { label, _, _, _ in offers(label) }, onDisabled: disabled)
        return (layer, tx)
    }

    func testPromptCarriesProsodyAndOverlapFlags() {
        let q = DispatchQueue(label: "t")
        let (layer, _) = makeLayer(judge: MockJudge(), queue: q)
        q.sync {
            layer.onLocal(LocalEvent(kind: .prosody, t: 9, onset: 9,
                                     prosody: ProsodyFlags(t: 9, baselineReady: true, flagged: true, loudnessJumpDb: 6.2, rateJumpPct: 31.5)))
            layer.onLocal(LocalEvent(kind: .interrupt, t: 8, onset: 7.5))
            let p = layer.buildPrompt(.init(refT: 10, reason: "me_turn"))
            XCTAssertTrue(p.contains("prosody_flagged=yes loudness_jump_db=6.2 rate_jump_pct=31.5"), p)
            XCTAssertTrue(p.contains("recent_overlaps=interrupt@-2.5s"), p)
            XCTAssertTrue(p.contains("TRIGGER: me_turn"))
        }
    }

    func testPrerollThenStreamThenCommit() {
        let q = DispatchQueue(label: "t")
        let (layer, tx) = makeLayer(judge: MockJudge(), queue: q)
        let frame = [Float](repeating: 0.1, count: 480)
        q.sync {
            for _ in 0..<30 { layer.feed(.me, frame: frame[...], onset: nil, offset: nil) }
            XCTAssertEqual(tx[.me]?.audioBytes, 0, "nothing is sent before speech starts")
            layer.feed(.me, frame: frame[...], onset: 1.0, offset: nil)
            // 300 ms pre-roll (7200 samples) + the onset frame, as 16-bit PCM.
            XCTAssertEqual(tx[.me]?.audioBytes, (7200 + 480) * 2)
            layer.feed(.me, frame: frame[...], onset: nil, offset: 1.5)
            layer.feed(.me, frame: frame[...], onset: nil, offset: nil)
            XCTAssertEqual(tx[.me]?.audioBytes, (7200 + 480 * 2) * 2, "stops streaming after the offset")
        }
    }

    func testJudgeFailureDisablesLayer() {
        let q = DispatchQueue(label: "t")
        let done = expectation(description: "disabled")
        let (layer, _) = makeLayer(judge: FailingJudge(), queue: q, disabled: { kind in
            XCTAssertEqual(kind, .judgeHTTP)
            done.fulfill()
        })
        q.async { layer.onText(.me, "token", 9) }
        wait(for: [done], timeout: 2)
        q.sync { XCTAssertFalse(layer.enabled) }
    }

    func testBudgetCapStopsStreaming() {
        let q = DispatchQueue(label: "t")
        let done = expectation(description: "disabled")
        let (layer, tx) = makeLayer(judge: MockJudge(), budget: 0.0001, queue: q, disabled: { kind in
            XCTAssertEqual(kind, .budgetCap)
            done.fulfill()
        })
        let frame = [Float](repeating: 0.1, count: 480)
        q.async {
            layer.feed(.me, frame: frame[...], onset: 0, offset: nil)
            for _ in 0..<50 { layer.feed(.me, frame: frame[...], onset: nil, offset: nil) }
        }
        wait(for: [done], timeout: 2)
        q.sync { XCTAssertLessThan(tx[.me]?.audioBytes ?? 0, 51 * 960 + 7200 * 2) }
    }

    func testMissedQuestionAfterDeadline() {
        let q = DispatchQueue(label: "t")
        var c = config!
        c.gpt.questionWaitS = 0.1
        c.gpt.judgeMinIntervalS = 0
        let got = expectation(description: "missed_question")
        let judge = MockJudge()
        let layer = GptLayer(config: c, queue: q, now: { 10 }, transcribers: [:], judge: judge,
                             offer: { label, _, _, _ in if label == "missed_question" { got.fulfill() } }, onDisabled: { _ in })
        q.async { layer.onText(.others, "can you send it today?", 10) }
        wait(for: [got], timeout: 3)
    }
}
