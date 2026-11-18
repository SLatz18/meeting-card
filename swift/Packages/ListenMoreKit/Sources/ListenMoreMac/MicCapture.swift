import AVFoundation
import AudioToolbox
import CoreAudio
import ListenMoreCore

/// The user's microphone, routed by `MicPlan`: no voice processing on headphones (nothing is
/// ducked) and the Mac's own mic with Bluetooth output (a headset never switches to its hands-free
/// profile); on speakers, Apple voice processing (echo cancellation) with other-audio ducking at its
/// minimum, unless test-build diagnostics say otherwise. Each open is a fresh AVAudioEngine; closing
/// stops and discards it, which releases the device and voice processing. Route changes reopen it.
/// Use from the main thread.
public final class MicCapture: MicSource {
    public let mic: RoutedMic

    public init(routes: AudioRouteSource = CoreAudioRoutes(),
                macOS: OperatingSystemVersion = ProcessInfo.processInfo.operatingSystemVersion) {
        mic = RoutedMic(routes: routes, opener: EngineMicOpener(), scheduler: MainQueueMicScheduler(), macOS: macOS)
        mic.events = { Self.log($0) }
    }

    public func start(sampleRate: Int, handler: @escaping @Sendable ([Float]) -> Void) throws {
        try mic.start(sampleRate: sampleRate, handler: handler)
    }

    public func stop() { mic.stop() }

    /// The coach Mute: closes the input device and keeps the session's handler; unmuting reopens it.
    @discardableResult
    public func setMuted(_ muted: Bool) -> Bool { mic.setMuted(muted) }

    /// Test-build switches for the speakers route; the shipping app never sets them.
    public var diagnostics: MicDiagnostics {
        get { mic.diagnostics }
        set { mic.setDiagnostics(newValue) }
    }

    public var isRunning: Bool { mic.isRunning }
    public var isMuted: Bool { mic.isMuted }
    public var plan: MicPlan? { mic.plan }
    public var applied: MicProcessing? { mic.applied }
    public var deviceID: UInt32? { mic.deviceID }
    public var restartCount: Int { mic.restartCount }
    /// Inputs set aside for delivering no sound (a closed lid), until the routes change or the call ends.
    public var unavailableInputs: Set<UInt32> { mic.unavailableInputs }
    public var builtInMicPresent: Bool { mic.routes.snapshot().builtInInput != nil }
    /// How the default output is connected (USB headsets count as speakers; this tells them apart).
    public var outputTransport: AudioDeviceInfo.Transport? { mic.routes.snapshot().output?.transport }
    /// Bluetooth headphones on a Mac with no built-in mic: no mic, so mic-based cues are off.
    public var noMicStatus: Bool {
        NoMicNotice.showsStatus(route: mic.plan?.route, micSource: mic.plan?.micSource, builtInMicPresent: builtInMicPresent)
    }
    /// The input devices this app is actually doing IO on, read back from Core Audio (not the request).
    public func inputDevicesInUse() -> [UInt32]? { CoreAudioRoutes.inputDevicesInUse() }
    public func currentPlan() -> MicPlan { mic.currentPlan() }

    /// The default output is a Bluetooth headset in its hands-free (call) mode, and not because of
    /// the coach's mic. Core Audio properties only.
    public func headphonesInCallMode() -> Bool {
        guard mic.isStarted else { return false }
        let s = CoreAudioRoutes.outputCallState()
        return CallModeHint.isCallMode(outputTransport: s.transport, outputInputStreamActive: s.inputStreamActive,
                                       outputSampleRate: s.sampleRate, outputDevice: s.device,
                                       ourMicDevice: mic.deviceID ?? mic.plan?.device)
    }

    @available(macOS 14.0, *)
    public static func duckingConfiguration(_ ducking: MicProcessing.Ducking) -> AVAudioVoiceProcessingOtherAudioDuckingConfiguration {
        AVAudioVoiceProcessingOtherAudioDuckingConfiguration(
            enableAdvancedDucking: ObjCBool(ducking.advanced),
            duckingLevel: AVAudioVoiceProcessingOtherAudioDuckingConfiguration.Level(rawValue: ducking.level.rawValue) ?? .min)
    }

    static func log(_ event: RoutedMic.Event) {
        switch event {
        case let .opened(plan, applied, deviceID):
            let voiceProcessing = applied?.voiceProcessing ?? false
            let ducking = applied?.ducking
            CoachLog.record(.micOpened(route: LogToken.route(plan.route), source: LogToken.micSource(plan.micSource),
                                       voiceProcessing: voiceProcessing,
                                       device: deviceID.flatMap { CoreAudioRoutes.string($0, kAudioObjectPropertyName) }.map { LogToken.device($0) }))
            Log.capture.info("mic open: route \(plan.route.rawValue, privacy: .public), micSource \(plan.micSource.rawValue, privacy: .public), voiceProcessing \(voiceProcessing, privacy: .public), advanced ducking \(ducking?.advanced ?? false, privacy: .public), ducking level \(ducking?.level.rawValue ?? -1, privacy: .public)")
        case .closed:
            CoachLog.record(.micClosed)
            Log.capture.info("mic closed")
        case let .restarted(count):
            CoachLog.record(.micRouteRestart(count: count))
            Log.capture.info("mic route restart, count \(count, privacy: .public)")
        case let .openFailed(plan):
            CoachLog.record(.micOpenFailed(route: LogToken.route(plan.route), source: LogToken.micSource(plan.micSource)))
            Log.capture.error("mic open failed: route \(plan.route.rawValue, privacy: .public), micSource \(plan.micSource.rawValue, privacy: .public)")
        case .inputSilent:
            CoachLog.record(.micSilent)
            Log.capture.info("mic delivered no sound: built-in mic set aside, call audio only")
        }
    }
}

struct EngineMicOpener: MicInputOpening {
    func open(_ plan: MicPlan, sampleRate: Int, handler: @escaping @Sendable ([Float]) -> Void,
              onStopped: @escaping @Sendable () -> Void) throws -> MicInput {
        try EngineMicInput(plan: plan, sampleRate: sampleRate, handler: handler, onStopped: onStopped)
    }
}

/// One fresh AVAudioEngine for one plan. Voice processing first (when the plan has it), then its
/// ducking, then the device, then the tap; `stop()` removes the tap before stopping, so no buffer
/// is delivered after it returns.
final class EngineMicInput: MicInput {
    enum OpenError: Error {
        case noInputUnit
        case device(OSStatus)
        case noFormat
    }

    private let engine = AVAudioEngine()
    private var observer: NSObjectProtocol?
    private(set) var applied = MicProcessing(voiceProcessing: false, ducking: nil)
    private(set) var deviceID: UInt32?

    var isRunning: Bool { engine.isRunning }

    init(plan: MicPlan, sampleRate: Int, handler: @escaping @Sendable ([Float]) -> Void,
         onStopped: @escaping @Sendable () -> Void) throws {
        let input = engine.inputNode
        do {
            if plan.processing.voiceProcessing {
                try input.setVoiceProcessingEnabled(true)
                if #available(macOS 14.0, *), let ducking = plan.processing.ducking {
                    input.voiceProcessingOtherAudioDuckingConfiguration = MicCapture.duckingConfiguration(ducking)
                }
            }
            if let device = plan.device {
                // Voice processing follows the system devices; only a different mic is asked for there.
                if !plan.processing.voiceProcessing {
                    try Self.setDevice(device, on: input)
                } else if plan.micSource == .builtIn {
                    try? Self.setDevice(device, on: input)
                }
            }
            let format = input.outputFormat(forBus: 0)
            guard format.sampleRate > 0, format.channelCount > 0 else { throw OpenError.noFormat }
            let resampler = MonoResampler(sampleRate: Double(sampleRate))
            input.installTap(onBus: 0, bufferSize: 2048, format: format) { buffer, _ in
                let samples = resampler.convert(buffer)
                if !samples.isEmpty { handler(samples) }
            }
            observer = NotificationCenter.default.addObserver(forName: .AVAudioEngineConfigurationChange, object: engine,
                                                              queue: nil) { _ in onStopped() }
            engine.prepare()
            try engine.start()
        } catch {
            release()
            throw error
        }
        applied = Self.readBack(input)
        deviceID = Self.currentDevice(of: input)
    }

    func stop() {
        release()
    }

    private func release() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        try? engine.inputNode.setVoiceProcessingEnabled(false)
    }

    static func setDevice(_ device: UInt32, on input: AVAudioInputNode) throws {
        guard let unit = input.audioUnit else { throw OpenError.noInputUnit }
        var id = AudioDeviceID(device)
        let status = AudioUnitSetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                                          &id, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard status == noErr else { throw OpenError.device(status) }
    }

    static func currentDevice(of input: AVAudioInputNode) -> UInt32? {
        guard let unit = input.audioUnit else { return nil }
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioUnitGetProperty(unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0, &id, &size)
        return status == noErr && id != 0 ? id : nil
    }

    static func readBack(_ input: AVAudioInputNode) -> MicProcessing {
        guard input.isVoiceProcessingEnabled else { return MicProcessing(voiceProcessing: false, ducking: nil) }
        guard #available(macOS 14.0, *) else { return MicProcessing(voiceProcessing: true, ducking: nil) }
        let c = input.voiceProcessingOtherAudioDuckingConfiguration
        let ducking = MicProcessing.DuckingLevel(rawValue: c.duckingLevel.rawValue)
            .map { MicProcessing.Ducking(advanced: c.enableAdvancedDucking.boolValue, level: $0) }
        return MicProcessing(voiceProcessing: true, ducking: ducking)
    }
}

final class MainQueueMicScheduler: MicScheduler {
    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func schedule(after delay: TimeInterval, _ work: @escaping () -> Void) {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
