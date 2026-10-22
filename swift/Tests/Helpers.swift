import Foundation
import XCTest
@testable import MeetingCardCore

/// Python conftest `fx` fixture: load tests/fixtures/<name>.json (copied into Tests/Fixtures).
func fx(_ name: String) -> Event {
    let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .appendingPathComponent("Fixtures/\(name).json")
    return try! Event.decode(try! Data(contentsOf: url))
}

func start(_ ev: Event) -> Date { Timing.times(ev)!.start }

let S: TimeInterval = 1
let M: TimeInterval = 60

/// Python `_moved`: shift start and end by `minutes`, re-serialized with the original offset
/// (like `datetime.isoformat()` on an aware datetime).
func moved(_ ev: Event, _ minutes: Double) -> Event {
    var f = ev
    func shift(_ s: String?) -> String? {
        guard let s, let d = Timing.parseDT(s) else { return s }
        let off = String(s.suffix(6))
        let sign = off.hasPrefix("-") ? -1 : 1
        let secs = sign * (Int(off.dropFirst().prefix(2))! * 3600 + Int(off.suffix(2))! * 60)
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.timeZone = TimeZone(secondsFromGMT: secs)
        fmt.dateFormat = "yyyy-MM-dd'T'HH:mm:ssxxx"
        return fmt.string(from: d.addingTimeInterval(minutes * 60))
    }
    let ns = shift(ev.start?.dateTime), ne = shift(ev.end?.dateTime)
    f.start?.dateTime = ns
    f.end?.dateTime = ne
    return f
}

/// Python `_runner`: a fake gws that records calls and returns a canned result.
final class FakeRunner: GwsRunner, @unchecked Sendable {
    struct Call { let executable: String; let args: [String]; let env: [String: String]; let timeout: TimeInterval }
    private let lock = NSLock()
    private(set) var calls: [Call] = []
    let result: RunResult
    init(rc: Int32 = 0, out: String = "", err: String = "") {
        result = .exited(status: rc, stdout: Data(out.utf8), stderr: Data(err.utf8))
    }
    init(result: RunResult) { self.result = result }
    func run(executable: String, args: [String], env: [String: String], timeout: TimeInterval) -> RunResult {
        lock.lock(); calls.append(Call(executable: executable, args: args, env: env, timeout: timeout)); lock.unlock()
        return result
    }
}

final class LogBox: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var lines: [String] = []
    func add(_ s: String) { lock.lock(); lines.append(s); lock.unlock() }
}

func gws(_ r: GwsRunner, _ logs: LogBox = LogBox(), path: String = "/fake/gws") -> Gws {
    Gws(path: path, runner: r, log: { logs.add($0) })
}

func json(_ s: String) -> Any { try! JSONSerialization.jsonObject(with: Data(s.utf8)) }
func jsonString(_ o: Any) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self) }

/// Python `_FakeCard`.
final class FakeCard: CardHandle {
    var ev: Event
    let rk: Rechecker
    var closedCalled = false
    var placed: [Int] = []
    var refreshed: [Event] = []
    var opening: [Bool] = []
    var slotsPlaced: [CardSlot] = []
    var nextUps: [String?] = []
    init(_ ev: Event, rk: Rechecker = Rechecker(now: 0)) { self.ev = ev; self.rk = rk }
    func close() { closedCalled = true }
    func place(_ s: CardSlot) { placed.append(s.index); slotsPlaced.append(s) }
    func setNextUp(_ line: NextUp.Parts?) { nextUps.append(line?.line) }
    func refresh(_ ev: Event, now: Date) { self.ev = ev; refreshed.append(ev) }
    func setNow(_ now: Date) {}
    func setOpening(_ on: Bool) { opening.append(on) }
}

/// Python `app.Controller.alloc().initWithArgs_(no_poll, no_recheck)`.
func controller(recheck: Bool = false, logs: LogBox = LogBox(),
                spawn: @escaping (String?, @escaping (GetOutcome) -> Void) -> Void = { _, _ in }) -> Coordinator<FakeCard> {
    Coordinator<FakeCard>(recheck: recheck, log: { logs.add($0) },
                          makeCard: { ev, _, _ in FakeCard(ev) }, spawnGet: spawn)
}
