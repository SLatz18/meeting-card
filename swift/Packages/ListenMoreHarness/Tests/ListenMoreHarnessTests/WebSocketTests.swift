import XCTest
import ListenMoreCore
@testable import ListenMoreHarness
#if canImport(Glibc)
import Glibc
#endif

final class WebSocketCodecTests: XCTestCase {
    func testHandshakeAcceptMatchesTheRFCExample() {
        XCTAssertEqual(WebSocketCodec.accept(for: "dGhlIHNhbXBsZSBub25jZQ=="), "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=")
    }

    func testHandshakeRequest() throws {
        let url = try XCTUnwrap(URL(string: "wss://example.invalid/v1/realtime?intent=transcription"))
        let req = WebSocketCodec.handshake(url: url, headers: ["Authorization": "Bearer x"], key: "k")
        XCTAssertTrue(req.hasPrefix("GET /v1/realtime?intent=transcription HTTP/1.1\r\nHost: example.invalid\r\n"))
        XCTAssertTrue(req.contains("Sec-WebSocket-Version: 13\r\n"))
        XCTAssertTrue(req.hasSuffix("Authorization: Bearer x\r\n\r\n"))
    }

    func testParsesResponseAndKeepsTheRest() throws {
        let bytes = Array("HTTP/1.1 101 Switching Protocols\r\nSec-WebSocket-Accept: abc\r\n\r\n".utf8) + [0x81, 0x00]
        let r = try XCTUnwrap(WebSocketCodec.parseResponse(bytes))
        XCTAssertEqual(r.status, 101)
        XCTAssertEqual(r.headers["sec-websocket-accept"], "abc")
        XCTAssertEqual(r.rest, [0x81, 0x00])
        XCTAssertNil(WebSocketCodec.parseResponse(Array("HTTP/1.1 101 OK\r\n".utf8)))
    }

    func roundTrip(_ n: Int) throws {
        let payload = (0..<n).map { UInt8($0 % 251) }
        let frame = WebSocketCodec.encode(.text, payload, mask: [1, 2, 3, 4])
        XCTAssertEqual(frame[1] & 0x80, 0x80, "client frames are masked")
        var p = WebSocketCodec.Parser()
        p.push(Array(frame.prefix(3)))
        XCTAssertNil(try p.next())
        p.push(Array(frame.dropFirst(3)))
        let f = try XCTUnwrap(try p.next())
        XCTAssertEqual(f.payload, payload)
        XCTAssertTrue(f.fin)
    }

    func testRoundTripsEveryLengthForm() throws {
        try roundTrip(0)
        try roundTrip(125)
        try roundTrip(126)
        try roundTrip(70_000)
    }

    func testAssemblerJoinsFragmentsAndPassesControlFrames() {
        var a = WebSocketCodec.Assembler()
        XCTAssertNil(a.feed(.init(fin: false, opcode: 0x1, payload: Array("hel".utf8))))
        XCTAssertEqual(a.feed(.init(fin: false, opcode: 0x9, payload: [7])), .ping([7]))
        XCTAssertEqual(a.feed(.init(fin: true, opcode: 0x0, payload: Array("lo".utf8))), .text("hello"))
        XCTAssertEqual(a.feed(.init(fin: true, opcode: 0x8, payload: [0x03, 0xE8])), .close(1000))
    }
}

#if canImport(CHarnessTLS)
/// The Linux socket client against an in-process plain-ws server on loopback: handshake (with the
/// Authorization header), echo of small and large text messages, a server ping, and close.
final class SocketWebSocketLoopbackTests: XCTestCase {
    final class EchoServer: @unchecked Sendable {
        let listener: Int32
        let port: UInt16
        private let lock = NSLock()
        private(set) var sawAuthorization = false
        private(set) var pongs = 0
        private(set) var closed = false

        init() throws {
            let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
            var one: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
            var addr = sockaddr_in()
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            addr.sin_port = 0
            var len = socklen_t(MemoryLayout<sockaddr_in>.size)
            _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, len) } }
            listen(fd, 1)
            _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
            listener = fd
            port = UInt16(bigEndian: addr.sin_port)
            Thread { self.serve() }.start()
        }

        func readSome(_ fd: Int32) -> [UInt8] {
            var buf = [UInt8](repeating: 0, count: 65536)
            let n = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            return n > 0 ? Array(buf[0..<n]) : []
        }

        func send(_ fd: Int32, _ bytes: [UInt8]) {
            var off = 0
            while off < bytes.count {
                let n = bytes.withUnsafeBytes { write(fd, $0.baseAddress!.advanced(by: off), $0.count - off) }
                if n <= 0 { return }
                off += n
            }
        }

        static func serverFrame(_ opcode: UInt8, _ payload: [UInt8]) -> [UInt8] {
            var out: [UInt8] = [0x80 | opcode]
            if payload.count < 126 {
                out.append(UInt8(payload.count))
            } else if payload.count <= 0xFFFF {
                out += [126, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
            } else {
                out.append(127)
                for s in stride(from: 56, through: 0, by: -8) { out.append(UInt8(UInt64(payload.count) >> UInt64(s) & 0xFF)) }
            }
            return out + payload
        }

        func serve() {
            let fd = accept(listener, nil, nil)
            guard fd >= 0 else { return }
            var got: [UInt8] = []
            var request: WebSocketCodec.HandshakeResponse?
            while request == nil {
                let chunk = readSome(fd)
                if chunk.isEmpty { return }
                got += chunk
                request = WebSocketCodec.parseResponse(got)
            }
            let key = request?.headers["sec-websocket-key"] ?? ""
            lock.withLock { sawAuthorization = request?.headers["authorization"] == "Bearer loopback-test" }
            send(fd, Array("HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(WebSocketCodec.accept(for: key))\r\n\r\n".utf8))
            send(fd, Self.serverFrame(0x9, [42]))
            var parser = WebSocketCodec.Parser()
            parser.push(request?.rest ?? [])
            while true {
                while let f = try? parser.next() {
                    switch f.opcode {
                    case 0x1: send(fd, Self.serverFrame(0x1, f.payload))
                    case 0xA: lock.withLock { pongs += 1 }
                    case 0x8:
                        lock.withLock { closed = true }
                        send(fd, Self.serverFrame(0x8, f.payload))
                        close(fd)
                        return
                    default: break
                    }
                }
                let chunk = readSome(fd)
                if chunk.isEmpty {
                    close(fd)
                    return
                }
                parser.push(chunk)
            }
        }

        var state: (auth: Bool, pongs: Int, closed: Bool) { lock.withLock { (sawAuthorization, pongs, closed) } }
    }

    func testEchoPingAndClose() async throws {
        let server = try EchoServer()
        defer { close(server.listener) }
        let url = try XCTUnwrap(URL(string: "ws://127.0.0.1:\(server.port)/v1/realtime?intent=transcription"))
        let ws = try await SocketWebSocketConnector().connect(url: url, headers: ["Authorization": "Bearer loopback-test"])
        try await ws.send(#"{"type":"session.update"}"#)
        let first = try await ws.receive()
        XCTAssertEqual(first, #"{"type":"session.update"}"#)
        let big = String(repeating: "a", count: 200_000)
        try await ws.send(big)
        let echoed = try await ws.receive()
        XCTAssertEqual(echoed.count, big.count)
        let deadline = Date().addingTimeInterval(3)
        while server.state.pongs == 0 && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        ws.close()
        while !server.state.closed && Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertTrue(server.state.auth, "the Authorization header reaches the server")
        XCTAssertEqual(server.state.pongs, 1, "a server ping is answered")
        XCTAssertTrue(server.state.closed, "close sends a close frame")
        do {
            try await ws.send("after close")
            XCTFail("send after close must throw")
        } catch {}
    }

    /// Opt-in (`LM_HARNESS_NETWORK_TEST=1`): TLS with peer verification against a public echo server, and
    /// OpenAI's realtime endpoint refusing an invalid key at the handshake. No real key is used.
    func testTLSOverTheNetwork() async throws {
        guard ProcessInfo.processInfo.environment["LM_HARNESS_NETWORK_TEST"] == "1" else {
            throw XCTSkip("set LM_HARNESS_NETWORK_TEST=1 to reach the network")
        }
        let echo = try await SocketWebSocketConnector().connect(url: URL(string: "wss://echo.websocket.org/")!, headers: [:])
        try await echo.send("tls-check")
        var got: [String] = []
        for _ in 0..<2 { got.append(try await echo.receive()) }
        echo.close()
        XCTAssertTrue(got.contains("tls-check"), "\(got.count) messages")
        // OpenAI completes the upgrade and then reports the bad key as an `error` event (or refuses the
        // upgrade outright); either way no session starts.
        do {
            let ws = try await SocketWebSocketConnector().connect(url: URL(string: "wss://api.openai.com/v1/realtime?intent=transcription")!,
                                                                   headers: ["Authorization": "Bearer sk-invalid-harness-check"])
            let first = try await ws.receive()
            ws.close()
            let event = try JSONSerialization.jsonObject(with: Data(first.utf8)) as? [String: Any]
            XCTAssertEqual(event?["type"] as? String, "error")
            XCTAssertEqual((event?["error"] as? [String: Any])?["code"] as? String, "invalid_api_key")
        } catch {
            XCTAssertTrue("\(error)".hasPrefix("websocket: "), "\(error)")
        }
    }

    func testRefusedHandshakeReportsTheStatusOnly() async throws {
        let listener = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        defer { close(listener) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, len) } }
        listen(listener, 1)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(listener, $0, &len) } }
        let port = UInt16(bigEndian: addr.sin_port)
        Thread {
            let fd = accept(listener, nil, nil)
            var buf = [UInt8](repeating: 0, count: 4096)
            _ = buf.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
            let reply = Array("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n".utf8)
            _ = reply.withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            close(fd)
        }.start()
        do {
            _ = try await SocketWebSocketConnector().connect(url: URL(string: "ws://127.0.0.1:\(port)/")!,
                                                              headers: ["Authorization": "Bearer secret-value-123"])
            XCTFail("expected a refused handshake")
        } catch {
            XCTAssertEqual("\(error)", "websocket: handshake HTTP 401")
        }
    }
}
#endif
