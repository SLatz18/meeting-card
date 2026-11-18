import Foundation
import ListenMoreCore

/// The real `LocalCoachEngine` behind a counting wrapper: what reaches the engine on each stream, when
/// (run clock), and its starts, stops and mic mutes. Offline (lockstep) it also holds the session's
/// engine queue after each call frame until the GPT layer has handled every frame fed so far, so
/// transcripts land at the same frame on every run.
public final class MeteredEngine: CoachEngine, @unchecked Sendable {
    public struct Ingest: Sendable {
        public var t: Double
        public var stream: AudioStream
        public var samples: Int
    }

    public let inner: LocalCoachEngine
    private let clock: HarnessClock
    private let lockstep: Bool
    private let lock = NSLock()
    private var _ingests: [Ingest] = []
    private var _starts: [Double] = []
    private var _stops: [Double] = []
    private var _micMutes: [(t: Double, muted: Bool)] = []
    private var _barrierTimeouts = 0
    /// Call frames the engine has finished (and, offline, the GPT layer has caught up on).
    public let callIngests = AsyncCounter()

    public init(inner: LocalCoachEngine, clock: HarnessClock, lockstep: Bool) {
        self.inner = inner
        self.clock = clock
        self.lockstep = lockstep
    }

    public var delegate: CoachEngineDelegate? {
        get { inner.delegate }
        set { inner.delegate = newValue }
    }

    public var isRunning: Bool { inner.isRunning }

    public var ingests: [Ingest] { lock.withLock { _ingests } }
    public var starts: [Double] { lock.withLock { _starts } }
    public var stops: [Double] { lock.withLock { _stops } }
    public var micMutes: [(t: Double, muted: Bool)] { lock.withLock { _micMutes } }
    public var barrierTimeouts: Int { lock.withLock { _barrierTimeouts } }

    public func start(config: ListenMoreConfig, apiKey: APIKey?) {
        inner.start(config: config, apiKey: apiKey)
        let t = clock.now()
        lock.withLock { _starts.append(t) }
    }

    public func ingest(_ stream: AudioStream, samples: [Float], time: TimeInterval) {
        inner.ingest(stream, samples: samples, time: time)
        let t = clock.now()
        lock.withLock { _ingests.append(Ingest(t: t, stream: stream, samples: samples.count)) }
        guard stream == .call else { return }
        if lockstep && inner.hasGptLayer { gptBarrier() }
        callIngests.add()
    }

    public func setMicMuted(_ muted: Bool) {
        inner.setMicMuted(muted)
        let t = clock.now()
        lock.withLock { _micMutes.append((t, muted)) }
    }

    public func stop() {
        inner.stop()
        let t = clock.now()
        lock.withLock { _stops.append(t) }
    }

    /// Runs on the session's engine queue, which stays blocked until the GPT layer's loop has answered
    /// a snapshot request queued behind every frame fed so far. The engine's `start`/`stop` are queued
    /// on that same queue, so nothing changes the engine's GPT layer while the snapshot reads it. The
    /// snapshot runs on the cooperative pool, never on this queue, so the wait can't deadlock.
    private func gptBarrier() {
        let done = DispatchSemaphore(value: 0)
        let engine = inner
        Task.detached {
            _ = await engine.gptSnapshot()
            done.signal()
        }
        if done.wait(timeout: .now() + 10) == .timedOut {
            lock.withLock { _barrierTimeouts += 1 }
        }
    }

    /// Samples of `stream` that reached the engine with run time inside `window`.
    public func samples(_ stream: AudioStream, in window: ClosedRange<Double>) -> Int {
        ingests.filter { $0.stream == stream && window.contains($0.t) }.reduce(0) { $0 + $1.samples }
    }
}
