import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import ListenMoreCore
#if canImport(CHarnessTLS)
import CHarnessTLS
import Glibc
#endif

public enum PlatformWebSocket {
    /// Linux: RFC 6455 over a socket and system OpenSSL. Apple platforms: URLSessionWebSocketTask.
    public static func connector() -> WebSocketConnector {
        #if canImport(CHarnessTLS)
        return SocketWebSocketConnector()
        #else
        return URLSessionWebSocketConnector()
        #endif
    }
}

#if !canImport(CHarnessTLS)
final class URLSessionWebSocketConnector: WebSocketConnector, @unchecked Sendable {
    let session: URLSession

    init() {
        let c = URLSessionConfiguration.ephemeral
        c.urlCache = nil
        c.httpCookieStorage = nil
        c.urlCredentialStorage = nil
        session = URLSession(configuration: c)
    }

    func connect(url: URL, headers: [String: String]) async throws -> WebSocketConnection {
        var r = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        for (k, v) in headers { r.setValue(v, forHTTPHeaderField: k) }
        let task = session.webSocketTask(with: r)
        task.maximumMessageSize = 1 << 22
        task.resume()
        return URLSessionWebSocketConnection(task: task)
    }
}

final class URLSessionWebSocketConnection: WebSocketConnection, @unchecked Sendable {
    let task: URLSessionWebSocketTask

    init(task: URLSessionWebSocketTask) {
        self.task = task
    }

    func send(_ text: String) async throws { try await task.send(.string(text)) }

    func receive() async throws -> String {
        switch try await task.receive() {
        case .string(let s): return s
        case .data(let d): return String(decoding: d, as: UTF8.self)
        @unknown default: throw GptError.badResponse
        }
    }

    func close() { task.cancel(with: .normalClosure, reason: nil) }
}
#endif

#if canImport(CHarnessTLS)
public final class SocketWebSocketConnector: WebSocketConnector, @unchecked Sendable {
    public init() {}

    public func connect(url: URL, headers: [String: String]) async throws -> WebSocketConnection {
        try await withCheckedThrowingContinuation { c in
            DispatchQueue.global().async {
                do { c.resume(returning: try SocketWebSocket.open(url: url, headers: headers)) } catch { c.resume(throwing: error) }
            }
        }
    }
}

/// One client WebSocket over a TCP socket, TLS (OpenSSL, peer and host name verified) for wss.
/// Concurrency: one reader thread; writes go through a serial queue; every OpenSSL call on the
/// connection happens under `ioLock`, with the socket non-blocking so no call holds the lock while
/// waiting for the network (waits are `poll` outside the lock). Errors carry status codes and error
/// classes only: never headers, bodies or the key.
final class SocketWebSocket: WebSocketConnection, @unchecked Sendable {
    private let fd: Int32
    private let ctx: OpaquePointer?
    private let ssl: OpaquePointer?
    private let ioLock = NSLock()
    private let stateLock = NSLock()
    private let writes = DispatchQueue(label: "lm-harness.ws.write")
    private var parser = WebSocketCodec.Parser()
    private var assembler = WebSocketCodec.Assembler()
    private var inbox: [String] = []
    private var waiters: [CheckedContinuation<String, Error>] = []
    private var closed = false
    private var failure: Error?

    private init(fd: Int32, ctx: OpaquePointer?, ssl: OpaquePointer?, leftover: [UInt8]) {
        self.fd = fd
        self.ctx = ctx
        self.ssl = ssl
        parser.push(leftover)
    }

    static func open(url: URL, headers: [String: String], timeout: Int = 10) throws -> SocketWebSocket {
        guard let scheme = url.scheme, scheme == "wss" || scheme == "ws", let host = url.host else {
            throw HarnessError.webSocket("unsupported URL")
        }
        let port = url.port ?? (scheme == "wss" ? 443 : 80)
        let fd = try connectTCP(host: host, port: port, timeout: timeout)
        var ctx: OpaquePointer?
        var ssl: OpaquePointer?
        func fail(_ m: String) -> Error {
            if let ssl { SSL_free(ssl) }
            if let ctx { SSL_CTX_free(ctx) }
            Glibc.close(fd)
            return HarnessError.webSocket(m)
        }
        if scheme == "wss" {
            ctx = SSL_CTX_new(TLS_client_method())
            guard let ctx else { throw fail("TLS context") }
            SSL_CTX_set_verify(ctx, SSL_VERIFY_PEER, nil)
            guard SSL_CTX_set_default_verify_paths(ctx) == 1, lm_tls_min_tls12(ctx) == 1 else { throw fail("TLS setup") }
            ssl = SSL_new(ctx)
            guard let ssl else { throw fail("TLS session") }
            _ = lm_tls_set_partial_writes(ssl)
            guard lm_tls_set_sni(ssl, host) == 1, SSL_set1_host(ssl, host) == 1, SSL_set_fd(ssl, fd) == 1 else { throw fail("TLS host") }
            if SSL_connect(ssl) != 1 {
                let verify = SSL_get_verify_result(ssl)
                throw fail("TLS handshake failed (verify result \(verify))")
            }
        }
        let key = WebSocketCodec.clientKey()
        let request = Array(WebSocketCodec.handshake(url: url, headers: headers, key: key).utf8)
        guard blockingWrite(fd: fd, ssl: ssl, request) else { throw fail("handshake send") }
        var got: [UInt8] = []
        var response: WebSocketCodec.HandshakeResponse?
        var buf = [UInt8](repeating: 0, count: 4096)
        while response == nil {
            let n = blockingRead(fd: fd, ssl: ssl, &buf)
            guard n > 0 else { throw fail("handshake read") }
            got += buf[0..<n]
            guard got.count < 65536 else { throw fail("handshake too large") }
            response = WebSocketCodec.parseResponse(got)
        }
        guard let r = response, r.status == 101 else { throw fail("handshake HTTP \(response?.status ?? 0)") }
        guard r.headers["sec-websocket-accept"] == WebSocketCodec.accept(for: key) else { throw fail("handshake accept mismatch") }
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
        let ws = SocketWebSocket(fd: fd, ctx: ctx, ssl: ssl, leftover: r.rest)
        let reader = Thread { ws.readLoop() }
        reader.name = "lm-harness.ws.read"
        reader.start()
        return ws
    }

    // MARK: WebSocketConnection

    func send(_ text: String) async throws {
        try await write(WebSocketCodec.encode(.text, Array(text.utf8), mask: WebSocketCodec.randomMask()))
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { c in
            stateLock.lock()
            if !inbox.isEmpty {
                let m = inbox.removeFirst()
                stateLock.unlock()
                c.resume(returning: m)
            } else if closed {
                let e = failure ?? GptError.notConnected
                stateLock.unlock()
                c.resume(throwing: e)
            } else {
                waiters.append(c)
                stateLock.unlock()
            }
        }
    }

    func close() {
        guard markClosed(nil) else { return }
        let frame = WebSocketCodec.encode(.close, [0x03, 0xE8], mask: WebSocketCodec.randomMask())
        writes.async { [self] in
            _ = writeAll(frame)
            shutdown(fd, Int32(SHUT_RDWR))
        }
    }

    // MARK: reading

    private func readLoop() {
        var buf = [UInt8](repeating: 0, count: 16384)
        while !isClosed {
            let n = rawRead(&buf)
            if n > 0 {
                parser.push(Array(buf[0..<n]))
                drainFrames()
            } else if n == 0 {
                var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                _ = poll(&p, 1, 100)
            } else {
                _ = markClosed(HarnessError.webSocket("connection closed"))
            }
        }
        writes.sync {}
        ioLock.lock()
        if let ssl { SSL_free(ssl) }
        if let ctx { SSL_CTX_free(ctx) }
        Glibc.close(fd)
        ioLock.unlock()
    }

    private func drainFrames() {
        while true {
            let frame: WebSocketCodec.Frame?
            do { frame = try parser.next() } catch {
                _ = markClosed(HarnessError.webSocket("frame too large"))
                return
            }
            guard let frame, let event = assembler.feed(frame) else {
                if frame == nil { return }
                continue
            }
            switch event {
            case .text(let s): deliver(s)
            case .binary(let b): deliver(String(decoding: b, as: UTF8.self))
            case .ping(let payload):
                let pong = WebSocketCodec.encode(.pong, payload, mask: WebSocketCodec.randomMask())
                writes.async { [self] in _ = writeAll(pong) }
            case .pong: break
            case .close(let code):
                _ = markClosed(HarnessError.webSocket("closed by server (\(code.map(String.init) ?? "no code"))"))
                return
            }
        }
    }

    private func deliver(_ s: String) {
        stateLock.lock()
        if let w = waiters.first {
            waiters.removeFirst()
            stateLock.unlock()
            w.resume(returning: s)
        } else {
            inbox.append(s)
            stateLock.unlock()
        }
    }

    private var isClosed: Bool { stateLock.withLock { closed } }

    /// First close wins; pending receivers get the error. Returns false if already closed.
    private func markClosed(_ error: Error?) -> Bool {
        let ws = stateLock.withLock { () -> [CheckedContinuation<String, Error>]? in
            guard !closed else { return nil }
            closed = true
            failure = error
            defer { waiters.removeAll() }
            return waiters
        }
        guard let ws else { return false }
        ws.forEach { $0.resume(throwing: error ?? GptError.notConnected) }
        return true
    }

    // MARK: raw I/O (non-blocking)

    /// > 0 bytes read, 0 would block, < 0 closed or failed.
    private func rawRead(_ buf: inout [UInt8]) -> Int {
        ioLock.lock()
        defer { ioLock.unlock() }
        if let ssl {
            let n = buf.withUnsafeMutableBytes { SSL_read(ssl, $0.baseAddress, Int32($0.count)) }
            if n > 0 { return Int(n) }
            let e = SSL_get_error(ssl, n)
            return e == SSL_ERROR_WANT_READ || e == SSL_ERROR_WANT_WRITE ? 0 : -1
        }
        let n = buf.withUnsafeMutableBytes { Glibc.read(fd, $0.baseAddress, $0.count) }
        if n > 0 { return n }
        if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) { return 0 }
        return -1
    }

    private func write(_ bytes: [UInt8]) async throws {
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
            writes.async { [self] in
                if isClosed {
                    c.resume(throwing: GptError.notConnected)
                } else if writeAll(bytes) {
                    c.resume()
                } else {
                    _ = markClosed(HarnessError.webSocket("send failed"))
                    c.resume(throwing: GptError.notConnected)
                }
            }
        }
    }

    /// On the write queue only. Takes the I/O lock per attempt and waits for the socket outside it.
    private func writeAll(_ bytes: [UInt8]) -> Bool {
        var off = 0
        var waits = 0
        while off < bytes.count {
            ioLock.lock()
            var wantRead = false
            let n: Int = bytes.withUnsafeBytes { raw in
                let p = raw.baseAddress!.advanced(by: off)
                let left = raw.count - off
                if let ssl {
                    let r = SSL_write(ssl, p, Int32(left))
                    if r > 0 { return Int(r) }
                    let e = SSL_get_error(ssl, r)
                    wantRead = e == SSL_ERROR_WANT_READ
                    return e == SSL_ERROR_WANT_READ || e == SSL_ERROR_WANT_WRITE ? 0 : -1
                }
                let r = Glibc.write(fd, p, left)
                if r > 0 { return r }
                return r < 0 && (errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR) ? 0 : -1
            }
            ioLock.unlock()
            if n < 0 { return false }
            if n > 0 {
                off += n
                waits = 0
                continue
            }
            waits += 1
            if waits > 300 { return false }
            var p = pollfd(fd: fd, events: Int16(wantRead ? POLLIN : POLLOUT), revents: 0)
            _ = poll(&p, 1, 100)
        }
        return true
    }

    // MARK: connect and handshake (blocking, with socket timeouts)

    private static func connectTCP(host: String, port: Int, timeout: Int) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let first = res else { throw HarnessError.webSocket("DNS lookup failed") }
        defer { freeaddrinfo(first) }
        var ai: UnsafeMutablePointer<addrinfo>? = first
        while let a = ai {
            let fd = socket(a.pointee.ai_family, a.pointee.ai_socktype, a.pointee.ai_protocol)
            if fd >= 0 {
                var tv = timeval(tv_sec: timeout, tv_usec: 0)
                _ = setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                _ = setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
                var one: Int32 = 1
                _ = setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &one, socklen_t(MemoryLayout<Int32>.size))
                if Glibc.connect(fd, a.pointee.ai_addr, a.pointee.ai_addrlen) == 0 { return fd }
                Glibc.close(fd)
            }
            ai = a.pointee.ai_next
        }
        throw HarnessError.webSocket("connect failed")
    }

    private static func blockingWrite(fd: Int32, ssl: OpaquePointer?, _ bytes: [UInt8]) -> Bool {
        var off = 0
        while off < bytes.count {
            let n: Int = bytes.withUnsafeBytes { raw in
                let p = raw.baseAddress!.advanced(by: off)
                if let ssl { return Int(SSL_write(ssl, p, Int32(raw.count - off))) }
                return Glibc.write(fd, p, raw.count - off)
            }
            guard n > 0 else { return false }
            off += n
        }
        return true
    }

    private static func blockingRead(fd: Int32, ssl: OpaquePointer?, _ buf: inout [UInt8]) -> Int {
        buf.withUnsafeMutableBytes { raw in
            if let ssl { return Int(SSL_read(ssl, raw.baseAddress, Int32(raw.count))) }
            return Glibc.read(fd, raw.baseAddress, raw.count)
        }
    }
}
#endif
