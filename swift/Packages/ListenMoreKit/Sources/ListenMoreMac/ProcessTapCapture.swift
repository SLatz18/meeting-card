import AVFoundation
import CoreAudio

/// Chromium helper fallback: a private Core Audio process tap (macOS 14.2+) on the helpers' audio
/// process objects, read through a private aggregate device. Tapping only the parent PID yields no
/// data, so callers pass the helpers' objects. Needs the "System Audio Recording" permission.
@available(macOS 14.2, *)
final class ProcessTapCapture {
    enum TapError: Error {
        case status(String, OSStatus)
        case format
    }

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var ioProcID: AudioDeviceIOProcID?

    func start(processObjects: [AudioObjectID], queue: DispatchQueue, handler: @escaping (AVAudioPCMBuffer) -> Void) throws {
        let desc = CATapDescription(stereoMixdownOfProcesses: processObjects)
        desc.uuid = UUID()
        desc.muteBehavior = .unmuted
        desc.isPrivate = true

        var tap = AudioObjectID(kAudioObjectUnknown)
        try check("create tap", AudioHardwareCreateProcessTap(desc, &tap))
        tapID = tap

        var formatAddress = AudioObjectPropertyAddress(mSelector: kAudioTapPropertyFormat,
                                                       mScope: kAudioObjectPropertyScopeGlobal,
                                                       mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check("tap format", AudioObjectGetPropertyData(tap, &formatAddress, 0, nil, &size, &asbd))
        guard let format = AVAudioFormat(streamDescription: &asbd) else { throw TapError.format }

        var aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "ListenMoreKit call tap",
            kAudioAggregateDeviceUIDKey: UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,
                                               kAudioSubTapUIDKey: desc.uuid.uuidString]],
        ]
        if let outputUID = Self.defaultOutputDeviceUID() {
            aggregate[kAudioAggregateDeviceMainSubDeviceKey] = outputUID
            aggregate[kAudioAggregateDeviceSubDeviceListKey] = [[kAudioSubDeviceUIDKey: outputUID]]
        }
        var agg = AudioObjectID(kAudioObjectUnknown)
        try check("create aggregate", AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &agg))
        aggregateID = agg

        var procID: AudioDeviceIOProcID?
        try check("io proc", AudioDeviceCreateIOProcIDWithBlock(&procID, agg, queue) { _, input, _, _, _ in
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, bufferListNoCopy: input, deallocator: nil) else { return }
            handler(buffer)
        })
        ioProcID = procID
        try check("start", AudioDeviceStart(agg, procID))
    }

    func stop() {
        if aggregateID != kAudioObjectUnknown {
            if let ioProcID {
                AudioDeviceStop(aggregateID, ioProcID)
                AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
            }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        tapID = AudioObjectID(kAudioObjectUnknown)
    }

    deinit {
        stop()
    }

    private func check(_ step: String, _ status: OSStatus) throws {
        guard status == noErr else {
            CoachLog.record(.callAudioFailed(stage: .processTap, domain: LogToken("OSStatus"), code: Int(status)))
            stop()
            throw TapError.status(step, status)
        }
    }

    private static func defaultOutputDeviceUID() -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr
        else { return nil }
        var uidAddress = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceUID,
                                                    mScope: kAudioObjectPropertyScopeGlobal,
                                                    mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &uidAddress, 0, nil, &uidSize, &uid) == noErr, let uid else { return nil }
        return uid.takeRetainedValue() as String
    }
}
