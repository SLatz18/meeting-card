import AVFoundation
import ListenMoreCore

/// The user's microphone via AVAudioEngine with Apple voice processing enabled (echo cancellation), so
/// call audio coming out of the speakers is not attributed to the user.
public final class MicCapture: MicSource {
    private let engine = AVAudioEngine()
    public private(set) var isRunning = false

    public init() {}

    public var voiceProcessingEnabled: Bool {
        engine.inputNode.isVoiceProcessingEnabled
    }

    /// `handler` runs on an audio thread with mono Float32 at `sampleRate`.
    public func start(sampleRate: Int, handler: @escaping @Sendable ([Float]) -> Void) throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        let format = input.outputFormat(forBus: 0)
        let resampler = MonoResampler(sampleRate: Double(sampleRate))
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            let samples = resampler.convert(buffer)
            if !samples.isEmpty { handler(samples) }
        }
        engine.prepare()
        do {
            try engine.start()
        } catch {
            input.removeTap(onBus: 0)
            try? input.setVoiceProcessingEnabled(false)
            throw error
        }
        isRunning = true
        Log.capture.info("mic started, voice processing \(input.isVoiceProcessingEnabled, privacy: .public)")
    }

    /// Removes the tap before stopping, so no buffer is delivered after this returns.
    public func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        isRunning = false
        Log.capture.info("mic stopped")
    }
}
