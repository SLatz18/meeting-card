import XCTest
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
@testable import ListenMoreCore

final class KeyCheckTests: XCTestCase {
    func testClassify() {
        XCTAssertEqual(KeyCheck.classify(httpStatus: 200), .ok)
        XCTAssertEqual(KeyCheck.classify(httpStatus: 401), .rejected)
        XCTAssertEqual(KeyCheck.classify(httpStatus: 403), .rejected)
        XCTAssertEqual(KeyCheck.classify(httpStatus: nil), .unreachable)
        XCTAssertEqual(KeyCheck.classify(httpStatus: 500), .unreachable)
        XCTAssertEqual(KeyCheck.classify(httpStatus: 429), .unreachable)
    }

    func testEmptyKeyIsNotAKey() {
        XCTAssertNil(APIKey(""))
        XCTAssertNil(APIKey("  \n"))
    }

    func testRequestIsAGetWithBearerAndNoCache() throws {
        let r = KeyCheck.request(try XCTUnwrap(APIKey("sk-test-not-real")))
        XCTAssertEqual(r.httpMethod, "GET")
        XCTAssertEqual(r.url?.absoluteString, "https://api.openai.com/v1/models")
        XCTAssertEqual(r.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test-not-real")
        XCTAssertEqual(r.cachePolicy, .reloadIgnoringLocalAndRemoteCacheData)
        XCTAssertNil(r.httpBody)
    }
}
