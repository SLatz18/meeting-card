import Foundation

/// Runs on the transcription event loop, using the same call frames and VAD offsets as commits.
struct SpeakerTurns {
    struct Attribution {
        let speaker: Speaker
        let centroid: SpeakerEmbedding
        var announced = false
    }

    private let embedder: any SpeakerEmbedder
    private let sampleRate: Int
    private let preRollLimit: Int
    private var preRoll: [(raw: Bool, samples: [Float])] = []
    private var voiced: [Float] = []
    private var clusters = SpeakerClusters()
    private var turns: [(TimeInterval, Attribution)] = []

    init(embedder: any SpeakerEmbedder, config: ListenMoreConfig) {
        self.embedder = embedder
        sampleRate = config.audio.sampleRate
        preRollLimit = max(1, config.vad.onsetWindow)
    }

    mutating func observe(_ samples: [Float], vad: VadState) async {
        if vad.onset != nil {
            voiced = preRoll.drop(while: { !$0.raw }).filter(\.raw).flatMap(\.samples)
            preRoll.removeAll()
        }
        if vad.active && vad.raw && voiced.count < sampleRate * 8 {
            voiced += samples.prefix(sampleRate * 8 - voiced.count)
        } else if !vad.active && vad.offset == nil {
            preRoll.append((vad.raw, samples))
            if preRoll.count >= preRollLimit { preRoll.removeFirst() }
        }
        guard let offset = vad.offset else { return }
        let audio = voiced
        voiced.removeAll()
        let rate = sampleRate, embedder = embedder
        guard audio.count >= rate / 2 else { return }
        let embedding = await Task.detached(priority: .utility) { embedder.embed(audio, sampleRate: rate) }.value
        guard let embedding, let match = clusters.assign(embedding) else { return }
        turns.append((offset, Attribution(speaker: .other(match.number), centroid: match.centroid)))
        if turns.count > 128 { turns.removeFirst() }
    }

    mutating func attribution(at offset: TimeInterval, announce: Bool) -> Attribution? {
        guard let index = turns.lastIndex(where: { $0.0 == offset }) else { return nil }
        let result = turns[index].1
        if announce { turns[index].1.announced = true }
        return result
    }
}
