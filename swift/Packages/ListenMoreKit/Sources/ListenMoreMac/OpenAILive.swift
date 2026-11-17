import Foundation
import ListenMoreCore

/// Ephemeral sessions only: no URL cache, cookie store or credential storage on disk.
enum OpenAISession {
    static func make() -> URLSession {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.urlCredentialStorage = nil
        c.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        return URLSession(configuration: c)
    }
}

/// The realtime WebSocket, narrowed to what the transcriber uses (tests count frames on a fake).
protocol RealtimeSocket: AnyObject {
    func resume()
    func send(_ text: String, completion: @escaping (Error?) -> Void)
    func receive(_ completion: @escaping (Result<Data, Error>) -> Void)
    func cancel()
}

typealias RealtimeSocketFactory = (URLRequest) -> RealtimeSocket

final class URLSessionRealtimeSocket: RealtimeSocket {
    private let task: URLSessionWebSocketTask

    init(_ task: URLSessionWebSocketTask) { self.task = task }

    static func factory(session: URLSession = OpenAISession.make()) -> RealtimeSocketFactory {
        { URLSessionRealtimeSocket(session.webSocketTask(with: $0)) }
    }

    func resume() { task.resume() }

    func send(_ text: String, completion: @escaping (Error?) -> Void) {
        task.send(.string(text), completionHandler: completion)
    }

    func receive(_ completion: @escaping (Result<Data, Error>) -> Void) {
        task.receive { result in
            completion(result.map { message in
                switch message {
                case .string(let s): Data(s.utf8)
                case .data(let d): d
                @unknown default: Data()
                }
            })
        }
    }

    func cancel() { task.cancel(with: .normalClosure, reason: nil) }
}

/// One realtime transcription session (WebSocket) for one stream. Turns are committed by the
/// client at the local VAD offset; the server's transcript for a committed item is matched back to
/// that turn's audio time. Errors are reported once, as a kind only.
final class RealtimeTranscriber: Transcriber {
    private let config: ListenMoreConfig
    private let key: APIKey
    private let makeSocket: RealtimeSocketFactory
    private let lock = NSLock()
    private var task: RealtimeSocket?
    private var onText: ((String, Double?) -> Void)?
    private var onError: ((GptError) -> Void)?
    private var pendingRefs: [Double] = []
    private var refByItem: [String: Double] = [:]
    private var audioSeconds = 0.0
    private var failed = false
    private var closed = false

    init(config: ListenMoreConfig, key: APIKey, makeSocket: @escaping RealtimeSocketFactory = URLSessionRealtimeSocket.factory()) {
        self.config = config
        self.key = key
        self.makeSocket = makeSocket
    }

    var reportedAudioSeconds: Double {
        lock.lock(); defer { lock.unlock() }
        return audioSeconds
    }

    func start(onText: @escaping (String, Double?) -> Void, onError: @escaping (GptError) -> Void) {
        guard let url = URL(string: config.gpt.realtimeUrl) else {
            onError(GptError(.realtimeConnect))
            return
        }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(key.value)", forHTTPHeaderField: "Authorization")
        let task = makeSocket(req)
        lock.lock()
        self.onText = onText
        self.onError = onError
        self.task = task
        lock.unlock()
        task.resume()
        send(OpenAIWire.sessionUpdate(config.gpt, sampleRate: config.audio.sampleRate), kind: .realtimeConnect)
        receive()
    }

    func sendAudio(_ pcm16: Data) {
        send(OpenAIWire.appendAudio(pcm16), kind: .realtimeSend)
    }

    func commit(refT: Double) {
        lock.lock()
        pendingRefs.append(refT)
        lock.unlock()
        send(OpenAIWire.commit(), kind: .realtimeSend)
    }

    func close() {
        lock.lock()
        closed = true
        let t = task
        task = nil
        onText = nil
        onError = nil
        pendingRefs = []
        refByItem = [:]
        lock.unlock()
        t?.cancel()
    }

    private func send(_ data: Data, kind: GptErrorKind) {
        lock.lock()
        let t = closed || failed ? nil : task
        lock.unlock()
        guard let t, let text = String(data: data, encoding: .utf8) else { return }
        t.send(text) { [weak self] error in
            if error != nil { self?.fail(kind) }
        }
    }

    private func receive() {
        lock.lock()
        let t = closed ? nil : task
        lock.unlock()
        t?.receive { [weak self] result in
            guard let self else { return }
            switch result {
            case .failure:
                self.fail(.realtimeRead)
            case .success(let data):
                self.handle(OpenAIWire.parseRealtime(data))
                self.receive()
            }
        }
    }

    private func handle(_ ev: OpenAIWire.RealtimeEvent) {
        lock.lock()
        switch ev {
        case .committed(let item):
            if !pendingRefs.isEmpty { refByItem[item] = pendingRefs.removeFirst() }
            lock.unlock()
        case .transcript(let item, let text, let secs):
            let ref = refByItem.removeValue(forKey: item)
            audioSeconds += secs ?? 0
            let cb = closed ? nil : onText
            lock.unlock()
            cb?(text, ref)
        case .error:
            lock.unlock()
            fail(.realtimeServer)
        case .other:
            lock.unlock()
        }
    }

    private func fail(_ kind: GptErrorKind) {
        lock.lock()
        guard !closed, !failed else { lock.unlock(); return }
        failed = true
        let cb = onError
        lock.unlock()
        cb?(GptError(kind))
    }
}

/// The judge: one Responses API call per request, `store: false`, strict JSON schema.
final class ResponsesJudge: Judge {
    private let config: ListenMoreConfig
    private let key: APIKey
    private let session: URLSession

    init(config: ListenMoreConfig, key: APIKey, session: URLSession = OpenAISession.make()) {
        self.config = config
        self.key = key
        self.session = session
    }

    func judge(prompt: String, completion: @escaping (Result<(JudgeResult, JudgeUsage), GptError>) -> Void) {
        guard let url = URL(string: config.gpt.responsesUrl) else {
            completion(.failure(GptError(.judgeTransport)))
            return
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: config.gpt.judgeTimeoutS)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key.value)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = OpenAIWire.judgeBody(config.gpt, prompt: prompt)
        session.dataTask(with: req) { data, response, error in
            if let error = error as? URLError {
                completion(.failure(GptError(error.code == .timedOut ? .judgeTimeout : .judgeTransport)))
                return
            }
            guard error == nil, let http = response as? HTTPURLResponse, let data else {
                completion(.failure(GptError(.judgeTransport)))
                return
            }
            guard http.statusCode == 200 else {
                completion(.failure(GptError(.judgeHTTP, httpStatus: http.statusCode)))
                return
            }
            do { completion(.success(try OpenAIWire.parseJudge(data))) } catch let e as GptError {
                completion(.failure(e))
            } catch {
                completion(.failure(GptError(.judgeDecode)))
            }
        }.resume()
    }
}

/// Live OpenAI transports for `LocalCoachEngine`.
public final class OpenAITransport: GptTransportFactory {
    private let makeSocket: RealtimeSocketFactory?
    private let makeJudge: ((ListenMoreConfig, APIKey) -> Judge)?

    public init() {
        makeSocket = nil
        makeJudge = nil
    }

    init(makeSocket: @escaping RealtimeSocketFactory, makeJudge: ((ListenMoreConfig, APIKey) -> Judge)? = nil) {
        self.makeSocket = makeSocket
        self.makeJudge = makeJudge
    }

    public func transcriber(config: ListenMoreConfig, key: APIKey, speaker: Speaker) -> Transcriber {
        if let makeSocket { return RealtimeTranscriber(config: config, key: key, makeSocket: makeSocket) }
        return RealtimeTranscriber(config: config, key: key)
    }

    public func judge(config: ListenMoreConfig, key: APIKey) -> Judge {
        makeJudge?(config, key) ?? ResponsesJudge(config: config, key: key)
    }
}

/// Checks a key with GET /v1/models before the coach is switched on. Reads only the status code.
public enum KeyValidator {
    public static func check(_ text: String, session: URLSession = OpenAISession.make()) async -> KeyCheck {
        guard let key = APIKey(text) else { return .empty }
        do {
            let (_, response) = try await session.data(for: KeyCheck.request(key))
            return KeyCheck.classify(httpStatus: (response as? HTTPURLResponse)?.statusCode)
        } catch {
            return .unreachable
        }
    }
}
