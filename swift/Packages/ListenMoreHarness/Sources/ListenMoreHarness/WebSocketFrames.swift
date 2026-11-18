import Foundation

/// RFC 6455 pieces for the live transport: client frames (always masked), server frame parsing,
/// message reassembly and the opening handshake. Pure code, unit-tested offline.
public enum WebSocketCodec {
    public enum Opcode: UInt8 {
        case continuation = 0x0, text = 0x1, binary = 0x2, close = 0x8, ping = 0x9, pong = 0xA
    }

    public struct Frame: Equatable {
        public var fin: Bool
        public var opcode: UInt8
        public var payload: [UInt8]
    }

    public static func encode(_ opcode: Opcode, _ payload: [UInt8], mask: [UInt8]) -> [UInt8] {
        precondition(mask.count == 4)
        var out: [UInt8] = [0x80 | opcode.rawValue]
        let n = payload.count
        if n < 126 {
            out.append(0x80 | UInt8(n))
        } else if n <= 0xFFFF {
            out.append(0x80 | 126)
            out += [UInt8(n >> 8 & 0xFF), UInt8(n & 0xFF)]
        } else {
            out.append(0x80 | 127)
            for shift in stride(from: 56, through: 0, by: -8) { out.append(UInt8(UInt64(n) >> UInt64(shift) & 0xFF)) }
        }
        out += mask
        out.reserveCapacity(out.count + n)
        for (i, b) in payload.enumerated() { out.append(b ^ mask[i & 3]) }
        return out
    }

    public static func randomMask() -> [UInt8] {
        var g = SystemRandomNumberGenerator()
        return (0..<4).map { _ in UInt8.random(in: 0...255, using: &g) }
    }

    /// Accumulates bytes and yields whole frames.
    public struct Parser {
        private var buffer: [UInt8] = []
        public let maxPayload: Int

        public init(maxPayload: Int = 1 << 24) {
            self.maxPayload = maxPayload
        }

        public mutating func push(_ bytes: [UInt8]) {
            buffer += bytes
        }

        public enum ParseError: Error { case tooLarge }

        public mutating func next() throws -> Frame? {
            guard buffer.count >= 2 else { return nil }
            let fin = buffer[0] & 0x80 != 0
            let opcode = buffer[0] & 0x0F
            let masked = buffer[1] & 0x80 != 0
            var len = Int(buffer[1] & 0x7F)
            var i = 2
            if len == 126 {
                guard buffer.count >= 4 else { return nil }
                len = Int(buffer[2]) << 8 | Int(buffer[3])
                i = 4
            } else if len == 127 {
                guard buffer.count >= 10 else { return nil }
                var v: UInt64 = 0
                for k in 2..<10 { v = v << 8 | UInt64(buffer[k]) }
                guard v <= UInt64(maxPayload) else { throw ParseError.tooLarge }
                len = Int(v)
                i = 10
            }
            guard len <= maxPayload else { throw ParseError.tooLarge }
            var mask: [UInt8] = []
            if masked {
                guard buffer.count >= i + 4 else { return nil }
                mask = Array(buffer[i..<(i + 4)])
                i += 4
            }
            guard buffer.count >= i + len else { return nil }
            var payload = Array(buffer[i..<(i + len)])
            if masked { for k in payload.indices { payload[k] ^= mask[k & 3] } }
            buffer.removeFirst(i + len)
            return Frame(fin: fin, opcode: opcode, payload: payload)
        }
    }

    public enum Event: Equatable {
        case text(String)
        case binary([UInt8])
        case ping([UInt8])
        case pong
        case close(UInt16?)
    }

    /// Joins fragmented data frames; control frames pass straight through.
    public struct Assembler {
        private var opcode: UInt8?
        private var parts: [UInt8] = []

        public init() {}

        public mutating func feed(_ f: Frame) -> Event? {
            switch f.opcode {
            case Opcode.ping.rawValue: return .ping(f.payload)
            case Opcode.pong.rawValue: return .pong
            case Opcode.close.rawValue:
                return .close(f.payload.count >= 2 ? UInt16(f.payload[0]) << 8 | UInt16(f.payload[1]) : nil)
            case Opcode.text.rawValue, Opcode.binary.rawValue:
                opcode = f.opcode
                parts = f.payload
            case Opcode.continuation.rawValue:
                guard opcode != nil else { return nil }
                parts += f.payload
            default:
                return nil
            }
            guard f.fin, let op = opcode else { return nil }
            defer {
                opcode = nil
                parts = []
            }
            return op == Opcode.text.rawValue ? .text(String(decoding: parts, as: UTF8.self)) : .binary(parts)
        }
    }

    // MARK: handshake

    public static let guid = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

    public static func clientKey() -> String {
        var g = SystemRandomNumberGenerator()
        return Data((0..<16).map { _ in UInt8.random(in: 0...255, using: &g) }).base64EncodedString()
    }

    public static func accept(for key: String) -> String {
        Data(SHA1.hash(Array((key + guid).utf8))).base64EncodedString()
    }

    public static func handshake(url: URL, headers: [String: String], key: String) -> String {
        let host = url.host ?? ""
        let defaultPort = url.scheme == "wss" ? 443 : 80
        let hostHeader = url.port.map { $0 == defaultPort ? host : "\(host):\($0)" } ?? host
        var path = url.path.isEmpty ? "/" : url.path
        if let q = url.query { path += "?" + q }
        var lines = ["GET \(path) HTTP/1.1", "Host: \(hostHeader)", "Upgrade: websocket", "Connection: Upgrade",
                     "Sec-WebSocket-Key: \(key)", "Sec-WebSocket-Version: 13"]
        for (k, v) in headers.sorted(by: { $0.key < $1.key }) { lines.append("\(k): \(v)") }
        return lines.joined(separator: "\r\n") + "\r\n\r\n"
    }

    public struct HandshakeResponse {
        public var status: Int
        public var headers: [String: String]
        /// Bytes after the header block (the first frames).
        public var rest: [UInt8]
    }

    /// nil until the whole header block has arrived.
    public static func parseResponse(_ bytes: [UInt8]) -> HandshakeResponse? {
        let end: [UInt8] = [13, 10, 13, 10]
        guard bytes.count >= 4, let i = (0...(bytes.count - 4)).first(where: { Array(bytes[$0..<($0 + 4)]) == end }) else { return nil }
        let head = String(decoding: bytes[0..<i], as: UTF8.self)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        let status = parts.count >= 2 ? Int(parts[1]) ?? 0 : 0
        var headers: [String: String] = [:]
        for l in lines.dropFirst() {
            guard let c = l.firstIndex(of: ":") else { continue }
            headers[l[..<c].trimmingCharacters(in: .whitespaces).lowercased()] = l[l.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        return HandshakeResponse(status: status, headers: headers, rest: Array(bytes[(i + 4)...]))
    }
}

/// SHA-1 for the handshake's accept value only (RFC 3174). Not used for anything security-relevant.
enum SHA1 {
    static func hash(_ message: [UInt8]) -> [UInt8] {
        var h: [UInt32] = [0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0]
        var m = message
        let bitLength = UInt64(message.count) * 8
        m.append(0x80)
        while m.count % 64 != 56 { m.append(0) }
        for shift in stride(from: 56, through: 0, by: -8) { m.append(UInt8(bitLength >> UInt64(shift) & 0xFF)) }
        func rotl(_ x: UInt32, _ n: UInt32) -> UInt32 { x << n | x >> (32 - n) }
        for chunk in stride(from: 0, to: m.count, by: 64) {
            var w = [UInt32](repeating: 0, count: 80)
            for i in 0..<16 {
                let j = chunk + i * 4
                w[i] = UInt32(m[j]) << 24 | UInt32(m[j + 1]) << 16 | UInt32(m[j + 2]) << 8 | UInt32(m[j + 3])
            }
            for i in 16..<80 { w[i] = rotl(w[i - 3] ^ w[i - 8] ^ w[i - 14] ^ w[i - 16], 1) }
            var (a, b, c, d, e) = (h[0], h[1], h[2], h[3], h[4])
            for i in 0..<80 {
                let (f, k): (UInt32, UInt32)
                switch i {
                case 0..<20: (f, k) = ((b & c) | (~b & d), 0x5A827999)
                case 20..<40: (f, k) = (b ^ c ^ d, 0x6ED9EBA1)
                case 40..<60: (f, k) = ((b & c) | (b & d) | (c & d), 0x8F1BBCDC)
                default: (f, k) = (b ^ c ^ d, 0xCA62C1D6)
                }
                let t = rotl(a, 5) &+ f &+ e &+ k &+ w[i]
                (e, d, c, b, a) = (d, c, rotl(b, 30), a, t)
            }
            h[0] = h[0] &+ a; h[1] = h[1] &+ b; h[2] = h[2] &+ c; h[3] = h[3] &+ d; h[4] = h[4] &+ e
        }
        return h.flatMap { v in [24, 16, 8, 0].map { UInt8(v >> UInt32($0) & 0xFF) } }
    }
}
