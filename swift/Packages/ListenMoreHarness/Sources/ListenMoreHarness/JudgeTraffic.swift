import Foundation
import ListenMoreCore

/// What the harness reads from a judge request body: which judge asked (its schema's name) and whether
/// it sent `store: false`. Never the prompt, the instructions or any other text.
public struct JudgeRequestFacts: Equatable, Sendable {
    public var selfPivot: Bool
    public var storeFalse: Bool

    public static func read(_ body: Data) -> JudgeRequestFacts {
        let root = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any]
        let format = (root?["text"] as? [String: Any])?["format"] as? [String: Any]
        return JudgeRequestFacts(selfPivot: format?["name"] as? String == SelfPivotJudgeSpec.name,
                                 storeFalse: root?["store"] as? Bool == false)
    }
}

/// Judge requests counted by judge, plus any that didn't send `store: false`. Counts only.
public final class JudgeTraffic: @unchecked Sendable {
    private let lock = NSLock()
    private var _selfPivotCalls = 0
    private var _storeViolations = 0

    public init() {}

    public var selfPivotCalls: Int { lock.withLock { _selfPivotCalls } }
    public var storeViolations: Int { lock.withLock { _storeViolations } }

    @discardableResult
    func record(_ body: Data) -> JudgeRequestFacts {
        let facts = JudgeRequestFacts.read(body)
        lock.withLock {
            if facts.selfPivot { _selfPivotCalls += 1 }
            if !facts.storeFalse { _storeViolations += 1 }
        }
        return facts
    }
}
