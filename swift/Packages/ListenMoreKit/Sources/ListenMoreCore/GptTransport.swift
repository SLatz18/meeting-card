import Foundation

/// Network seams for the GPT layer. ListenMoreMac provides URLSession implementations (ephemeral
/// sessions: no cache, no cookies, nothing on disk); tests provide fakes.
public protocol HTTPTransport: Sendable {
    /// Returns the status code and body. Implementations must not log headers or bodies.
    func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval) async throws -> (status: Int, body: Data)
}

public protocol WebSocketConnection: AnyObject, Sendable {
    func send(_ text: String) async throws
    /// Next text message; throws when the socket closes.
    func receive() async throws -> String
    func close()
}

public protocol WebSocketConnector: Sendable {
    func connect(url: URL, headers: [String: String]) async throws -> WebSocketConnection
}

/// Wall-clock seam for the judge rate limit and the question timer.
public protocol GptScheduler: Sendable {
    func monotonic() -> TimeInterval
    func sleep(seconds: Double) async throws
}

public struct SystemGptScheduler: GptScheduler {
    public init() {}

    public func monotonic() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    public func sleep(seconds: Double) async throws {
        guard seconds > 0 else { return }
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
    }
}

/// Everything the GPT layer needs from the outside world.
public struct GptTransports: Sendable {
    public var http: HTTPTransport
    public var webSocket: WebSocketConnector
    public var scheduler: GptScheduler

    public init(http: HTTPTransport, webSocket: WebSocketConnector, scheduler: GptScheduler = SystemGptScheduler()) {
        self.http = http
        self.webSocket = webSocket
        self.scheduler = scheduler
    }
}
