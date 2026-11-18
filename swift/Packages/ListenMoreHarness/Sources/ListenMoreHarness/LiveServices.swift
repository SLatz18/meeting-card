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
        LiveBackend(http: EphemeralHTTPTransport.shared, webSocket: PlatformWebSocket.connector())
    }
}

/// `HTTPTransport` over an ephemeral URLSession: no cache, cookies or credential storage on disk.
/// One session for the whole process, never torn down: on Linux, FoundationNetworking with libcurl
/// 8.11 or newer aborts when a URLSession's curl multi handle is released ("_MultiHandle deallocated
/// with non-zero retain count", swift-corelibs-foundation #5203), so live mode never releases one.
public final class EphemeralHTTPTransport: HTTPTransport, @unchecked Sendable {
    public static let shared = EphemeralHTTPTransport()
    let session: URLSession

    private init() {
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
    let clock: HarnessClock?
    private let lock = NSLock()
    private var _calls = 0
    private var _inputTokens = 0
    private var _outputTokens = 0
    private var _failures: [String] = []
    private var _hostRedirects = 0
    private var _cancelled: [Double] = []
    private var _selfPivotInputTokens = 0
    private var _selfPivotOutputTokens = 0
    /// Requests per judge, and any without `store: false` (read from the body's schema name and store flag only).
    public let traffic = JudgeTraffic()

    public init(inner: HTTPTransport, clock: HarnessClock? = nil) {
        self.inner = inner
        self.clock = clock
    }

    /// Run-clock times of calls cancelled in flight (the GPT layer cancels its judge task when the engine
    /// stops: Pause, the call app's mute, the end of the call). Not failures.
    public var cancelled: [Double] { lock.withLock { _cancelled } }

    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || (error as? URLError)?.code == .cancelled
    }

    public var calls: Int { lock.withLock { _calls } }
    public var tokens: (input: Int, output: Int) { lock.withLock { (_inputTokens, _outputTokens) } }
    /// The self-pivot judge's share of `tokens`.
    public var selfPivotTokens: (input: Int, output: Int) { lock.withLock { (_selfPivotInputTokens, _selfPivotOutputTokens) } }
    /// One class per failed call: `HTTP <status> <error code>` or the thrown error's type (a timeout
    /// shows as its URLError code). Never a body, header or message text.
    public var failures: [String] { lock.withLock { _failures } }
    /// `401 incorrect_hostname`: the configured host named the key's regional host and the judge retried
    /// there (once per process; the learned host is kept). Not failures.
    public var hostRedirects: Int { lock.withLock { _hostRedirects } }

    public func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval) async throws -> (status: Int, body: Data) {
        let facts = traffic.record(body)
        let reply: (status: Int, body: Data)
        do {
            reply = try await inner.post(url: url, headers: headers, body: body, timeout: timeout)
        } catch {
            let t = clock?.now() ?? 0
            lock.withLock {
                _calls += 1
                if Self.isCancellation(error) { _cancelled.append(t) } else { _failures.append(GptError.safe(error)) }
            }
            throw error
        }
        let root = (try? JSONSerialization.jsonObject(with: reply.body)) as? [String: Any]
        let usage = root?["usage"] as? [String: Any]
        lock.withLock {
            _calls += 1
            if reply.status != 200 {
                let failure = Self.failureClass(status: reply.status, root: root)
                if failure == Self.hostRedirect { _hostRedirects += 1 } else { _failures.append(failure) }
            }
            let input = (usage?["input_tokens"] as? NSNumber)?.intValue ?? 0
            let output = (usage?["output_tokens"] as? NSNumber)?.intValue ?? 0
            _inputTokens += input
            _outputTokens += output
            if facts.selfPivot {
                _selfPivotInputTokens += input
                _selfPivotOutputTokens += output
            }
        }
        return reply
    }

    static let hostRedirect = "HTTP 401 incorrect_hostname"

    /// `HTTP 401 incorrect_hostname`: the status and OpenAI's error code (a fixed identifier), if any.
    static func failureClass(status: Int, root: [String: Any]?) -> String {
        let code = (root?["error"] as? [String: Any])?["code"] as? String
        let safe = code.flatMap { $0.range(of: #"^[a-z0-9_]{1,40}$"#, options: .regularExpression) != nil ? $0 : nil }
        return "HTTP \(status)" + (safe.map { " \($0)" } ?? "")
    }
}

/// Wraps the realtime connector to observe traffic: appends per stream with times, commits, clears,
/// closes, billed seconds from `completed` usage, and each segment's commit and transcript times with
/// its (synthetic) transcript for scoring, in memory. No audio is kept.
public final class MeteredConnector: WebSocketConnector, SocketObserver, @unchecked Sendable {
    let inner: WebSocketConnector
    let clock: HarnessClock
    private let lock = NSLock()
    private var origin = 0.0
    private var s = SocketStats()
    private var pairing: [Int: SegmentPairing] = [:]

    public init(inner: WebSocketConnector, clock: HarnessClock) {
        self.inner = inner
        self.clock = clock
    }

    public func setOrigin(_ origin: Double) { lock.withLock { self.origin = origin } }
    public func stats() -> SocketStats { lock.withLock { s } }

    public func connect(url: URL, headers: [String: String]) async throws -> WebSocketConnection {
        let (stream, id): (AudioStream, Int) = lock.withLock {
            defer { s.connections += 1 }
            return (s.connections % 2 == 0 ? .mic : .call, s.connections)
        }
        return MeteredConnection(inner: try await inner.connect(url: url, headers: headers), stream: stream, id: id, owner: self)
    }

    var now: Double { clock.now() - lock.withLock { origin } }

    func sent(_ stream: AudioStream, id: Int, _ text: String) {
        let t = now
        // Only the event type is parsed; an append's audio is measured, never kept.
        guard let data = text.data(using: .utf8), let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        lock.withLock {
            switch msg["type"] as? String ?? "" {
            case "input_audio_buffer.append":
                let pcm = Data(base64Encoded: msg["audio"] as? String ?? "") ?? Data()
                s.appends.append(.init(t: t, stream: stream, samples: pcm.count / 2, loud: ScriptedRealtime.loud(pcm)))
            case "input_audio_buffer.commit":
                s.commits.append((t, stream))
                pairing[id, default: SegmentPairing()].commitSent(at: t)
            case "input_audio_buffer.clear": s.clears.append((t, stream))
            default: break
            }
        }
    }

    func received(_ stream: AudioStream, id: Int, _ text: String) {
        let t = now
        guard text.contains("input_audio_buffer.committed") || text.contains("transcription.completed"),
              let data = text.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let item = msg["item_id"] as? String ?? ""
        lock.withLock {
            switch msg["type"] as? String ?? "" {
            case "input_audio_buffer.committed":
                pairing[id, default: SegmentPairing()].acknowledged(item: item)
            case "conversation.item.input_audio_transcription.completed":
                if let usage = msg["usage"] as? [String: Any], usage["type"] as? String == "duration" {
                    s.billedSeconds += (usage["seconds"] as? NSNumber)?.doubleValue ?? 0
                }
                if let committed = pairing[id]?.completed(item: item) {
                    s.segments.append(TranscribedSegment(stream: stream, committedAt: committed, transcribedAt: t,
                                                         text: msg["transcript"] as? String ?? ""))
                }
            default: break
            }
        }
    }

    func closed() { lock.withLock { s.closes += 1 } }
    func sendAfterClose() { lock.withLock { s.sendsAfterClose += 1 } }
}

final class MeteredConnection: WebSocketConnection, @unchecked Sendable {
    let inner: WebSocketConnection
    let stream: AudioStream
    let id: Int
    unowned let owner: MeteredConnector
    private let lock = NSLock()
    private var isClosed = false

    init(inner: WebSocketConnection, stream: AudioStream, id: Int, owner: MeteredConnector) {
        self.inner = inner
        self.stream = stream
        self.id = id
        self.owner = owner
    }

    func send(_ text: String) async throws {
        if lock.withLock({ isClosed }) { owner.sendAfterClose() }
        owner.sent(stream, id: id, text)
        try await inner.send(text)
    }

    func receive() async throws -> String {
        let m = try await inner.receive()
        owner.received(stream, id: id, m)
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
