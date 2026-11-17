import AVFoundation

/// The user's microphone via AVAudioEngine with Apple voice processing enabled, so call audio
/// coming out of the speakers is echo-cancelled and not attributed to the user.
public final class MicCapture {
    private let engine = AVAudioEngine()
    private let resampler: MonoResampler
    public private(set) var isRunning = false

    public init(sampleRate: Double) {
        resampler = MonoResampler(sampleRate: sampleRate)
    }

    public var voiceProcessingEnabled: Bool {
        engine.inputNode.isVoiceProcessingEnabled
    }

    /// `handler` runs on an audio thread with mono Float32 at the configured rate.
    public func start(handler: @escaping ([Float]) -> Void) throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        try input.setVoiceProcessingEnabled(true)
        let format = input.outputFormat(forBus: 0)
        let resampler = resampler
        input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
            let samples = resampler.convert(buffer)
            if !samples.isEmpty { handler(samples) }
        }
        engine.prepare()
        try engine.start()
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
