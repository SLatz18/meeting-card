import Foundation
import ListenMoreCore

/// Ephemeral URLSession configuration for OpenAI calls: no URL cache, no cookie or credential storage,
/// so nothing about a request or reply is written to disk.
public enum EphemeralSession {
    public static func configuration() -> URLSessionConfiguration {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.urlCredentialStorage = nil
        c.httpShouldSetCookies = false
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return c
    }
}

/// `HTTPTransport` over an ephemeral URLSession.
public final class URLSessionHTTPTransport: HTTPTransport, @unchecked Sendable {
    let session: URLSession

    public init(configuration: URLSessionConfiguration = EphemeralSession.configuration()) {
        session = URLSession(configuration: configuration)
    }

    static func request(url: URL, headers: [String: String], body: Data, timeout: TimeInterval) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: timeout)
        r.httpMethod = "POST"
        r.httpBody = body
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    public func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval) async throws -> (status: Int, body: Data) {
        let (data, response) = try await session.data(for: Self.request(url: url, headers: headers, body: body, timeout: timeout))
        return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
    }
}

/// `WebSocketConnector` over URLSessionWebSocketTask.
public final class URLSessionWebSocketConnector: WebSocketConnector, @unchecked Sendable {
    let session: URLSession

    public init(configuration: URLSessionConfiguration = EphemeralSession.configuration()) {
        session = URLSession(configuration: configuration)
    }

    static func request(url: URL, headers: [String: String]) -> URLRequest {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        return r
    }

    public func connect(url: URL, headers: [String: String]) async throws -> WebSocketConnection {
        let task = session.webSocketTask(with: Self.request(url: url, headers: headers))
        task.maximumMessageSize = 1 << 22
        task.resume()
        return URLSessionWebSocketConnection(task: task)
    }
}

final class URLSessionWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    private let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(_ text: String) async throws {
        try await task.send(.string(text))
    }

    func receive() async throws -> String {
        switch try await task.receive() {
        case .string(let s):
            return s
        case .data(let d):
            return String(decoding: d, as: UTF8.self)
        @unknown default:
            throw GptError.badResponse
        }
    }

    func close() {
        task.cancel(with: .normalClosure, reason: nil)
    }
}

extension GptTransports {
    /// Production transports: ephemeral URLSession for the judge and realtime transcription.
    public static func urlSession() -> GptTransports {
        GptTransports(http: URLSessionHTTPTransport(), webSocket: URLSessionWebSocketConnector())
    }
}

/// Checks a key the user typed before it is saved (GET /v1/models over an ephemeral session).
public enum KeyValidator {
    public static func check(_ text: String, session: URLSession? = nil) async -> KeyCheck {
        guard let key = APIKey(text) else { return .empty }
        do {
            let s = session ?? URLSession(configuration: EphemeralSession.configuration())
            let (_, response) = try await s.data(for: KeyCheck.request(key))
            return KeyCheck.classify(httpStatus: (response as? HTTPURLResponse)?.statusCode)
        } catch {
            return .unreachable
        }
    }
}
