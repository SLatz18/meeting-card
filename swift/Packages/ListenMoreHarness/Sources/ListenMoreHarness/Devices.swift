import Foundation
import ListenMoreCore

/// The run's clock in scenario-independent seconds. Simulated offline (advanced by the runner, one
/// 20 ms step at a time); the monotonic wall clock live.
public final class HarnessClock: @unchecked Sendable {
    public enum Kind: Sendable { case simulated, wall }

    public let kind: Kind
    private let lock = NSLock()
    private var t = 0.0
    private let origin = ProcessInfo.processInfo.systemUptime

    public init(_ kind: Kind) {
        self.kind = kind
    }

    public func now() -> Double {
        switch kind {
        case .simulated: return lock.withLock { t }
        case .wall: return ProcessInfo.processInfo.systemUptime - origin
        }
    }

    public func advance(to v: Double) {
        lock.withLock { t = max(t, v) }
    }
}

/// A counter tasks can wait on. `wait` returns false if the target isn't reached within `timeout`
/// seconds of real time (a stuck barrier is reported, never hung on). One watchdog timer runs only
/// while someone is waiting and expires overdue waiters; a wait doesn't schedule its own timer.
public final class AsyncCounter: @unchecked Sendable {
    struct Waiter {
        var target: Int
        var deadline: DispatchTime
        var c: CheckedContinuation<Bool, Never>
    }

    static let watchdogInterval = 0.25
    private let lock = NSLock()
    private var value = 0
    private var nextId = 0
    private var waiters: [Int: Waiter] = [:]
    private var watchdog: DispatchSourceTimer?

    public init() {}

    deinit { watchdog?.cancel() }

    public var current: Int { lock.withLock { value } }

    public func add(_ n: Int = 1) {
        let ready = lock.withLock { () -> [CheckedContinuation<Bool, Never>] in
            value += n
            let hits = waiters.filter { $0.value.target <= value }
            for k in hits.keys { waiters[k] = nil }
            stopWatchdogIfIdle()
            return hits.map(\.value.c)
        }
        ready.forEach { $0.resume(returning: true) }
    }

    public func wait(atLeast target: Int, timeout: Double) async -> Bool {
        await withCheckedContinuation { (c: CheckedContinuation<Bool, Never>) in
            let reached = lock.withLock { () -> Bool in
                if value >= target { return true }
                nextId += 1
                waiters[nextId] = Waiter(target: target, deadline: .now() + timeout, c: c)
                startWatchdogIfNeeded()
                return false
            }
            if reached { c.resume(returning: true) }
        }
    }

    /// Under `lock`.
    private func startWatchdogIfNeeded() {
        guard watchdog == nil else { return }
        let t = DispatchSource.makeTimerSource(queue: .global())
        t.schedule(deadline: .now() + Self.watchdogInterval, repeating: Self.watchdogInterval)
        t.setEventHandler { [weak self] in self?.expireOverdue() }
        watchdog = t
        t.resume()
    }

    /// Under `lock`.
    private func stopWatchdogIfIdle() {
        guard waiters.isEmpty, let t = watchdog else { return }
        t.cancel()
        watchdog = nil
    }

    private func expireOverdue() {
        let now = DispatchTime.now()
        let overdue = lock.withLock { () -> [CheckedContinuation<Bool, Never>] in
            let late = waiters.filter { $0.value.deadline <= now }
            for k in late.keys { waiters[k] = nil }
            stopWatchdogIfIdle()
            return late.map(\.value.c)
        }
        overdue.forEach { $0.resume(returning: false) }
    }
}

/// The user's microphone. While muted it keeps offering audio to the session's handler (a buffer
/// already in flight, or a device slow to stop), so the session's own mic gate is what the mute
/// assertions test.
public final class HarnessMic: MicSource, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable ([Float]) -> Void)?
    private var muted = false
    public private(set) var starts = 0
    public private(set) var stops = 0
    public private(set) var muteCalls: [Bool] = []
    /// Samples offered to the session's handler while muted (all must be dropped before the engine).
    public private(set) var offeredWhileMuted = 0

    public init() {}

    public var isStarted: Bool { lock.withLock { handler != nil } }
    public var isMuted: Bool { lock.withLock { muted } }

    public func start(sampleRate: Int, handler: @escaping @Sendable ([Float]) -> Void) throws {
        lock.withLock {
            self.handler = handler
            starts += 1
        }
    }

    public func stop() {
        lock.withLock {
            handler = nil
            muted = false
            stops += 1
        }
    }

    public func setMuted(_ muted: Bool) -> Bool {
        lock.withLock {
            self.muted = muted
            muteCalls.append(muted)
        }
        return true
    }

    /// Offers one chunk; false when the mic isn't started.
    @discardableResult
    public func deliver(_ samples: [Float]) -> Bool {
        let h = lock.withLock { () -> (@Sendable ([Float]) -> Void)? in
            if muted && handler != nil { offeredWhileMuted += samples.count }
            return handler
        }
        guard let h else { return false }
        h(samples)
        return true
    }
}

/// Call audio ("everyone else"). `generation` goes up on every start, so the runner can wait for a
/// (re)start that the session runs asynchronously.
public final class HarnessCall: CallSource, @unchecked Sendable {
    private let lock = NSLock()
    private var handler: (@Sendable ([Float]) -> Void)?
    private var _generation = 0
    private var _stops = 0
    private var _bundleIds: [[String]] = []

    public init() {}

    public var generation: Int { lock.withLock { _generation } }
    public var stops: Int { lock.withLock { _stops } }
    public var isStarted: Bool { lock.withLock { handler != nil } }
    public var startedBundleIds: [[String]] { lock.withLock { _bundleIds } }

    public func start(bundleIds: [String], stage: CaptureStage, sampleRate: Int,
                      handler: @escaping @Sendable ([Float]) -> Void) async throws {
        lock.withLock {
            self.handler = handler
            _generation += 1
            _bundleIds.append(bundleIds)
        }
    }

    public func stop() async {
        lock.withLock {
            handler = nil
            _stops += 1
        }
    }

    @discardableResult
    public func deliver(_ samples: [Float]) -> Bool {
        guard let h = lock.withLock({ handler }) else { return false }
        h(samples)
        return true
    }
}

/// Core Audio running state for one synthetic call app: input and output running while the call is live.
public final class HarnessAudioState: AudioStateProvider {
    public static let appBundleId = "com.example.callapp"
    public var live = false

    public init() {}

    public func snapshot() -> AudioStateSnapshot {
        guard live else { return AudioStateSnapshot(defaultInputRunning: false, processes: []) }
        return AudioStateSnapshot(defaultInputRunning: true, processes: [
            AudioProcessState(pid: 4242, bundleId: Self.appBundleId, isRunningInput: true, isRunningOutput: true),
        ])
    }
}

/// The Kit's `FileTranscriptStore` (the coach's only disk writer) with every call recorded, so a
/// keep-nothing run can show it was never asked to write and a saving run that it wrote only in the run dir.
public final class CountingTranscriptStore: TranscriptStore {
    private let inner: TranscriptStore
    public private(set) var prepared: [URL] = []
    public private(set) var written: [URL] = []
    public private(set) var removed: [URL] = []

    public init(inner: TranscriptStore = FileTranscriptStore()) {
        self.inner = inner
    }

    public func prepare(folder: URL) throws {
        prepared.append(folder)
        try inner.prepare(folder: folder)
    }

    public func exists(_ url: URL) -> Bool { inner.exists(url) }

    public func write(_ text: String, to url: URL) throws {
        written.append(url)
        try inner.write(text, to: url)
    }

    public func remove(_ url: URL) throws {
        removed.append(url)
        try inner.remove(url)
    }
}

public struct HarnessKeys: APIKeyProvider {
    public var key: APIKey?

    public init(key: APIKey?) {
        self.key = key
    }

    public func readKey() throws -> APIKey? { key }
}

@MainActor
public final class HarnessRenderer: CueRenderer {
    public private(set) var rendered: [Cue] = []
    public private(set) var clears = 0

    public init() {}

    public func render(_ cue: Cue) { rendered.append(cue) }
    public func clear() { clears += 1 }
}
