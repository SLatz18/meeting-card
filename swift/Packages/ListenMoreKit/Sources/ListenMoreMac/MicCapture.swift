import AVFoundation
import ListenMoreCore

/// The user's microphone via AVAudioEngine with Apple voice processing enabled (echo cancellation), so
/// call audio coming out of the speakers is not attributed to the user. Voice processing ducks other
/// audio while it runs; `processing` sets that to its minimum (`MicProcessing.plan`). Stopping
/// releases the input device and voice processing, and with them the ducking.
public final class MicCapture: MicSource {
    private let engine = AVAudioEngine()
    public let processing: MicProcessing
    public private(set) var isRunning = false
    /// What the running engine reports after start; nil while stopped.
    public private(set) var applied: MicProcessing?

    public init(processing: MicProcessing = .plan(macOS: ProcessInfo.processInfo.operatingSystemVersion)) {
        self.processing = processing
    }

    public var voiceProcessingEnabled: Bool {
        engine.inputNode.isVoiceProcessingEnabled
    }

    @available(macOS 14.0, *)
    public static func duckingConfiguration(_ ducking: MicProcessing.Ducking) -> AVAudioVoiceProcessingOtherAudioDuckingConfiguration {
        AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
            enableAdvancedDucking: ObjCBool(ducking.advanced),
            duckingLevel: AVAudioVoiceProcessingOtherAudioDuckingConfiguration.Level(rawValue: ducking.level.rawValue) ?? .min)
    }

    /// `handler` runs on an audio thread with mono Float32 at `sampleRate`.
    public func start(sampleRate: Int, handler: @escaping @Sendable ([Float]) -> Void) throws {
        guard !isRunning else { return }
        let input = engine.inputNode
        if processing.voiceProcessing {
            try input.setVoiceProcessingEnabled(true)
            if #available(macOS 14.0, *), let ducking = processing.ducking {
                input.voiceProcessingOtherAudioDuckingConfiguration = Self.duckingConfiguration(ducking)
            }
        }
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
        let applied = Self.readBack(input)
        self.applied = applied
        Log.capture.info("mic started, voice processing \(input.isVoiceProcessingEnabled, privacy: .public), advanced ducking \(applied.ducking?.advanced ?? false, privacy: .public), ducking level \(applied.ducking?.level.rawValue ?? -1, privacy: .public)")
    }

    /// Removes the tap before stopping, so no buffer is delivered after this returns.
    public func stop() {
        guard isRunning else { return }
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
        isRunning = false
        applied = nil
        Log.capture.info("mic stopped, voice processing \(self.engine.inputNode.isVoiceProcessingEnabled, privacy: .public)")
    }

    private static func readBack(_ input: AVAudioInputNode) -> MicProcessing {
        guard input.isVoiceProcessingEnabled else { return MicProcessing(voiceProcessing: false, ducking: nil) }
        guard #available(macOS 14.0, *) else { return MicProcessing(voiceProcessing: true, ducking: nil) }
        let c = input.voiceProcessingOtherAudioDuckingConfiguration
        let ducking = MicProcessing.DuckingLevel(rawValue: c.duckingLevel.rawValue)
            .map { MicProcessing.Ducking(advanced: c.enableAdvancedDucking.boolValue, level: $0) }
        return MicProcessing(voiceProcessing: true, ducking: ducking)
    }
}
