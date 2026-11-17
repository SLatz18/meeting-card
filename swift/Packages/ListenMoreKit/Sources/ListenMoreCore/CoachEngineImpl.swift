import Foundation

/// Builds the network transports for the GPT layer (live OpenAI clients on macOS, mocks in tests).
public protocol GptTransportFactory: AnyObject {
    func transcriber(config: ListenMoreConfig, key: APIKey, speaker: Speaker) -> Transcriber
    func judge(config: ListenMoreConfig, key: APIKey) -> Judge
}

/// Counters only; safe to log.
public struct EngineStats: Equatable, Sendable {
    public var frames = 0
    public var localCues = 0
    public var gptCues = 0
    public var paddedFrames = 0
}

/// The engine: frames both streams in lockstep, runs the local layer on every frame, and (with a
/// key) the GPT layer. All state lives on one serial queue; nothing is written anywhere.
public final class LocalCoachEngine: CoachEngine {
    public weak var delegate: CoachEngineDelegate?
    public let queue = DispatchQueue(label: "listenmore.engine", qos: .userInteractive)
    let transport: GptTransportFactory?
    /// If one stream is this many frames ahead while the other has nothing (capture not delivering,
    /// e.g. an app that only sends buffers while audible), the quiet side is padded with silence.
    let maxSkewFrames: Int

    private let lock = NSLock()
    private var running = false
    private var config: ListenMoreConfig?
    private var local: LocalLayer?
    private var gpt: GptLayer?
    private var micFifo: [Float] = []
    private var callFifo: [Float] = []
    private var frameIndex = 0
    private var _stats = EngineStats()

    public init(transport: GptTransportFactory? = nil, maxSkewFrames: Int = 10) {
        self.transport = transport
        self.maxSkewFrames = maxSkewFrames
    }

    public var isRunning: Bool {
        lock.lock()
        defer { lock.unlock() }
        return running
    }

    public var stats: EngineStats {
        lock.lock()
        defer { lock.unlock() }
        return _stats
    }

    public var gptCost: CostTracker? { queue.sync { gpt?.cost } }

    /// Audio time of the last processed frame (the engine clock).
    var engineTime: Double { Double(frameIndex) * (config?.frameS ?? 0.02) }

    public func start(config: ListenMoreConfig, apiKey: APIKey?) {
        lock.lock()
        running = true
        _stats = EngineStats()
        lock.unlock()
        queue.async { [self] in
            self.config = config
            local = LocalLayer(config: config)
            micFifo = []
            callFifo = []
            frameIndex = 0
            gpt = nil
            if let apiKey, let transport {
                var txs: [Speaker: Transcriber] = [:]
                for s in Speaker.allCases { txs[s] = transport.transcriber(config: config, key: apiKey, speaker: s) }
                let layer = GptLayer(config: config, queue: queue, now: { [weak self] in self?.engineTime ?? 0 },
                                     transcribers: txs, judge: transport.judge(config: config, key: apiKey),
                                     offer: { [weak self] label, t, ref, conf in self?.gptOffer(label, t, ref, conf) },
                                     onDisabled: { [weak self] kind in
                                         guard let self else { return }
                                         self.delegate?.engine(self, gptDisabled: kind)
                                     })
                layer.start()
                gpt = layer
            }
        }
    }

    public func ingest(_ stream: AudioStream, samples: [Float]) {
        queue.async { [self] in
            guard local != nil else { return }
            switch stream {
            case .mic: micFifo += samples
            case .call: callFifo += samples
            }
            drain()
        }
    }

    public func stop() {
        lock.lock()
        running = false
        lock.unlock()
        queue.async { [self] in
            gpt?.close()
            gpt = nil
            local = nil
            micFifo = []
            callFifo = []
        }
    }

    /// Waits until everything queued so far has been processed (tests, orderly shutdown).
    public func flush() {
        queue.sync {}
    }

    private func drain() {
        guard let config, let local else { return }
        let hop = config.frameSamples
        let skew = hop * maxSkewFrames
        while true {
            if micFifo.count >= hop && callFifo.count < hop && micFifo.count >= skew {
                callFifo += [Float](repeating: 0, count: hop - callFifo.count)
                bumpPadded()
            } else if callFifo.count >= hop && micFifo.count < hop && callFifo.count >= skew {
                micFifo += [Float](repeating: 0, count: hop - micFifo.count)
                bumpPadded()
            }
            guard micFifo.count >= hop, callFifo.count >= hop else { return }
            let mic = micFifo[0..<hop], call = callFifo[0..<hop]
            frameIndex += 1
            let t = engineTime
            let (events, s, o) = local.step(t: t, mic: mic, call: call)
            for ev in events {
                gpt?.onLocal(ev)
                if let type = ev.cueType {
                    lock.lock(); _stats.localCues += 1; lock.unlock()
                    delegate?.engine(self, didSuggest: CueSuggestion(type: type, t: t, onset: ev.onset, source: .local))
                }
            }
            gpt?.feed(.me, frame: mic, onset: s.onset, offset: s.offset)
            gpt?.feed(.others, frame: call, onset: o.onset, offset: o.offset)
            micFifo.removeFirst(hop)
            callFifo.removeFirst(hop)
            lock.lock(); _stats.frames += 1; lock.unlock()
        }
    }

    private func bumpPadded() {
        lock.lock(); _stats.paddedFrames += 1; lock.unlock()
    }

    private func gptOffer(_ label: String, _ t: Double, _ ref: Double, _ conf: Double) {
        guard let type = CueType(gptLabel: label) else { return }
        lock.lock(); _stats.gptCues += 1; lock.unlock()
        delegate?.engine(self, didSuggest: CueSuggestion(type: type, t: t, onset: ref, source: .gpt, confidence: conf))
    }
}
