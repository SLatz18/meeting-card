import CoreAudio
import Foundation
import ListenMoreCore

/// The routes the mic policy needs, from Core Audio properties only (no audio, no permission): the
/// default output and whether a built-in output plays through speakers or headphones, the default
/// input, and the Mac's own microphone. Reports changes to the default devices, the device list and
/// the output's data source (the headphone jack).
public final class CoreAudioRoutes: AudioRouteSource {
    private var onChange: (() -> Void)?
    private var listening = false
    private var watchedOutput = AudioObjectID(kAudioObjectUnknown)

    public init() {}

    deinit { stopObserving() }

    public func snapshot() -> AudioRoutes {
        let output = Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
        let input = Self.defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
        return AudioRoutes(output: output.map(Self.info), outputSource: output.map(Self.outputSource) ?? .unknown,
                           defaultInput: input.map(Self.info), builtInInput: Self.builtInInput().map(Self.info))
    }

    public func observe(_ onChange: @escaping () -> Void) {
        self.onChange = onChange
        guard !listening else { return }
        listening = true
        for selector in Self.systemSelectors {
            var address = Self.address(selector)
            AudioObjectAddPropertyListener(AudioObjectID(kAudioObjectSystemObject), &address, Self.listener, context)
        }
        watchOutputSource()
    }

    public func stopObserving() {
        onChange = nil
        guard listening else { return }
        listening = false
        for selector in Self.systemSelectors {
            var address = Self.address(selector)
            AudioObjectRemovePropertyListener(AudioObjectID(kAudioObjectSystemObject), &address, Self.listener, context)
        }
        unwatchOutputSource()
    }

    // MARK: listening

    static let systemSelectors = [kAudioHardwarePropertyDefaultOutputDevice, kAudioHardwarePropertyDefaultInputDevice,
                                  kAudioHardwarePropertyDevices]
    static let outputSourceAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDataSource,
                                                               mScope: kAudioObjectPropertyScopeOutput,
                                                               mElement: kAudioObjectPropertyElementMain)

    private var context: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }

    /// Core Audio calls this on its own thread; the work hops to the main queue.
    private static let listener: AudioObjectPropertyListenerProc = { _, _, _, context in
        guard let context else { return noErr }
        let routes = Unmanaged<CoreAudioRoutes>.fromOpaque(context).takeUnretainedValue()
        DispatchQueue.main.async { routes.changed() }
        return noErr
    }

    private func changed() {
        guard listening else { return }
        watchOutputSource()
        onChange?()
    }

    private func watchOutputSource() {
        let output = Self.defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) ?? AudioObjectID(kAudioObjectUnknown)
        guard output != watchedOutput else { return }
        unwatchOutputSource()
        guard output != kAudioObjectUnknown else { return }
        var address = Self.outputSourceAddress
        if AudioObjectHasProperty(output, &address) {
            AudioObjectAddPropertyListener(output, &address, Self.listener, context)
            watchedOutput = output
        }
    }

    private func unwatchOutputSource() {
        guard watchedOutput != kAudioObjectUnknown else { return }
        var address = Self.outputSourceAddress
        AudioObjectRemovePropertyListener(watchedOutput, &address, Self.listener, context)
        watchedOutput = AudioObjectID(kAudioObjectUnknown)
    }

    /// What the call-mode hint reads about the default output: its transport, whether any of its
    /// input streams is doing IO, and its nominal sample rate.
    public struct OutputCallState: Equatable, Sendable {
        public var device: UInt32?
        public var transport: AudioDeviceInfo.Transport?
        public var inputStreamActive: Bool
        public var sampleRate: Double?
    }

    public static func outputCallState() -> OutputCallState {
        guard let output = defaultDevice(kAudioHardwarePropertyDefaultOutputDevice) else {
            return OutputCallState(device: nil, transport: nil, inputStreamActive: false, sampleRate: nil)
        }
        return OutputCallState(device: output, transport: info(output).transport,
                               inputStreamActive: inputStreams(of: output).contains { (uint32($0, kAudioStreamPropertyIsActive) ?? 0) != 0 },
                               sampleRate: float64(output, kAudioDevicePropertyNominalSampleRate))
    }

    static func inputStreams(of device: AudioObjectID) -> [AudioStreamID] {
        var address = Self.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    static func float64(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Double? {
        var address = Self.address(selector)
        var out: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &out) == noErr ? out : nil
    }

    // MARK: reads

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func defaultDevice(_ selector: AudioObjectPropertySelector) -> AudioObjectID? {
        var address = Self.address(selector)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return nil }
        return id
    }

    static func info(_ id: AudioObjectID) -> AudioDeviceInfo {
        AudioDeviceInfo(id: id, transport: transport(uint32(id, kAudioDevicePropertyTransportType) ?? 0))
    }

    static func transport(_ t: UInt32) -> AudioDeviceInfo.Transport {
        switch t {
        case kAudioDeviceTransportTypeBuiltIn: return .builtIn
        case kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE: return .bluetooth
        case kAudioDeviceTransportTypeUSB: return .usb
        default: return .other
        }
    }

    /// 'hdpn' / 'ispk' when the device reports a data source; otherwise its UID, which names the
    /// built-in headphone and speaker devices on Macs that make them separate devices.
    static func outputSource(_ id: AudioObjectID) -> AudioRoutes.OutputSource {
        var address = outputSourceAddress
        if AudioObjectHasProperty(id, &address) {
            var source: UInt32 = 0
            var size = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(id, &address, 0, nil, &size, &source) == noErr {
                if source == fourCC("hdpn") { return .headphones }
                if source == fourCC("ispk") { return .speakers }
            }
        }
        let uid = string(id, kAudioDevicePropertyDeviceUID)?.lowercased() ?? ""
        if uid.contains("headphone") { return .headphones }
        if uid.contains("speaker") { return .speakers }
        return .unknown
    }

    /// The first built-in device with input streams.
    static func builtInInput() -> AudioObjectID? {
        var address = Self.address(kAudioHardwarePropertyDevices)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return nil }
        return ids.first { id in
            guard uint32(id, kAudioDevicePropertyTransportType) == kAudioDeviceTransportTypeBuiltIn else { return false }
            var streams = Self.address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeInput)
            var streamsSize: UInt32 = 0
            return AudioObjectGetPropertyDataSize(id, &streams, 0, nil, &streamsSize) == noErr && streamsSize > 0
        }
    }

    static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> UInt32? {
        var address = Self.address(selector)
        var out: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &address, 0, nil, &size, &out) == noErr ? out : nil
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = Self.address(selector)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &cf) == noErr, let cf else { return nil }
        return cf.takeRetainedValue() as String
    }

    static func fourCC(_ s: String) -> UInt32 {
        s.utf8.reduce(0) { $0 << 8 | UInt32($1) }
    }
}
