#if MEETINGCARD_TEST_ID
import AppKit
import CoreAudio
import ListenMoreCore
import ListenMoreMac

/// Test build only: `scripts/build.sh --test-id` defines MEETINGCARD_TEST_ID, the shipping build
/// compiles none of this. Holding Option in the coach menu turns Settings… into this readout: the
/// mic's voice processing and ducking, the default input and output devices, and which processes run
/// audio input. It refreshes once a second while open and keeps nothing: no file, no log.
@MainActor
final class CoachDebugReadout: NSObject, NSWindowDelegate {
    static let shared = CoachDebugReadout()
    static let heading = "MeetingCard audio debug readout (test build)"
    static let menuTitle = "Audio Debug Readout…"

    private weak var mic: MicCapture?
    private weak var coach: CoachController?
    private let audioState = CoreAudioStateProvider()
    private var panel: NSPanel?
    private var label: NSTextField?
    private var timer: Timer?

    func attach(mic: MicCapture?, coach: CoachController) {
        self.mic = mic
        self.coach = coach
    }

    /// The Option alternate of Settings… (same key, Option added).
    func menuItem() -> NSMenuItem {
        let m = NSMenuItem(title: Self.menuTitle, action: #selector(show(_:)), keyEquivalent: ",")
        m.keyEquivalentModifierMask = [.command, .option]
        m.isAlternate = true
        m.target = self
        return m
    }

    @objc func show(_ sender: Any?) {
        let p = panel ?? makePanel()
        panel = p
        update()
        NSApp.activate()
        p.makeKeyAndOrderFront(nil)
        guard timer == nil else { return }
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.update() } }
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 260),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        p.title = Self.heading
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.delegate = self
        let l = NSTextField(wrappingLabelWithString: "")
        l.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        l.isSelectable = true
        if let content = p.contentView {
            l.frame = content.bounds.insetBy(dx: 12, dy: 12)
            l.autoresizingMask = [.width, .height]
            content.addSubview(l)
        }
        label = l
        p.center()
        return p
    }

    private func update() {
        label?.stringValue = lines().joined(separator: "\n")
    }

    func lines() -> [String] {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        var out = ["macOS \(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"]
        if let coach {
            out.append("Coach: \(coach.indicator.rawValue), capturing \(Self.yesNo(coach.service?.isCapturing ?? false))")
        }
        if let mic {
            out.append("Mic engine: \(mic.isRunning ? "running" : "stopped")")
            out.append("Voice processing (applied): \(mic.applied.map(Self.describe) ?? "off (mic engine stopped)")")
            out.append("Plan for this macOS: \(Self.describe(mic.processing))")
        } else {
            out.append("Mic engine: not created (coach off)")
        }
        out.append("Input:  \(Self.device(kAudioHardwarePropertyDefaultInputDevice, scope: kAudioObjectPropertyScopeInput))")
        out.append("Output: \(Self.device(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeOutput))")
        let owners = Set(audioState.snapshot().processes.filter(\.isRunningInput)
            .map { $0.bundleId ?? $0.owningBundleId ?? "pid \($0.pid)" }).sorted()
        out.append("Mic in use by: \(owners.isEmpty ? "nobody" : owners.joined(separator: ", "))")
        return out
    }

    static func describe(_ p: MicProcessing) -> String {
        guard p.voiceProcessing else { return "off" }
        guard let d = p.ducking else { return "on, ducking not reported" }
        return "on, advanced ducking \(d.advanced ? "on" : "off"), level \(d.level) (\(d.level.rawValue))"
    }

    static func yesNo(_ b: Bool) -> String { b ? "yes" : "no" }

    // MARK: Core Audio reads (properties only, no audio)

    static func device(_ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope) -> String {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != kAudioObjectUnknown else { return "none" }
        var parts = [string(id, kAudioObjectPropertyName) ?? "unnamed",
                     uint32(id, kAudioDevicePropertyTransportType).map(transport) ?? "transport ?"]
        if scope == kAudioObjectPropertyScopeOutput, let source = uint32(id, kAudioDevicePropertyDataSource, scope: scope) {
            parts.append(dataSource(source))
        }
        parts.append(float64(id, kAudioDevicePropertyNominalSampleRate).map { "\(Int($0)) Hz" } ?? "rate ?")
        if scope == kAudioObjectPropertyScopeOutput {
            let volume = float32(id, kAudioDevicePropertyVolumeScalar, scope: scope, element: kAudioObjectPropertyElementMain)
                ?? float32(id, kAudioDevicePropertyVolumeScalar, scope: scope, element: 1)
            parts.append(volume.map { String(format: "volume %.2f", $0) } ?? "volume ?")
        } else {
            parts.append("running \(yesNo((uint32(id, kAudioDevicePropertyDeviceIsRunningSomewhere) ?? 0) != 0))")
        }
        return parts.joined(separator: " · ")
    }

    static func transport(_ t: UInt32) -> String {
        let names: [UInt32: String] = [
            kAudioDeviceTransportTypeBuiltIn: "Built-in", kAudioDeviceTransportTypeBluetooth: "Bluetooth",
            kAudioDeviceTransportTypeBluetoothLE: "Bluetooth LE", kAudioDeviceTransportTypeUSB: "USB",
            kAudioDeviceTransportTypeAggregate: "Aggregate", kAudioDeviceTransportTypeVirtual: "Virtual",
            kAudioDeviceTransportTypeHDMI: "HDMI", kAudioDeviceTransportTypeDisplayPort: "DisplayPort",
            kAudioDeviceTransportTypeAirPlay: "AirPlay", kAudioDeviceTransportTypeThunderbolt: "Thunderbolt",
        ]
        return names[t] ?? fourCC(t)
    }

    static func dataSource(_ s: UInt32) -> String {
        switch fourCC(s) {
        case "ispk": "Internal Speakers"
        case "hdpn": "Headphones"
        case let code: "source \(code)"
        }
    }

    static func fourCC(_ v: UInt32) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((v >> UInt32($0)) & 0xFF) }
        return bytes.allSatisfy { $0 >= 32 && $0 < 127 } ? String(decoding: bytes, as: UTF8.self) : String(v)
    }

    static func address(_ selector: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope,
                        _ element: AudioObjectPropertyElement) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: element)
    }

    static func uint32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector,
                       scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> UInt32? {
        var a = address(selector, scope, kAudioObjectPropertyElementMain)
        var out: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &out) == noErr ? out : nil
    }

    static func float64(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> Float64? {
        var a = address(selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain)
        var out: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &out) == noErr ? out : nil
    }

    static func float32(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector, scope: AudioObjectPropertyScope,
                        element: AudioObjectPropertyElement) -> Float32? {
        var a = address(selector, scope, element)
        guard AudioObjectHasProperty(id, &a) else { return nil }
        var out: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        return AudioObjectGetPropertyData(id, &a, 0, nil, &size, &out) == noErr ? out : nil
    }

    static func string(_ id: AudioObjectID, _ selector: AudioObjectPropertySelector) -> String? {
        var a = address(selector, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain)
        var cf: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(id, &a, 0, nil, &size, &cf) == noErr, let cf else { return nil }
        return cf.takeRetainedValue() as String
    }
}
#endif
