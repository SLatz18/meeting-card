import AVFoundation
import XCTest
@testable import ListenMoreMac

final class MonoResamplerTests: XCTestCase {
    func buffer(rate: Double, channels: AVAudioChannelCount, frames: Int, value: (Int, Int) -> Float) -> AVAudioPCMBuffer {
        let f = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: false)!
        let b = AVAudioPCMBuffer(pcmFormat: f, frameCapacity: AVAudioFrameCount(frames))!
        b.frameLength = AVAudioFrameCount(frames)
        for ch in 0..<Int(channels) {
            for i in 0..<frames { b.floatChannelData![ch][i] = value(ch, i) }
        }
        return b
    }

    func testPassThroughWhenFormatMatches() {
        let r = MonoResampler(sampleRate: 24000)
        let out = r.convert(buffer(rate: 24000, channels: 1, frames: 480) { _, i in Float(i) / 480 })
        XCTAssertEqual(out.count, 480)
        XCTAssertEqual(out[240], 0.5, accuracy: 1e-6)
    }

    func testStereo48kDownmixesAndResamplesTo24kMono() {
        let r = MonoResampler(sampleRate: 24000)
        // A 440 Hz tone on both channels: output keeps the energy and halves the sample count.
        let tone = buffer(rate: 48000, channels: 2, frames: 4800) { _, i in 0.5 * sin(2 * .pi * 440 * Float(i) / 48000) }
        var out: [Float] = []
        for _ in 0..<4 { out += r.convert(tone) }
        // AVAudioConverter keeps its filter's priming samples (~170 here), so the total runs a little short.
        XCTAssertEqual(Double(out.count), 4 * 2400, accuracy: 256)
        let tail = Array(out.suffix(2400))
        XCTAssertGreaterThan(AudioMath.rmsDbfs(tail), -12)
        XCTAssertLessThan(AudioMath.rmsDbfs(tail), -3)
    }
}

/// URLProtocol stub so the URLSession transports run end to end without the network.
final class StubURLProtocol: URLProtocol {
    nonisolated(unsafe) static var lastRequest: URLRequest?
    nonisolated(unsafe) static var lastBody: Data?
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var reply = Data("{}".utf8)

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.lastRequest = request
        if let body = request.httpBody {
            Self.lastBody = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buf = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let n = stream.read(&buf, maxLength: buf.count)
                if n <= 0 { break }
                data.append(buf, count: n)
            }
            stream.close()
            Self.lastBody = data
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Self.reply)
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

final class URLSessionTransportTests: XCTestCase {
    func stubbedConfiguration() -> URLSessionConfiguration {
        let c = EphemeralSession.configuration()
        c.protocolClasses = [StubURLProtocol.self]
        return c
    }

    func testEphemeralConfigurationStoresNothing() {
        let c = EphemeralSession.configuration()
        XCTAssertNil(c.urlCache)
        XCTAssertNil(c.httpCookieStorage)
        XCTAssertNil(c.urlCredentialStorage)
        XCTAssertFalse(c.httpShouldSetCookies)
    }

    func testJudgeThroughURLSession() async throws {
        let inner = #"{"cue":"not_listening","confidence":0.8,"short_reason":"ignored point"}"#
        let reply: [String: Any] = ["output": [["type": "message", "content": [["type": "output_text", "text": inner]]]],
                                    "usage": ["input_tokens": 10, "output_tokens": 5]]
        StubURLProtocol.reply = try JSONSerialization.data(withJSONObject: reply)
        StubURLProtocol.status = 200
        let config = try ListenMoreConfig.builtIn()
        let judge = LiveJudge(config: config, key: APIKey("sk-test-urlsession")!, http: URLSessionHTTPTransport(configuration: stubbedConfiguration()), hosts: LearnedHosts())
        let (res, usage) = try await judge.judge(prompt: "p")
        XCTAssertEqual(res.cue, "not_listening")
        XCTAssertEqual(usage.inputTokens, 10)
        let req = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-urlsession")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Content-Type"), "application/json")
        XCTAssertEqual(req.timeoutInterval, config.gpt.judgeTimeoutS)
        let body = try XCTUnwrap(StubURLProtocol.lastBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(body["store"] as? Bool, false)
        XCTAssertEqual(body["model"] as? String, "gpt-6-luna")
    }

    /// The self-pivot judge over the real URLSession transport: store false and its own schema.
    func testSelfPivotJudgeThroughURLSession() async throws {
        let inner = #"{"cue":"self_pivot","confidence":0.9,"short_reason":"own story"}"#
        let reply: [String: Any] = ["output": [["type": "message", "content": [["type": "output_text", "text": inner]]]],
                                    "usage": ["input_tokens": 10, "output_tokens": 5]]
        StubURLProtocol.reply = try JSONSerialization.data(withJSONObject: reply)
        StubURLProtocol.status = 200
        let config = try ListenMoreConfig.builtIn()
        let judge = LiveJudge(config: config, key: APIKey("sk-test-urlsession")!, http: URLSessionHTTPTransport(configuration: stubbedConfiguration()),
                              hosts: LearnedHosts(), spec: .selfPivot)
        let (res, _) = try await judge.judge(prompt: "p")
        XCTAssertEqual(res.cue, "self_pivot")
        let body = try XCTUnwrap(StubURLProtocol.lastBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(body["store"] as? Bool, false)
        let format = (body["text"] as? [String: Any])?["format"] as? [String: Any]
        XCTAssertEqual(format?["name"] as? String, "listen_more_self_pivot")
    }

    func testHttpErrorStatusSurfacesAsCodeOnly() async throws {
        StubURLProtocol.status = 429
        StubURLProtocol.reply = Data("rate limited for key sk-test".utf8)
        let config = try ListenMoreConfig.builtIn()
        let judge = LiveJudge(config: config, key: APIKey("sk-test")!, http: URLSessionHTTPTransport(configuration: stubbedConfiguration()), hosts: LearnedHosts())
        do {
            _ = try await judge.judge(prompt: "p")
            XCTFail("expected failure")
        } catch {
            XCTAssertEqual(GptError.safe(error), "HTTP 429")
        }
    }

    func testTypeSafeJudgeThroughURLSession() async throws {
        let reply: [String: Any] = ["answers": ["missed_question": ["type": "choice", "choice": "fire", "confidence": 0.9,
                                                                    "probabilities": ["fire": 0.95, "no_fire": 0.05]]]]
        StubURLProtocol.reply = try JSONSerialization.data(withJSONObject: reply)
        StubURLProtocol.status = 200
        let config = try ListenMoreConfig.builtIn()
        let judge = TypeSafeJudge(config: config.judge.typesafe, key: APIKey("ts-test-urlsession")!,
                                  http: URLSessionHTTPTransport(configuration: stubbedConfiguration()), clock: SystemGptScheduler())
        let out = try await judge.judge(JudgeInput(prompt: "", window: [JudgeLine(speaker: .others, secondsAgo: 2, text: "one two three?")]))
        guard case .decided(let d) = out else { return XCTFail("expected a decision") }
        XCTAssertEqual(d.verdicts, [JudgeVerdict(label: "missed_question", confidence: 0.9)])
        let req = try XCTUnwrap(StubURLProtocol.lastRequest)
        XCTAssertEqual(req.url?.absoluteString, "https://api.typesafe.ai/v1/systemone")
        XCTAssertEqual(req.httpMethod, "POST")
        XCTAssertEqual(req.value(forHTTPHeaderField: "Authorization"), "Bearer ts-test-urlsession")
        XCTAssertEqual(req.timeoutInterval, config.judge.typesafe.timeoutS)
        let body = try XCTUnwrap(StubURLProtocol.lastBody.flatMap { try JSONSerialization.jsonObject(with: $0) as? [String: Any] })
        XCTAssertEqual(Set(body.keys), ["model", "state", "questions"])

        StubURLProtocol.status = 402
        StubURLProtocol.reply = Data("insufficient balance for ts-test-urlsession".utf8)
        guard case .decided(let failed) = try await judge.judge(JudgeInput(prompt: "", window: [])) else { return XCTFail() }
        XCTAssertEqual(failed.failure, .http(402))
        XCTAssertFalse(String(describing: failed).contains("ts-test-urlsession"))
    }

    func testWebSocketRequestCarriesAuthHeader() {
        let r = URLSessionWebSocketConnector.request(url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!,
                                                     headers: ["Authorization": "Bearer sk-test-ws"])
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-ws")
        XCTAssertEqual(r.url?.query, "intent=transcription")
        XCTAssertEqual(r.cachePolicy, .reloadIgnoringLocalCacheData)
    }
}

final class ProcessTableTests: XCTestCase {
    func testProcessTableHasOurProcess() {
        let table = ProcessTable.snapshot()
        XCTAssertTrue(table.contains { $0.pid == getpid() })
        XCTAssertTrue(table.contains { $0.pid == getpid() && $0.parentPid == getppid() })
    }
}
