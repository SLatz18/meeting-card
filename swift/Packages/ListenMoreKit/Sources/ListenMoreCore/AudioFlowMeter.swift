import Foundation

public enum AudioSource: String, Equatable, Sendable {
    case mic
    case call
}

/// What a stretch with no sound looked like.
public enum SilenceKind: String, Equatable, Sendable {
    /// No buffers arrived at all.
    case noBuffers
    /// Buffers arrived, but every sample was zero: what a refused System Audio Recording or Screen
    /// Recording permission delivers.
    case digitalSilence
}

/// Counts what a capture source delivers, for the diagnostics file: buffers, buffers with sound, and
/// the loudest peak. Nothing of the audio is kept: only these numbers. `record` is called from the
/// capture thread; `tick` and `finish` from the session, and return the events to log.
public final class AudioFlowMeter: @unchecked Sendable {
    /// Seconds between flow lines while capturing.
    public static let interval: TimeInterval = 10
    /// Seconds of digital silence (or no buffers) before a source is reported silent.
    public static let silenceAfter: TimeInterval = 15
    /// A buffer louder than this RMS counts as voiced.
    public static let voicedDbfs: Double = -50
    /// Below this peak a buffer is digital silence.
    public static let digitalSilencePeak: Float = 1e-6
    public static let floorDb = -120

    public let source: AudioSource
    private let watchesSilence: Bool
    private let lock = NSLock()
    private var windowStart: TimeInterval = 0
    private var buffers = 0
    private var voiced = 0
    private var peak: Float = 0
    private var soundSinceTick = false
    private var buffersSinceSound = 0
    private var lastSoundAt: TimeInterval = 0
    private var silentReported = false
    private var active = false

    /// `watchesSilence`: report a silent stream (the call's; a muted or closed mic is not a fault).
    public init(source: AudioSource, watchesSilence: Bool) {
        self.source = source
        self.watchesSilence = watchesSilence
    }

    public func start(now: TimeInterval) {
        lock.withLock {
            windowStart = now
            lastSoundAt = now
            buffers = 0
            voiced = 0
            peak = 0
            soundSinceTick = false
            buffersSinceSound = 0
            silentReported = false
            active = true
        }
    }

    public func record(_ samples: [Float]) {
        var p: Float = 0
        for s in samples { p = max(p, abs(s)) }
        let isVoiced = AudioMath.rmsDbfs(samples) > Self.voicedDbfs
        lock.withLock {
            guard active else { return }
            buffers += 1
            if isVoiced { voiced += 1 }
            peak = max(peak, p)
            if p > Self.digitalSilencePeak {
                soundSinceTick = true
            } else {
                buffersSinceSound += 1
            }
        }
    }

    /// The events due at `now`: a flow line once the interval has passed, a silence report once, and a
    /// note when sound returns after one.
    public func tick(now: TimeInterval) -> [CoachLogEvent] {
        lock.withLock {
            guard active else { return [] }
            var out: [CoachLogEvent] = []
            if soundSinceTick {
                soundSinceTick = false
                buffersSinceSound = 0
                lastSoundAt = now
                if silentReported {
                    silentReported = false
                    out.append(.callAudioSound(source: source))
                }
            }
            if now - windowStart >= Self.interval { out.append(flowLine(now: now)) }
            if watchesSilence, !silentReported, now - lastSoundAt >= Self.silenceAfter {
                silentReported = true
                out.append(.callAudioSilent(source: source, seconds: Int(now - lastSoundAt),
                                            kind: buffersSinceSound == 0 ? .noBuffers : .digitalSilence, buffers: buffersSinceSound))
            }
            return out
        }
    }

    /// The last partial window, when capture stops; then the meter goes idle.
    public func finish(now: TimeInterval) -> [CoachLogEvent] {
        lock.withLock {
            guard active else { return [] }
            active = false
            return buffers > 0 ? [flowLine(now: now)] : []
        }
    }

    private func flowLine(now: TimeInterval) -> CoachLogEvent {
        let db = peak > 0 ? max(Self.floorDb, Int((20 * log10(Double(peak))).rounded())) : Self.floorDb
        let event = CoachLogEvent.audioFlow(source: source, seconds: Int((now - windowStart).rounded()), buffers: buffers,
                                            voiced: voiced, peakDb: db)
        windowStart = now
        buffers = 0
        voiced = 0
        peak = 0
        return event
    }
}
