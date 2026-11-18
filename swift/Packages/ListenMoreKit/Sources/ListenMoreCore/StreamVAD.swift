import CWebRTCVAD
import Foundation

/// WebRTC VAD instance. Each stream owns one, because the classifier adapts to the signal it sees.
public final class WebRTCVad {
    private let handle: OpaquePointer

    public init?(mode: Int) {
        guard (0...3).contains(mode), let h = lm_vad_create(Int32(mode)) else { return nil }
        handle = h
    }

    deinit {
        lm_vad_free(handle)
    }

    public static func isValid(sampleRate: Int, frameLength: Int) -> Bool {
        lm_vad_valid_rate_and_frame_length(Int32(sampleRate), frameLength) == 1
    }

    /// nil when WebRTC rejects the rate or frame length.
    public func isSpeech(_ pcm: [Int16], sampleRate: Int) -> Bool? {
        let r = pcm.withUnsafeBufferPointer { lm_vad_process(handle, Int32(sampleRate), $0.baseAddress, $0.count) }
        switch r {
        case 1: return true
        case 0: return false
        default: return nil
        }
    }
}

public struct VadState: Equatable {
    public var raw: Bool
    public var active: Bool
    /// Set on the frame where activity is confirmed (back-dated to the first speech frame in the window).
    public var onset: TimeInterval?
    /// Set on the frame where activity is released (time of the last speech frame).
    public var offset: TimeInterval?
    public var dbfs: Double

    /// For drivers that place voice activity themselves (the harness's precision run, tests).
    public init(raw: Bool, active: Bool, onset: TimeInterval?, offset: TimeInterval?, dbfs: Double) {
        self.raw = raw
        self.active = active
        self.onset = onset
        self.offset = offset
        self.dbfs = dbfs
    }
}

/// Port of `listen_more/vad.py` `StreamVAD`: WebRTC VAD + energy gate + onset/hangover smoothing.
public final class StreamVAD {
    public let rate: Int
    public let frameS: Double
    public let vadRate: Int
    private let vad: WebRTCVad
    private let onsetFrames: Int
    private let window: Int
    private let hangFrames: Int
    private let minDb: Double
    private var recent: [(TimeInterval, Bool)] = []
    public private(set) var active = false
    private var silentRun = 0
    public private(set) var lastSpeechT: TimeInterval = 0
    public private(set) var activeSince: TimeInterval?

    /// While the VAD hasn't confirmed activity (fewer than `onset_frames` voiced frames in the last
    /// `onset_window`), the start of the earliest voiced frame still in that window: the time the onset
    /// is back-dated to if enough later voiced frames confirm it. nil while active or with none there.
    public var pendingOnset: TimeInterval? { active ? nil : recent.first(where: { $0.1 })?.0 }

    public init(config: ListenMoreConfig) {
        let a = config.audio, v = config.vad
        rate = a.sampleRate
        frameS = Double(a.frameMs) / 1000
        vadRate = a.vadRate
        guard let instance = WebRTCVad(mode: a.vadAggressiveness) else {
            preconditionFailure("vad_aggressiveness must be 0...3")
        }
        vad = instance
        onsetFrames = v.onsetFrames
        window = v.onsetWindow
        hangFrames = max(1, Int((Double(v.hangoverMs) / Double(a.frameMs)).rounded(.toNearestOrEven)))
        minDb = v.minRmsDbfs
    }

    public func process(tEnd: TimeInterval, frame: ArraySlice<Float>) -> VadState {
        let tStart = tEnd - frameS
        let db = AudioMath.rmsDbfs(frame)
        let pcm = AudioMath.pcm16(AudioMath.resample(frame, from: rate, to: vadRate)[...])
        let raw = db >= minDb && (vad.isSpeech(pcm, sampleRate: vadRate) ?? false)
        recent.append((tStart, raw))
        if recent.count > window { recent.removeFirst(recent.count - window) }
        var st = VadState(raw: raw, active: active, onset: nil, offset: nil, dbfs: db)
        if raw {
            lastSpeechT = tEnd
            silentRun = 0
        } else {
            silentRun += 1
        }
        if !active {
            if recent.filter({ $0.1 }).count >= onsetFrames, let first = recent.first(where: { $0.1 }) {
                active = true
                activeSince = first.0
                st.onset = first.0
            }
        } else if silentRun >= hangFrames {
            active = false
            activeSince = nil
            st.offset = lastSpeechT
            recent.removeAll()
        }
        st.active = active
        return st
    }

    /// Forgets the utterance in progress (its stream went away): no offset is ever reported for it.
    public func reset() {
        recent.removeAll()
        active = false
        silentRun = 0
        activeSince = nil
    }
}
