import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ListenMoreCore

/// The network a live run uses. `real()` is OpenAI over HTTPS and WSS; tests inject fakes to check
/// the live wiring (key handling, metering) without the network.
public struct LiveBackend: @unchecked Sendable {
    public var http: HTTPTransport
    public var webSocket: WebSocketConnector
    public var scheduler: GptScheduler

    public init(http: HTTPTransport, webSocket: WebSocketConnector, scheduler: GptScheduler = SystemGptScheduler()) {
        self.http = http
        self.webSocket = webSocket
        self.scheduler = scheduler
    }

    public static func real() -> LiveBackend {
        LiveBackend(http: EphemeralHTTPTransport(), webSocket: PlatformWebSocket.connector())
    }
}

/// `HTTPTransport` over an ephemeral URLSession: no cache, cookies or credential storage on disk.
public final class EphemeralHTTPTransport: HTTPTransport, @unchecked Sendable {
    let session: URLSession

    public init() {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.urlCredentialStorage = nil
        c.httpShouldSetCookies = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: c)
    }

    public func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval) async throws -> (status: Int, body: Data) {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        r.httpMethod = "POST"
        r.httpBody = body
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await session.data(for: r)
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// OpenAI text-to-speech for the synthetic voices: raw 24 kHz 16-bit mono PCM, kept in memory only.
public struct OpenAITTS: Sendable {
    public static let url = URL(string: "https://api.openai.com/v1/audio/speech")!
    /// Generic stock voices, one per role.
    public static let voices: [Voice: String] = [.you: "alloy", .themA: "coral", .themB: "onyx"]
    /// Published estimate for the default model, per minute of generated audio (logged, never capped).
    public static let estimatedUsdPerMinute = 0.015

    public var model: String
    let key: APIKey
    let http: HTTPTransport

    public init(key: APIKey, http: HTTPTransport, model: String = "gpt-4o-mini-tts") {
        self.key = key
        self.http = http
        self.model = model
    }

    public static func requestBody(model: String, voice: String, text: String) -> [String: Any] {
        ["model": model, "voice": voice, "input": text, "response_format": "pcm"]
    }

    /// Samples at 24 kHz (the format's fixed rate), resampled to `sampleRate` if that differs.
    public func speak(_ text: String, voice: Voice, sampleRate: Int) async throws -> [Float] {
        let body = try JSONSerialization.data(withJSONObject: Self.requestBody(model: model, voice: Self.voices[voice] ?? "alloy", text: text))
        let (status, data) = try await http.post(url: Self.url, headers: ["Authorization": "Bearer \(key.value)", "Content-Type": "application/json"],
                                                 body: body, timeout: 60)
        guard status == 200 else { throw HarnessError.tts(status) }
        var samples = [Float](repeating: 0, count: data.count / 2)
        data.withUnsafeBytes { raw in
            for (i, s) in raw.bindMemory(to: Int16.self).enumerated() where i < samples.count {
                samples[i] = Float(Int16(littleEndian: s)) / 32768
            }
        }
        return sampleRate == 24000 ? samples : AudioMath.resample(samples[...], from: 24000, to: sampleRate)
    }
}

/// Wraps the judge's HTTP transport to log token usage from each reply (numbers only).
public final class MeteredHTTP: HTTPTransport, @unchecked Sendable {
    let inner: HTTPTransport
    private let lock = NSLock()
    private var _calls = 0
    private var _inputTokens = 0
    private var _outputTokens = 0
    private var _failures = 0

    public init(inner: HTTPTransport) {
        self.inner = inner
    }

    public var calls: Int { lock.withLock { _calls } }
    public var tokens: (input: Int, output: Int) { lock.withLock { (_inputTokens, _outputTokens) } }
    public var failures: Int { lock.withLock { _failures } }

    public func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval) async throws -> (status: Int, body: Data) {
        let reply = try await inner.post(url: url, headers: headers, body: body, timeout: timeout)
        let usage = ((try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any])?["usage"] as? [String: Any]
        lock.withLock {
            _calls += 1
            if reply.status != 200 { _failures += 1 }
            _inputTokens += (usage?["input_tokens"] as? NSNumber)?.intValue ?? 0
            _outputTokens += (usage?["output_tokens"] as? NSNumber)?.intValue ?? 0
        }
        return reply
    }
}

/// Wraps the realtime connector to observe traffic: appends per stream with times, commits, clears,
/// closes, and billed seconds from `completed` usage. Transcript text is never read or kept.
public final class MeteredConnector: WebSocketConnector, SocketObserver, @unchecked Sendable {
    let inner: WebSocketConnector
    let clock: HarnessClock
    private let lock = NSLock()
    private var origin = 0.0
    private var s = SocketStats()

    public init(inner: WebSocketConnector, clock: HarnessClock) {
        self.inner = inner
        self.clock = clock
    }

    public func setOrigin(_ origin: Double) { lock.withLock { self.origin = origin } }
    public func stats() -> SocketStats { lock.withLock { s } }

    public func connect(url: URL, headers: [String: String]) async throws -> WebSocketConnection {
        let stream: AudioStream = lock.withLock {
            defer { s.connections += 1 }
            return s.connections % 2 == 0 ? .mic : .call
        }
        return MeteredConnection(inner: try await inner.connect(url: url, headers: headers), stream: stream, owner: self)
    }

    var now: Double { clock.now() - lock.withLock { origin } }

    func sent(_ stream: AudioStream, _ text: String) {
        let t = now
        // Only the event type is parsed; an append's audio is measured, never kept.
        guard let data = text.data(using: .utf8), let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        lock.withLock {
            switch msg["type"] as? String ?? "" {
            case "input_audio_buffer.append":
                let pcm = Data(base64Encoded: msg["audio"] as? String ?? "") ?? Data()
                s.appends.append(.init(t: t, stream: stream, samples: pcm.count / 2, loud: ScriptedRealtime.loud(pcm)))
            case "input_audio_buffer.commit": s.commits.append((t, stream))
            case "input_audio_buffer.clear": s.clears.append((t, stream))
            default: break
            }
        }
    }

    func received(_ text: String) {
        guard text.contains("\"usage\""), let data = text.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let usage = msg["usage"] as? [String: Any], usage["type"] as? String == "duration" else { return }
        let seconds = (usage["seconds"] as? NSNumber)?.doubleValue ?? 0
        lock.withLock { s.billedSeconds += seconds }
    }

    func closed() { lock.withLock { s.closes += 1 } }
    func sendAfterClose() { lock.withLock { s.sendsAfterClose += 1 } }
}

final class MeteredConnection: WebSocketConnection, @unchecked Sendable {
    let inner: WebSocketConnection
    let stream: AudioStream
    unowned let owner: MeteredConnector
    private let lock = NSLock()
    private var isClosed = false

    init(inner: WebSocketConnection, stream: AudioStream, owner: MeteredConnector) {
        self.inner = inner
        self.stream = stream
        self.owner = owner
    }

    func send(_ text: String) async throws {
        if lock.withLock({ isClosed }) { owner.sendAfterClose() }
        owner.sent(stream, text)
        try await inner.send(text)
    }

    func receive() async throws -> String {
        let m = try await inner.receive()
        owner.received(m)
        return m
    }

    func close() {
        let first = lock.withLock { () -> Bool in
            defer { isClosed = true }
            return !isClosed
        }
        if first { owner.closed() }
        inner.close()
    }
}
