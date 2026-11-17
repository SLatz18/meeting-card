import Foundation

/// Where the audio routes come from (Core Audio in ListenMoreMac, fakes in tests).
public protocol AudioRouteSource: AnyObject {
    func snapshot() -> AudioRoutes
    /// Calls `onChange` on the main queue whenever the routes may have changed, until `stopObserving()`.
    func observe(_ onChange: @escaping () -> Void)
    func stopObserving()
}

/// One open mic input for one plan (ListenMoreMac: a fresh AVAudioEngine per open).
public protocol MicInput: AnyObject {
    /// False once the input stopped by itself (for example, its device went away).
    var isRunning: Bool { get }
    /// Voice processing and ducking as the input reports them.
    var applied: MicProcessing { get }
    /// The device the input reports using.
    var deviceID: UInt32? { get }
    /// Stops and releases the device; no buffer is delivered after it returns.
    func stop()
}

public protocol MicInputOpening {
    /// Opens `plan.device`. `handler` gets mono Float32 at `sampleRate` on an audio thread;
    /// `onStopped` runs on any thread if the input stops by itself.
    func open(_ plan: MicPlan, sampleRate: Int, handler: @escaping @Sendable ([Float]) -> Void,
              onStopped: @escaping @Sendable () -> Void) throws -> MicInput
}

/// Main-queue time and timers (a manual clock in tests).
public protocol MicScheduler: AnyObject {
    var now: TimeInterval { get }
    /// Runs `work` on the main queue after `delay` seconds. Callable from any thread.
    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void)
}

/// The coach's mic: opens the input `MicPlan` picks for the current routes, reopens it when the
/// routes change (debounced by `MicRestartPolicy`), and closes it completely (input stopped and
/// released) on `stop()` or `setMuted(true)`. Use from the main thread.
public final class RoutedMic: MicSource {
    public enum Event: Equatable, Sendable {
        /// `applied` is nil when the plan opens no mic.
        case opened(MicPlan, applied: MicProcessing?, deviceID: UInt32?)
        case closed
        case restarted(count: Int)
        case openFailed(MicPlan)
    }

    public private(set) var isStarted = false
    public private(set) var isMuted = false
    /// The plan of the open mic; nil while closed.
    public private(set) var plan: MicPlan?
    public private(set) var restartCount = 0
    public private(set) var diagnostics: MicDiagnostics
    public var events: ((Event) -> Void)?

    public var isRunning: Bool { input?.isRunning ?? false }
    public var applied: MicProcessing? { input?.applied }
    public var deviceID: UInt32? { input?.deviceID }

    public let routes: AudioRouteSource
    private let opener: MicInputOpening
    private let scheduler: MicScheduler
    private let macOS: OperatingSystemVersion
    private var input: MicInput?
    private var sampleRate = 0
    private var handler: (@Sendable ([Float]) -> Void)?
    private var policy = MicRestartPolicy()
    private var timerGeneration = 0

    public init(routes: AudioRouteSource, opener: MicInputOpening, scheduler: MicScheduler,
                macOS: OperatingSystemVersion, diagnostics: MicDiagnostics = .standard) {
        self.routes = routes
        self.opener = opener
        self.scheduler = scheduler
        self.macOS = macOS
        self.diagnostics = diagnostics
    }

    /// The plan for the routes right now.
    public func currentPlan() -> MicPlan {
        MicPlan.plan(routes: routes.snapshot(), macOS: macOS, diagnostics: diagnostics)
    }

    public func start(sampleRate: Int, handler: @escaping @Sendable ([Float]) -> Void) throws {
        guard !isStarted else { return }
        self.sampleRate = sampleRate
        self.handler = handler
        isStarted = true
        routes.observe { [weak self] in self?.routesChanged() }
        guard !isMuted else { return }
        do {
            try open()
        } catch {
            isStarted = false
            routes.stopObserving()
            self.handler = nil
            throw error
        }
    }

    public func stop() {
        guard isStarted else { return }
        isStarted = false
        isMuted = false
        timerGeneration += 1
        routes.stopObserving()
        close()
        handler = nil
    }

    /// Muted closes the input completely and keeps the session's handler; unmuting reopens it on the
    /// current routes. Call capture is not this type's concern. `stop()` clears it.
    public func setMuted(_ muted: Bool) {
        guard muted != isMuted else { return }
        isMuted = muted
        guard isStarted else { return }
        if muted { close() } else { openReporting() }
    }

    /// Applies at once: the mic reopens if the plan changes.
    public func setDiagnostics(_ d: MicDiagnostics) {
        guard d != diagnostics else { return }
        diagnostics = d
        evaluate()
    }

    func routesChanged() {
        guard isStarted else { return }
        schedule(at: policy.changed(at: scheduler.now))
    }

    private func schedule(at due: TimeInterval) {
        timerGeneration += 1
        let generation = timerGeneration
        scheduler.schedule(after: max(0, due - scheduler.now)) { [weak self] in
            guard let self, generation == self.timerGeneration else { return }
            self.timerFired()
        }
    }

    private func timerFired() {
        switch policy.fire(at: scheduler.now) {
        case .idle: break
        case .wait(let until): schedule(at: until)
        case .evaluate: evaluate()
        }
    }

    private func evaluate() {
        guard isStarted, !isMuted else { return }
        let next = currentPlan()
        guard MicRestartPolicy.shouldRestart(open: plan, next: next, inputRunning: isRunning) else { return }
        close()
        policy.didRestart(at: scheduler.now)
        restartCount += 1
        events?(.restarted(count: restartCount))
        openReporting()
    }

    private func openReporting() {
        do { try open() } catch { events?(.openFailed(currentPlan())) }
    }

    private func open() throws {
        guard let handler else { return }
        let p = currentPlan()
        if p.device != nil {
            let scheduler = scheduler
            input = try opener.open(p, sampleRate: sampleRate, handler: handler, onStopped: { [weak self] in
                scheduler.schedule(after: 0) { self?.routesChanged() }
            })
        }
        plan = p
        events?(.opened(p, applied: input?.applied, deviceID: input?.deviceID))
    }

    private func close() {
        let wasOpen = plan != nil
        input?.stop()
        input = nil
        plan = nil
        if wasOpen { events?(.closed) }
    }
}
