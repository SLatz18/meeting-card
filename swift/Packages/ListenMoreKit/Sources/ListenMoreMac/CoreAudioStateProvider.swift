import CoreAudio
import Foundation
import ListenMoreCore

/// Trigger input from Core Audio. Reads only "is running" flags and process identity:
/// `kAudioDevicePropertyDeviceIsRunningSomewhere` on the default input device, and per process
/// object (macOS 14.4+) `kAudioProcessPropertyIsRunningInput` / `IsRunningOutput`, PID and bundle
/// ID. No audio is read here, and no permission prompt is involved.
public final class CoreAudioStateProvider: AudioStateProvider {
    /// Process-table snapshots (for helpers without a bundle ID) are refreshed at most this often.
    let tableTTL: TimeInterval
    private var table: [ProcessEntry] = []
    private var tableAt: TimeInterval = -1e9

    public init(tableTTL: TimeInterval = 5) {
        self.tableTTL = tableTTL
    }

    public func snapshot() -> AudioStateSnapshot {
        let objects = Self.processObjectIDs()
        var needsOwner = false
        var raw: [(AudioObjectID, pid_t, String?, Bool, Bool)] = []
        for id in objects {
            let input = Self.scalar(id, kAudioProcessPropertyIsRunningInput, default: UInt32(0)) != 0
            let output = Self.scalar(id, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0
            guard input || output else { continue }
            let pid = Self.scalar(id, kAudioProcessPropertyPID, default: pid_t(-1))
            let bundle = Self.string(id, kAudioProcessPropertyBundleID).flatMap { $0.isEmpty ? nil : $0 }
            if bundle == nil { needsOwner = true }
            raw.append((id, pid, bundle, input, output))
        }
        if needsOwner {
            let now = ProcessInfo.processInfo.systemUptime
            if now - tableAt > tableTTL {
                table = ProcessTable.snapshot()
                tableAt = now
            }
        }
        let processes = raw.map { _, pid, bundle, input, output in
            AudioProcessState(pid: pid, bundleId: bundle,
                              owningBundleId: bundle == nil ? HelperProcessMatcher.owningBundleId(pid: pid, in: table) : nil,
                              isRunningInput: input, isRunningOutput: output)
        }
        return AudioStateSnapshot(defaultInputRunning: Self.defaultInputRunning(), processes: processes)
    }

    // MARK: Core Audio reads

    static func defaultInputRunning() -> Bool {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultInputDevice,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return false }
        return scalar(device, kAudioDevicePropertyDeviceIsRunningSomewhere, default: UInt32(0)) != 0
    }

    /// Core Audio process object for a pid (for process taps), or nil if the process has no audio client.
    public static func objectID(forPid pid: pid_t) -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var inPid = pid
        var out = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address,
                                                UInt32(MemoryLayout<pid_t>.size), &inPid, &size, &out)
        guard status == noErr, out != kAudioObjectUnknown else { return nil }
        return out
    }

    /// True if any of `pids` has a Core Audio process object currently running output.
    public static func anyOutputRunning(pids: Set<pid_t>) -> Bool {
        pids.contains { pid in
            objectID(forPid: pid).map { scalar($0, kAudioProcessPropertyIsRunningOutput, default: UInt32(0)) != 0 } ?? false
        }
    }

    static func processObjectIDs() -> [AudioObjectID] {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        let system = AudioObjectID(kAudioObjectSystemObject)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &ids) == noErr else { return [] }
        return Array(ids.prefix(Int(size) / MemoryLayout<AudioObjectID>.size))
    }

    static func scalar<T: FixedWidthInteger>(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, default value: T) -> T {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var out = value
        var size = UInt32(MemoryLayout<T>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &out) == noErr else { return value }
        return out
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, &cf) == noErr, let cf else { return nil }
        return cf.takeRetainedValue() as String
    }
}
