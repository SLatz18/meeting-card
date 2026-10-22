import Foundation

/// A recognized video meeting link (provider: meet / zoom / teams / webex).
public struct VideoLink: Equatable, Hashable, Sendable {
    public let provider: String
    public let url: String
    public init(_ provider: String, _ url: String) { self.provider = provider; self.url = url }
}

/// Port of the link half of events.py. Regexes copied byte-for-byte from the Python
/// (`re.I` -> caseInsensitive; ICU `\w` is Unicode-aware like Python 3 str patterns).
public enum Links {
    static let linkRes: [(String, NSRegularExpression)] = [
        ("meet", rx(#"https://meet\.google\.com/[a-z0-9-]+"#)),
        ("zoom", rx(#"https://(?:[\w-]+\.)*zoom(?:gov)?\.(?:us|com)/"#
                    + #"(?:(?:j|w)/\d+(?:\?[\w.=&%-]*)?|my/[\w-]+(?:\.[\w-]+)*)"#)),
        ("teams", rx(#"https://teams\.microsoft\.com/l/meetup-join/[\w%./?=&+~-]+"#)),
        ("webex", rx(#"https://(?:[\w-]+\.)*webex\.com/[\w%./?=&+~-]+"#)),
    ]
    public static let labels: [String: String] = [
        "meet": "Join Meet", "zoom": "Join Zoom", "teams": "Join Teams", "webex": "Join Webex",
    ]

    static func rx(_ p: String, _ opts: NSRegularExpression.Options = [.caseInsensitive]) -> NSRegularExpression {
        try! NSRegularExpression(pattern: p, options: opts)
    }

    static func firstGroup(_ re: NSRegularExpression, _ s: String) -> String? {
        let ns = s as NSString
        guard let m = re.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        return ns.substring(with: m.range(at: 1))
    }

    /// Provider for a structured entry-point URL, or nil. Strict: the URL must BE a
    /// recognized meeting link (anchored at the start, like Python `re.match`).
    public static func providerOf(_ url: String) -> String? {
        let u = HTML.unescape(url)
        let r = NSRange(location: 0, length: (u as NSString).length)
        for (name, re) in linkRes where re.firstMatch(in: u, options: [.anchored], range: r) != nil {
            return name
        }
        return nil
    }

    /// All recognized meeting links in text, in text order (ties: provider name, then url,
    /// matching Python's tuple sort).
    public static func textLinks(_ text: String?) -> [VideoLink] {
        let t = HTML.unescape(text ?? "")
        let ns = t as NSString
        var hits: [(Int, String, String)] = []
        for (name, re) in linkRes {
            for m in re.matches(in: t, range: NSRange(location: 0, length: ns.length)) {
                hits.append((m.range.location, name, ns.substring(with: m.range)))
            }
        }
        hits.sort { ($0.0, $0.1, $0.2) < ($1.0, $1.1, $1.2) }
        return hits.map { VideoLink($0.1, $0.2) }
    }

    /// Python `urllib.parse.unquote`: valid %XX runs decode as UTF-8 (errors=replace);
    /// invalid escapes stay verbatim.
    public static func unquote(_ s: String) -> String {
        guard s.contains("%") else { return s }
        let b = Array(s.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var i = 0
        func hex(_ c: UInt8) -> UInt8? {
            switch c {
            case 48...57: return c - 48
            case 65...70: return c - 55
            case 97...102: return c - 87
            default: return nil
            }
        }
        while i < b.count {
            if b[i] == 37, i + 2 < b.count,let h = hex(b[i + 1]), let l = hex(b[i + 2]) {
                out.append(h << 4 | l); i += 3
            } else {
                out.append(b[i]); i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// HTML-unescape, then percent-decode until stable (max 3 rounds; Google redirect
    /// wrappers double-encode the target).
    public static func decode(_ url: String) -> String {
        var u = HTML.unescape(url)
        for _ in 0..<3 {
            let v = unquote(u)
            if v == u { break }
            u = v
        }
        return u
    }

    /// Python urlsplit(u).hostname and .path, lenient (decoded strings may hold spaces).
    static func splitHostPath(_ u: String) -> (host: String, path: String) {
        var rest = Substring(u)
        // scheme: leading [A-Za-z][A-Za-z0-9+.-]* followed by ':'
        if let colon = rest.firstIndex(of: ":") {
            let scheme = rest[rest.startIndex..<colon]
            if let f = scheme.first, f.isASCII, f.isLetter,
               scheme.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || "+-.".contains($0)) }) {
                rest = rest[rest.index(after: colon)...]
            }
        }
        var netloc = Substring("")
        if rest.hasPrefix("//") {
            rest = rest.dropFirst(2)
            let end = rest.firstIndex(where: { "/?#".contains($0) }) ?? rest.endIndex
            netloc = rest[rest.startIndex..<end]
            rest = rest[end...]
        }
        let pend = rest.firstIndex(where: { "?#".contains($0) }) ?? rest.endIndex
        let path = String(rest[rest.startIndex..<pend])
        var host = netloc
        if let at = host.lastIndex(of: "@") { host = host[host.index(after: at)...] }
        if host.hasPrefix("["), let close = host.firstIndex(of: "]") {
            host = host[host.index(after: host.startIndex)..<close]
        } else if let colon = host.firstIndex(of: ":") {
            host = host[host.startIndex..<colon]
        }
        return (host.lowercased(), path)
    }

    static let zoomId = rx(#"/(?:j|w)/(\d+)"#, [])
    static let zoomMy = rx(#"/my/([\w.-]+)"#)
    static let meetCode = rx(#"meet\.google\.com/([a-z0-9-]+)"#)

    /// Meeting identity for dedupe: Zoom meeting/webinar ID (any subdomain, pwd ignored)
    /// or personal-room name, Meet code, else host + decoded path with case preserved,
    /// cut at the first ? & or # (Teams thread IDs are case-sensitive).
    public static func identity(_ provider: String, _ url: String) -> [String] {
        let u = decode(url)
        if provider == "zoom" {
            if let id = firstGroup(zoomId, u) { return ["zoom", id] }
            if let my = firstGroup(zoomMy, u) { return ["zoom", "my:" + my.lowercased()] }
        }
        if provider == "meet", let code = firstGroup(meetCode, u) {
            return ["meet", code.lowercased()]
        }
        let (host, path) = splitHostPath(u)
        var p = Substring(path)
        if let cut = p.firstIndex(where: { "?&#".contains($0) }) { p = p[p.startIndex..<cut] }
        while p.hasSuffix("/") { p = p.dropLast() }
        return [provider, host, String(p)]
    }

    /// Distinct video meeting links, deduped by meeting identity, in source order:
    /// location, hangoutLink, conferenceData video entry points, description.
    public static func videoLinks(_ ev: Event) -> [VideoLink] {
        var found = textLinks(ev.location)
        if let h = ev.hangoutLink, !h.isEmpty { found.append(VideoLink("meet", h)) }
        for ep in ev.conferenceData?.entryPoints ?? [] {
            if ep.entryPointType == "video", let uri = ep.uri, !uri.isEmpty, let p = providerOf(uri) {
                found.append(VideoLink(p, uri))
            }
        }
        found += textLinks(ev.description)
        var seen = Set<[String]>()
        var out: [VideoLink] = []
        for l in found where seen.insert(identity(l.provider, l.url)).inserted {
            out.append(l)
        }
        return out
    }

    /// The link when the invite has exactly ONE distinct video link, else nil.
    public static func joinLink(_ ev: Event) -> VideoLink? {
        let l = videoLinks(ev)
        return l.count == 1 ? l[0] : nil
    }
}
