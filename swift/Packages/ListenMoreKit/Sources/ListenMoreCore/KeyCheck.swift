import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Result of checking an OpenAI key before the coach is switched on (GET /v1/models). Only these
/// three failure classes reach the UI; no response body is ever read or kept.
public enum KeyCheck: String, Equatable, Sendable {
    case ok
    /// Nothing entered.
    case empty
    /// OpenAI answered 401 (or 403): the key is wrong or revoked.
    case rejected
    /// No answer: offline, DNS, TLS, timeout, or a 5xx/429 from OpenAI.
    case unreachable

    public static func classify(httpStatus: Int?) -> KeyCheck {
        guard let s = httpStatus else { return .unreachable }
        switch s {
        case 200..<300: return .ok
        case 401, 403: return .rejected
        default: return .unreachable
        }
    }

    public static func request(_ key: APIKey, modelsURL: URL = URL(string: "https://api.openai.com/v1/models")!,
                               timeout: TimeInterval = 10) -> URLRequest {
        var r = URLRequest(url: modelsURL, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData, timeoutInterval: timeout)
        r.httpMethod = "GET"
        r.setValue("Bearer \(key.value)", forHTTPHeaderField: "Authorization")
        return r
    }
}
