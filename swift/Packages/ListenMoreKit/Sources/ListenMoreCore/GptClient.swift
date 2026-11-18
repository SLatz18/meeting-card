import Foundation

/// What the GPT layer needs from a transcription session (one per stream).
public protocol TranscriptionSession: AnyObject, Sendable {
    func start() async throws
    func sendAudio(_ pcm16: Data) async throws
    /// Commits the current audio turn; `refT` is the audio time of the turn's end (the VAD offset).
    func commit(refT: TimeInterval) async throws
    /// Drops the audio sent since the last commit: nothing is transcribed from it.
    func clear() async throws
    func close() async
}

public protocol CueJudge: Sendable {
    func judge(prompt: String) async throws -> (JudgeResult, JudgeUsage)
}

public enum TranscriptEvent: Sendable {
    case text(Speaker, String, refT: TimeInterval)
    /// Newly available text of the turn `item` (live captions only; the cue rules wait for `text`).
    case delta(Speaker, String, item: String)
    /// Billed audio seconds the API reported for one committed segment.
    case usage(Speaker, Double)
    /// The server refused this transcriber's `clear` (non-fatal: the layer keeps running).
    case clearRejected(Speaker)
    case error(String)
}

/// Port of `LiveTranscriber`: one realtime transcription WebSocket for one stream.
/// session.type = transcription, audio/pcm 24 kHz, turn_detection null (the local VAD commits turns).
public final class LiveTranscriber: TranscriptionSession, @unchecked Sendable {
    private let gpt: ListenMoreConfig.Gpt
    private let sampleRate: Int
    private let key: APIKey
    private let speaker: Speaker
    private let connector: WebSocketConnector
    private let onEvent: @Sendable (TranscriptEvent) -> Void
    private let lock = NSLock()
    private var socket: WebSocketConnection?
    private var reader: Task<Void, Never>?
    private var commitRefs: [TimeInterval] = []
    private var itemRef: [String: TimeInterval] = [:]
    /// `event_id`s of clears not yet acknowledged, oldest first: an `error` naming one is that clear's
    /// rejection, not a session failure.
    private var pendingClears: [String] = []
    private var clearCount = 0

    public init(config: ListenMoreConfig, key: APIKey, speaker: Speaker, connector: WebSocketConnector,
                onEvent: @escaping @Sendable (TranscriptEvent) -> Void) {
        gpt = config.gpt
        sampleRate = config.audio.sampleRate
        self.key = key
        self.speaker = speaker
        self.connector = connector
        self.onEvent = onEvent
    }

    public static func sessionUpdate(gpt: ListenMoreConfig.Gpt, sampleRate: Int) -> [String: Any] {
        var transcription: [String: Any] = ["model": gpt.transcribeModel]
        if let delay = gpt.transcribeDelay, !delay.isEmpty { transcription["delay"] = delay }
        return [
            "type": "session.update",
            "session": [
                "type": "transcription",
                "audio": ["input": [
                    "format": ["type": "audio/pcm", "rate": sampleRate],
                    "transcription": transcription,
                    "turn_detection": NSNull(),
                ]],
            ],
        ]
    }

    public func start() async throws {
        guard let url = URL(string: gpt.realtimeUrl) else { throw GptError.badResponse }
        let ws = try await connector.connect(url: url, headers: ["Authorization": "Bearer \(key.value)"])
        lock.withLock { socket = ws }
        try await ws.send(Self.json(Self.sessionUpdate(gpt: gpt, sampleRate: sampleRate)))
        let task = Task<Void, Never> { [weak self] in await self?.read(ws) }
        lock.withLock { reader = task }
    }

    public func sendAudio(_ pcm16: Data) async throws {
        guard let ws = lock.withLock({ socket }) else { throw GptError.notConnected }
        try await ws.send(Self.json(["type": "input_audio_buffer.append", "audio": pcm16.base64EncodedString()]))
    }

    public func commit(refT: TimeInterval) async throws {
        guard let ws = lock.withLock({ socket }) else { throw GptError.notConnected }
        lock.withLock { commitRefs.append(refT) }
        try await ws.send(Self.json(["type": "input_audio_buffer.commit"]))
    }

    public func clear() async throws {
        guard let ws = lock.withLock({ socket }) else { return }
        let id: String = lock.withLock {
            clearCount += 1
            let id = "lm_clear_\(clearCount)"
            pendingClears.append(id)
            return id
        }
        try await ws.send(Self.json(["type": "input_audio_buffer.clear", "event_id": id]))
    }

    public func close() async {
        let (ws, task) = lock.withLock { (socket, reader) }
        ws?.close()
        task?.cancel()
        lock.withLock {
            socket = nil
            reader = nil
        }
    }

    private func read(_ ws: WebSocketConnection) async {
        do {
            while !Task.isCancelled {
                let msg = try await ws.receive()
                handle(msg)
            }
        } catch {
            if !Task.isCancelled {
                let failure = CoachLog.describe(error)
                CoachLog.record(.transcriberError(speaker: speaker, model: LogToken(gpt.transcribeModel),
                                                  httpStatus: failure.httpStatus, code: failure.code))
                onEvent(.error("realtime read: \(GptError.safe(error))"))
            }
        }
    }

    func handle(_ msg: String) {
        guard let data = msg.data(using: .utf8),
              let ev = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        switch ev["type"] as? String ?? "" {
        case "input_audio_buffer.committed":
            let item = ev["item_id"] as? String ?? ""
            lock.withLock {
                let ref = commitRefs.isEmpty ? -1 : commitRefs.removeFirst()
                itemRef[item] = ref
            }
        case "conversation.item.input_audio_transcription.delta":
            let delta = ev["delta"] as? String ?? ""
            if !delta.isEmpty { onEvent(.delta(speaker, delta, item: ev["item_id"] as? String ?? "")) }
        case "conversation.item.input_audio_transcription.completed":
            let item = ev["item_id"] as? String ?? ""
            if let usage = ev["usage"] as? [String: Any], usage["type"] as? String == "duration" {
                onEvent(.usage(speaker, (usage["seconds"] as? NSNumber)?.doubleValue ?? 0))
            }
            let ref: TimeInterval = lock.withLock { itemRef.removeValue(forKey: item) ?? -1 }
            onEvent(.text(speaker, ev["transcript"] as? String ?? "", refT: ref))
        case "input_audio_buffer.cleared":
            lock.withLock { if !pendingClears.isEmpty { pendingClears.removeFirst() } }
        case "error":
            let err = ev["error"] as? [String: Any] ?? [:]
            if let id = err["event_id"] as? String,
               lock.withLock({ pendingClears.firstIndex(of: id).map { pendingClears.remove(at: $0) } }) != nil {
                onEvent(.clearRejected(speaker))
                return
            }
            let type = err["type"] as? String ?? "", code = err["code"] as? String ?? ""
            CoachLog.record(.transcriberError(speaker: speaker, model: LogToken(gpt.transcribeModel), httpStatus: nil,
                                              code: LogToken("\(type)/\(code)")))
            onEvent(.error("realtime error \(type)/\(code)"))
        default:
            break
        }
    }

    static func json(_ object: [String: Any]) throws -> String {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        guard let s = String(data: data, encoding: .utf8) else { throw GptError.badResponse }
        return s
    }
}

/// Port of `LiveJudge`: POST /v1/responses with the configured model alias, store=false and a strict
/// JSON schema. On `401 incorrect_hostname` it retries once on the regional OpenAI host the error names
/// and keeps that host for the rest of the call. The prompt and the reply stay in memory.
public final class LiveJudge: CueJudge, @unchecked Sendable {
    private let gpt: ListenMoreConfig.Gpt
    private let key: APIKey
    private let http: HTTPTransport
    private let lock = NSLock()
    private var url: String
    private var fallbackTried = false

    public init(config: ListenMoreConfig, key: APIKey, http: HTTPTransport) {
        gpt = config.gpt
        self.key = key
        self.http = http
        url = config.gpt.responsesUrl
    }

    /// The Responses URL in use (the regional one after a fallback).
    public var currentURL: String { lock.withLock { url } }

    public static func requestBody(gpt: ListenMoreConfig.Gpt, prompt: String) -> [String: Any] {
        var body: [String: Any] = [
            "model": gpt.judgeModel,
            "instructions": GptJudgeSpec.instructions,
            "input": prompt,
            "store": gpt.store,
            "max_output_tokens": 200,
            "text": ["format": ["type": "json_schema", "name": "listen_more_cue", "strict": true, "schema": GptJudgeSpec.schema]],
        ]
        if let effort = gpt.judgeReasoningEffort, !effort.isEmpty {
            body["reasoning"] = ["effort": effort]
        }
        return body
    }

    public func judge(prompt: String) async throws -> (JudgeResult, JudgeUsage) {
        let body = try JSONSerialization.data(withJSONObject: Self.requestBody(gpt: gpt, prompt: prompt))
        let (first, tried) = lock.withLock { (url, fallbackTried) }
        let (status, data) = try await post(first, body)
        if status == 200 { return try Self.parse(data) }
        guard !tried, let host = Self.regionalHost(status: status, body: data) else { throw GptError.http(status) }
        lock.withLock { fallbackTried = true }
        let firstHost = URLComponents(string: first)?.host ?? "?"
        guard let alt = Self.withHost(first, host) else { throw GptError.http(status) }
        let result: (JudgeResult, JudgeUsage)
        do {
            let (s2, d2) = try await post(alt, body)
            guard s2 == 200 else { throw GptError.http(s2) }
            result = try Self.parse(d2)
        } catch {
            throw GptError.hostRejected(first: firstHost, regional: host, inner: GptError.safe(error))
        }
        lock.withLock { url = alt }
        return result
    }

    private func post(_ urlString: String, _ body: Data) async throws -> (status: Int, body: Data) {
        guard let url = URL(string: urlString) else { throw GptError.badResponse }
        return try await http.post(url: url, headers: ["Authorization": "Bearer \(key.value)", "Content-Type": "application/json"],
                                   body: body, timeout: gpt.judgeTimeoutS)
    }

    /// The host a `401 incorrect_hostname` asks for, if it is an OpenAI API host.
    static func regionalHost(status: Int, body: Data) -> String? {
        guard status == 401,
              let root = try? JSONSerialization.jsonObject(with: body) as? [String: Any],
              let detail = root["error"] as? [String: Any],
              detail["code"] as? String == "incorrect_hostname" else { return nil }
        let message = detail["message"] as? String ?? ""
        guard let re = try? NSRegularExpression(pattern: #"\b((?:[a-z0-9-]+\.)?api\.openai\.com)\b"#, options: [.caseInsensitive]),
              let m = re.firstMatch(in: message, range: NSRange(message.startIndex..., in: message)),
              let r = Range(m.range(at: 1), in: message) else { return nil }
        return message[r].lowercased()
    }

    static func withHost(_ url: String, _ host: String) -> String? {
        guard var c = URLComponents(string: url) else { return nil }
        c.host = host
        return c.string
    }

    public static func parse(_ data: Data) throws -> (JudgeResult, JudgeUsage) {
        guard let root = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw GptError.badResponse }
        var text = ""
        for item in root["output"] as? [[String: Any]] ?? [] where item["type"] as? String == "message" {
            for c in item["content"] as? [[String: Any]] ?? [] where c["type"] as? String == "output_text" {
                text += c["text"] as? String ?? ""
            }
        }
        guard let td = text.data(using: .utf8),
              let obj = try JSONSerialization.jsonObject(with: td) as? [String: Any],
              let cue = obj["cue"] as? String else { throw GptError.badResponse }
        let result = JudgeResult(cue: cue, confidence: (obj["confidence"] as? NSNumber)?.doubleValue ?? 0,
                                 shortReason: obj["short_reason"] as? String ?? "")
        let u = root["usage"] as? [String: Any] ?? [:]
        let details = u["input_tokens_details"] as? [String: Any] ?? [:]
        let usage = JudgeUsage(inputTokens: (u["input_tokens"] as? NSNumber)?.intValue ?? 0,
                               cachedTokens: (details["cached_tokens"] as? NSNumber)?.intValue ?? 0,
                               outputTokens: (u["output_tokens"] as? NSNumber)?.intValue ?? 0)
        return (result, usage)
    }
}
