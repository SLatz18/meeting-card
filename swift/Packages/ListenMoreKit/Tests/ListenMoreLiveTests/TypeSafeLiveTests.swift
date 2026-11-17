import Foundation
import XCTest
import ListenMoreCore
import ListenMoreMac

/// Opt-in check against a real TypeSafe System One endpoint (possibly paid). Skipped unless
/// LISTEN_MORE_LIVE_TYPESAFE=1 and TYPESAFE_API_KEY are set; LISTEN_MORE_LIVE alone does not run it.
/// The state is synthetic and content-free (counting words). Nothing is printed except pass/fail.
final class TypeSafeLiveTests: XCTestCase {
    func testOneDecisionWithTheBuiltInQuestions() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["LISTEN_MORE_LIVE_TYPESAFE"] == "1", let key = env["TYPESAFE_API_KEY"].flatMap(APIKey.init) else {
            throw XCTSkip("live TypeSafe test needs LISTEN_MORE_LIVE_TYPESAFE=1 and TYPESAFE_API_KEY")
        }
        let config = try ListenMoreConfig.builtIn().judge.typesafe
        let judge = TypeSafeJudge(config: config, key: key, http: URLSessionHTTPTransport(), clock: SystemGptScheduler())
        let window = [JudgeLine(speaker: .others, secondsAgo: 8, text: "one two three four?"),
                      JudgeLine(speaker: .me, secondsAgo: 2, text: "five six seven eight.")]
        guard case .decided(let d) = try await judge.judge(JudgeInput(prompt: "", window: window)) else {
            return XCTFail("expected a decision")
        }
        XCTAssertNil(d.failure, d.failure?.description ?? "")
        XCTAssertTrue(d.verdicts.allSatisfy { v in CueType.judged.map(\.rawValue).contains(v.label) && v.confidence >= config.minConfidence })
    }
}
