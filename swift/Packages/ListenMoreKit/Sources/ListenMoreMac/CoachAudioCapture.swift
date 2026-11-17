import Foundation
import ListenMoreCore

/// Thread-safe on/off switch between the capture callbacks and the engine.
final class AudioGate {
    private let lock = NSLock()
    private var generation = 0
    private var open = false

    func openNew() -> Int {
        lock.lock(); defer { lock.unlock() }
        generation += 1
        open = true
        return generation
    }

    func close() {
        lock.lock(); defer { lock.unlock() }
        open = false
        generation += 1
    }

    func admits(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return open && gen == generation
    }
}

/// The user's mic (AVAudioEngine) as the capture sees it.
protocol MicSource: AnyObject {
    func start(handler: @escaping ([Float]) -> Void) throws
    func stop()
}

/// Call audio (ScreenCaptureKit, helper fallback, process tap) as the capture sees it.
protocol CallSource: AnyObject {
    func start(bundleIds: [String], stage: CaptureStage, handler: @escaping ([Float]) -> Void) async throws
    func stop() async
    func helperPids(bundleIds: [String]) async -> Set<pid_t>
}

extension MicCapture: MicSource {}
extension CallCapture: CallSource {}

/// Mic + call capture for `CoachRunner`. `stop()` closes the gate synchronously before tearing the
/// devices down, so not one buffer reaches the engine (or OpenAI) after it returns, even while
/// ScreenCaptureKit is still stopping asynchronously. Escalates the call-capture stage
/// (parent apps -> helper apps -> process tap) when the call stream stays silent while the app's
/// helpers are producing output.
public final class CoachAudioCapture: CoachCapture {
    public enum Status: String, Sendable {
        case idle, running, micFailed, callFailed
    }

    let config: ListenMoreConfig
    let mic: MicSource
    let call: CallSource
    private let gate = AudioGate()
    private var fallback = CaptureFallbackPolicy()
    private var fallbackTimer: DispatchSourceTimer?
    private let levelLock = NSLock()
    private var callEnergy: Float = 0
    private var callSamples = 0
    private var bundleIds: [String] = []
    private var onCall: (([Float]) -> Void)?
    public private(set) var status: Status = .idle
    public var onStatus: ((Status) -> Void)?

    public convenience init(config: ListenMoreConfig) {
        self.init(config: config, mic: MicCapture(sampleRate: Double(config.audio.sampleRate)), call: CallCapture(config: config))
    }

    init(config: ListenMoreConfig, mic: MicSource, call: CallSource) {
        self.config = config
        self.mic = mic
        self.call = call
    }

    public func start(bundleIds: [String], onMic: @escaping ([Float]) -> Void, onCall: @escaping ([Float]) -> Void) {
        let gen = gate.openNew()
        let gate = gate
        self.bundleIds = bundleIds
        self.onCall = onCall
        fallback.reset()
        do {
            try mic.start { samples in if gate.admits(gen) { onMic(samples) } }
            setStatus(.running)
        } catch {
            let code = (error as NSError).code
            Log.capture.error("mic start failed, code \(code, privacy: .public)")
            setStatus(.micFailed)
        }
        startCall(stage: .parentApps, gen: gen)
        startFallbackTimer(gen: gen)
    }

    public func stop() {
        gate.close()
        fallbackTimer?.cancel()
        fallbackTimer = nil
        mic.stop()
        onCall = nil
        let call = call
        Task { await call.stop() }
        setStatus(.idle)
    }

    private func startCall(stage: CaptureStage, gen: Int) {
        guard let onCall else { return }
        let gate = gate
        let bundleIds = bundleIds
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.call.start(bundleIds: bundleIds, stage: stage) { [weak self] samples in
                    guard gate.admits(gen) else { return }
                    self?.meter(samples)
                    onCall(samples)
                }
                if !gate.admits(gen) { await self.call.stop() }
            } catch {
                let code = (error as NSError).code
                Log.capture.error("call capture failed at stage \(stage.rawValue, privacy: .public), code \(code, privacy: .public)")
                if gate.admits(gen) { DispatchQueue.main.async { self.setStatus(.callFailed) } }
            }
        }
    }

    private func meter(_ samples: [Float]) {
        let e = samples.reduce(Float(0)) { $0 + $1 * $1 }
        levelLock.lock()
        callEnergy += e
        callSamples += samples.count
        levelLock.unlock()
    }

    private func takeLevel() -> Float {
        levelLock.lock(); defer { levelLock.unlock() }
        let db: Float = callSamples > 0 && callEnergy > 0 ? 10 * log10(callEnergy / Float(callSamples)) : -.infinity
        callEnergy = 0
        callSamples = 0
        return db
    }

    private func startFallbackTimer(gen: Int) {
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now() + 1, repeating: 1)
        t.setEventHandler { [weak self] in
            guard let self, self.gate.admits(gen) else { return }
            let db = self.takeLevel()
            let bundleIds = self.bundleIds
            Task { [weak self] in
                guard let self else { return }
                let pids = await self.call.helperPids(bundleIds: bundleIds)
                let audible = CoreAudioStateProvider.anyOutputRunning(pids: pids)
                await MainActor.run {
                    guard self.gate.admits(gen),
                          let stage = self.fallback.observe(callDbfs: db, helpersAudible: audible,
                                                           now: ProcessInfo.processInfo.systemUptime) else { return }
                    Log.capture.info("call capture escalating to stage \(stage.rawValue, privacy: .public)")
                    self.startCall(stage: stage, gen: gen)
                }
            }
        }
        t.resume()
        fallbackTimer = t
    }

    private func setStatus(_ s: Status) {
        status = s
        onStatus?(s)
    }
}
