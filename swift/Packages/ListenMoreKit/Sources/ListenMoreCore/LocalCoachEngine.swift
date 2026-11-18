import Foundation

/// Pairs mic and call samples into aligned frames. Both streams arrive in irregular chunks from
/// different capture APIs; a stream that falls more than `maxLag` behind (e.g. call capture delivering
/// nothing while the call is silent) is padded with silence so the other side keeps flowing.
public struct FrameAligner {
    public let hop: Int
    public let maxLag: Int
    private var mic: [Float] = []
    private var call: [Float] = []
    public private(set) var paddedFrames = 0
    /// The user's mic is off: mic samples are dropped and each call frame goes out at once, paired
    /// with silence (no `maxLag` wait for a stream that isn't coming).
    public var micSilenced = false {
        didSet { if micSilenced { mic.removeAll() } }
    }

    public init(hop: Int, maxLagSamples: Int) {
        self.hop = hop
        self.maxLag = maxLagSamples
    }

    public mutating func append(_ stream: AudioStream, _ samples: [Float]) {
        switch stream {
        case .mic: if !micSilenced { mic += samples }
        case .call: call += samples
        }
    }

    public var buffered: (mic: Int, call: Int) { (mic.count, call.count) }

    /// Aligned (mic, call) frames ready to process, oldest first.
    public mutating func popFrames() -> [(mic: [Float], call: [Float])] {
        var out: [(mic: [Float], call: [Float])] = []
        while true {
            let haveMic = mic.count >= hop, haveCall = call.count >= hop
            if haveMic && haveCall {
                out.append((Array(mic.prefix(hop)), Array(call.prefix(hop))))
                mic.removeFirst(hop)
                call.removeFirst(hop)
            } else if haveMic && mic.count - call.count > maxLag {
                call += [Float](repeating: 0, count: hop - call.count)
                paddedFrames += 1
            } else if haveCall && (micSilenced || call.count - mic.count > maxLag) {
                mic += [Float](repeating: 0, count: hop - mic.count)
                paddedFrames += 1
            } else {
                return out
            }
        }
    }

    public mutating func reset() {
        mic.removeAll()
        call.removeAll()
        paddedFrames = 0
    }
}

/// The real engine: `CoachPipeline` on every aligned 20 ms frame, with the GPT layer and the
/// transcript rules when a key and transports are available. Callers serialize all calls
/// (CoachSession uses one serial queue). Audio time is frames processed x frame length, the same
/// clock the Python engine uses.
public final class LocalCoachEngine: CoachEngine, @unchecked Sendable {
    public weak var delegate: CoachEngineDelegate?
    public private(set) var isRunning = false
    public private(set) var framesProcessed = 0
    public private(set) var micMuted = false

    private let transports: GptTransports?
    private let maxLagMs: Int
    private let participants: Int
    private let judgeKeys: APIKeyProvider?
    private let judgeProvider: (@Sendable () -> JudgeProviderKind?)?
    private var config: ListenMoreConfig?
    private var pipeline: CoachPipeline?
    private var aligner: FrameAligner?
    private var gpt: GptLayer?
    private let clock = AudioClock()

    /// `transports` nil = local layer only (no network at all). `participants`: people on the call
    /// (2 = a 1:1), for talk share and group questions. `judgeProvider`, read at each start, replaces
    /// the config's `judge.provider` when it returns a value (a host setting; the next call uses it).
    /// `judgeKeys` supplies the TypeSafe key, read at start only while that provider is selected.
    public init(transports: GptTransports? = nil, maxLagMs: Int = 200, participants: Int = 2,
                judgeKeys: APIKeyProvider? = nil, judgeProvider: (@Sendable () -> JudgeProviderKind?)? = nil) {
        self.transports = transports
        self.maxLagMs = maxLagMs
        self.participants = participants
        self.judgeKeys = judgeKeys
        self.judgeProvider = judgeProvider
    }

    /// The config a session runs with: `config` with the host's provider pick applied.
    func sessionConfig(_ config: ListenMoreConfig) -> ListenMoreConfig {
        var c = config
        if let pick = judgeProvider?() { c.judge.provider = pick }
        return c
    }

    private func judgeKey(for config: ListenMoreConfig) -> APIKey? {
        switch config.judge.provider {
        case .gpt: return nil
        case .typesafe: return (try? judgeKeys?.readKey()) ?? nil
        }
    }

    public var hasGptLayer: Bool { gpt != nil }

    /// What this session's cue policy held back so far (type, engine time, reason), for diagnostics.
    /// Read it from the caller's serial queue, like every other call.
    public var cueHolds: [CuePolicy.Hold] { pipeline?.policy.held ?? [] }

    public func start(config: ListenMoreConfig, apiKey: APIKey?) {
        start(config: config, apiKey: apiKey, keyAvailability: apiKey == nil ? .absent : .present)
    }

    public func start(config: ListenMoreConfig, apiKey: APIKey?, keyAvailability: KeyAvailability) {
        stop()
        let config = sessionConfig(config)
        self.config = config
        let hop = config.audio.sampleRate * config.audio.frameMs / 1000
        aligner = FrameAligner(hop: hop, maxLagSamples: config.audio.sampleRate * maxLagMs / 1000)
        framesProcessed = 0
        micMuted = false
        clock.set(0)
        var bridge: AsyncGptBridge?
        if let apiKey, let transports {
            let clock = clock
            let box = AsyncGptBridge()
            let layer = GptLayer(config: config, key: apiKey, judgeKey: judgeKey(for: config), transports: transports, now: { clock.get() },
                                 offer: { label, t, refT, conf in box.land(.offer(label: label, t: t, refT: refT, confidence: conf)) },
                                 onSegment: { speaker, text, refT, now in box.land(.segment(speaker, text, refT: refT, now: now)) },
                                 onStopped: { [weak self] reason in
                                     guard let self else { return }
                                     self.delegate?.engine(self, gptStopped: reason)
                                 },
                                 onJudgeStopped: { [weak self] failure in
                                     guard let self else { return }
                                     self.delegate?.engine(self, judgeStopped: failure)
                                 },
                                 onCaption: { [weak self] event in
                                     guard let self else { return }
                                     self.delegate?.engine(self, caption: event)
                                 },
                                 onMeter: { [weak self] reading in
                                     guard let self else { return }
                                     self.delegate?.engine(self, meter: reading)
                                 },
                                 onClearRejected: { [weak self] speaker in
                                     guard let self else { return }
                                     self.delegate?.engine(self, clearRejected: speaker)
                                 })
            box.layer = layer
            layer.start()
            gpt = layer
            bridge = box
            CoachLog.record(.gptLayer(enabled: true, reason: .keyPresent))
        } else {
            let reason: GptLayerReason = keyAvailability == .rejected ? .keyRejected : apiKey == nil ? .noKey : .noTransports
            CoachLog.record(.gptLayer(enabled: false, reason: reason))
        }
        pipeline = CoachPipeline(config: config, gpt: bridge, participants: participants)
        isRunning = true
    }

    public func ingest(_ stream: AudioStream, samples: [Float], time: TimeInterval) {
        guard isRunning, let config, let pipeline, !(stream == .mic && micMuted) else { return }
        aligner?.append(stream, samples)
        let fs = Double(config.audio.frameMs) / 1000
        for frame in aligner?.popFrames() ?? [] {
            framesProcessed += 1
            let t = Double(framesProcessed) * fs
            clock.set(t)
            for cue in pipeline.process(t: t, mic: frame.mic[...], call: frame.call[...]) {
                delegate?.engine(self, didSuggest: CueSuggestion(type: cue.type, t: cue.t, onset: cue.onset, source: cue.source,
                                                                 confidence: cue.confidence, level: cue.level))
            }
        }
    }

    /// Mic off: the aligner pairs call frames with silence and the pipeline drops what it held of the
    /// user's speech (see `CoachPipeline.setMicMuted`). Mic on: frames pair up again.
    public func setMicMuted(_ muted: Bool) {
        guard isRunning, muted != micMuted else { return }
        micMuted = muted
        aligner?.micSilenced = muted
        pipeline?.setMicMuted(muted)
    }

    public func stop() {
        if let gpt {
            Task { await gpt.close() }
        }
        pipeline?.clear()
        gpt = nil
        pipeline = nil
        aligner = nil
        isRunning = false
    }

    /// The GPT layer's counters (no content), for diagnostics.
    public func gptSnapshot() async -> GptLayer.Snapshot? {
        await gpt?.snapshot()
    }
}

/// Adapts the async `GptLayer` to `PipelineGpt`: frames and local events go to its loop; transcripts
/// and verdicts it produces wait here until the next frame drains them.
final class AsyncGptBridge: PipelineGpt, @unchecked Sendable {
    weak var layer: GptLayer?
    private let lock = NSLock()
    private var landed: [GptOutput] = []

    func land(_ out: GptOutput) {
        lock.withLock { landed.append(out) }
    }

    func onLocal(_ event: LocalEvent) {
        layer?.onLocal(event)
    }

    func setMicMuted(_ muted: Bool) {
        layer?.setMicMuted(muted)
    }

    func feed(me: [Float], meVad: VadState, others: [Float], othersVad: VadState, meRunS: Double) {
        layer?.feed(me: me, meVad: meVad, others: others, othersVad: othersVad, meRunS: meRunS)
    }

    func drain(now: TimeInterval) -> [GptOutput] {
        lock.withLock {
            defer { landed.removeAll() }
            return landed
        }
    }
}

/// Engine audio time, read by the GPT layer from its own task.
final class AudioClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval = 0

    func set(_ v: TimeInterval) {
        lock.lock()
        t = v
        lock.unlock()
    }

    func get() -> TimeInterval {
        lock.lock()
        defer { lock.unlock() }
        return t
    }
}
