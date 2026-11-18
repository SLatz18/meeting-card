import XCTest
import ListenMoreCore
@testable import ListenMoreHarness
#if canImport(Glibc)
import Glibc
#endif

#if canImport(CHarnessTLS)
/// The Linux socket client's teardown order. The reader thread frees the TLS session and closes the
/// descriptor once it sees the connection closed and the write queue drained, so nothing may be written,
/// shut down or answered with a pong after that, nor after the close frame and `shutdown`.
///
/// Each test holds one decision point open through `SocketHooks` until the other thread has run, so the
/// interleaving is fixed rather than left to timing:
///  - `closeGap`: `close()` after its state change, before the close write is queued. With the old
///    `close()` (marks the connection closed first) the reader releases the socket in this gap and the
///    close write then runs on a released socket. With the current `close()` the connection is not
///    closed yet, so the reader cannot release, and the hook waits out its timeout.
///  - `beforeCloseWrite`: the queued close write held until the reader has queued a pong behind it. The
///    pong must then be dropped, not written after the close frame and the shutdown.
final class SocketTeardownOrderTests: XCTestCase {
    typealias Event = SocketHooks.Event

    override class func setUp() {
        super.setUp()
        _ = SocketWebSocketConnector()
    }

    final class Trace: @unchecked Sendable {
        private let lock = NSLock()
        private var recorded: [Event] = []

        func record(_ e: Event) { lock.withLock { recorded.append(e) } }
        var events: [Event] { lock.withLock { recorded } }

        @discardableResult
        func wait(for e: Event, timeout: TimeInterval) -> Bool {
            let deadline = Date().addingTimeInterval(timeout)
            while Date() < deadline {
                if events.contains(e) { return true }
                usleep(2000)
            }
            return events.contains(e)
        }
    }

    /// A loopback ws server that completes the handshake, sends what a test asks for, and records the
    /// opcode of every frame the client sends after the handshake.
    final class ScriptedPeer: @unchecked Sendable {
        let listener: Int32
        let port: UInt16
        private let lock = NSLock()
        private var conn: Int32 = -1
        private var opcodes: [UInt8] = []
        private var finished = false

        init() throws {
            let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
            listen(fd, 1)
            _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
            listener = fd
            port = UInt16(bigEndian: addr.sin_port)
            Thread { self.serve() }.start()
        }

        deinit { close(listener) }

        var url: URL { URL(string: "ws://127.0.0.1:\(port)/v1/realtime")! }
        var received: [UInt8] { lock.withLock { opcodes } }
        var isFinished: Bool { lock.withLock { finished } }

        func send(opcode: UInt8, _ payload: [UInt8]) {
            let fd = lock.withLock { conn }
            let bytes = SocketWebSocketLoopbackTests.EchoServer.serverFrame(opcode, payload)
            var off = 0
            while fd >= 0 && off < bytes.count {
                let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: off), $0.count - off) }
                if n <= 0 { return }
                off += n
            }
        }

        private func serve() {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            defer {
                close(fd)
                lock.withLock { finished = true }
            }
            var buf = [UInt8](repeating: 0, count: 65536)
            func readSome() -> [UInt8] {
                let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                return n > 0 ? Array(buf[0..<n]) : []
            }
            var got: [UInt8] = []
            var request: WebSocketCodec.HandshakeResponse?
            while request == nil {
                let chunk = readSome()
                if chunk.isEmpty { return }
                got += chunk
                request = WebSocketCodec.parseResponse(got)
            }
            let key = request?.headers["sec-websocket-key"] ?? ""
            let reply = Array("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(WebSocketCodec.accept(for: key))\r\n\r\n".utf8)
            _ = reply.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            lock.withLock { conn = fd }
            var parser = WebSocketCodec.Parser()
            parser.push(request?.rest ?? [])
            while true {
                while let f = try? parser.next() { lock.withLock { opcodes.append(f.opcode) } }
                let chunk = readSome()
                if chunk.isEmpty { return }
                parser.push(chunk)
            }
        }
    }

    func open(_ peer: ScriptedPeer, _ hooks: SocketHooks) throws -> SocketWebSocket {
        try SocketWebSocket.open(url: peer.url, headers: [:], timeout: 5, hooks: hooks)
    }

    /// The close write is queued before the reader can see the connection closed: the socket is
    /// released only after the close frame went out and the socket was shut down.
    func testReaderReleasesOnlyAfterTheCloseFrameAndShutdown() throws {
        let peer = try ScriptedPeer()
        let trace = Trace()
        let hooks = SocketHooks()
        hooks.event = { trace.record($0) }
        hooks.closeGap = { _ = trace.wait(for: .released, timeout: 0.75) }
        let ws = try open(peer, hooks)
        ws.close()
        XCTAssertTrue(trace.wait(for: .released, timeout: 5), "the reader released the socket: \(trace.events)")
        XCTAssertTrue(trace.wait(for: .shutdown, timeout: 5), "the close path shut the socket down: \(trace.events)")
        usleep(100_000)
        XCTAssertEqual(trace.events, [.wrote(.close), .shutdown, .released],
                       "nothing may touch the socket after the reader released it")
        let deadline = Date().addingTimeInterval(3)
        while !peer.isFinished && Date() < deadline { usleep(5000) }
        XCTAssertEqual(peer.received, [WebSocketCodec.Opcode.close.rawValue], "the server got the close frame")
    }

    /// A ping that arrives after close() was requested, while the close write is still waiting its
    /// turn, is not answered: no pong after the close frame or the shutdown.
    func testNoPongAfterCloseWasRequested() throws {
        let peer = try ScriptedPeer()
        let trace = Trace()
        let hooks = SocketHooks()
        hooks.event = { trace.record($0) }
        hooks.beforeCloseWrite = { _ = trace.wait(for: .pongQueued, timeout: 5) }
        let ws = try open(peer, hooks)
        ws.close()
        peer.send(opcode: 0x9, [7])
        XCTAssertTrue(trace.wait(for: .released, timeout: 5), "the reader released the socket: \(trace.events)")
        usleep(100_000)
        XCTAssertEqual(trace.events, [.pongQueued, .wrote(.close), .shutdown, .released],
                       "the queued pong is dropped once the connection is closing")
        let deadline = Date().addingTimeInterval(3)
        while !peer.isFinished && Date() < deadline { usleep(5000) }
        XCTAssertEqual(peer.received, [WebSocketCodec.Opcode.close.rawValue], "the server saw the close frame and no pong")
    }

    /// The server closed first: the reader released the socket on its own, and a later close() writes and
    /// shuts down nothing.
    func testCloseAfterTheServerClosedTouchesNothing() throws {
        let peer = try ScriptedPeer()
        let trace = Trace()
        let hooks = SocketHooks()
        hooks.event = { trace.record($0) }
        let ws = try open(peer, hooks)
        peer.send(opcode: 0x8, [0x03, 0xE8])
        XCTAssertTrue(trace.wait(for: .released, timeout: 5), "the reader released the socket: \(trace.events)")
        ws.close()
        ws.close()
        usleep(200_000)
        XCTAssertEqual(trace.events, [.released], "close() after the server's close frame does no I/O")
    }
}
#endif
