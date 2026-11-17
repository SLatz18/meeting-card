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
final class CoachDebugReadout: NSObject, NSWindowDelegate, NSMenuDelegate {
    static let shared = CoachDebugReadout()
    static let heading = "MeetingCard audio debug readout (test build)"
    static let menuTitle = "Audio Debug Readout…"
    static let diagnosticsHeading = "Speaker mic diagnostics (test build)"
    static let diagnosticsNote = "Speakers only. Headphones always run without voice processing; Bluetooth output always uses the built-in mic. Not saved: resets when the app quits."
    static let statusTag = 7301
    static let voiceProcessingChoices: [(title: String, value: Bool?)] = [("Standard", nil), ("On", true), ("Off", false)]
    static let micSourceChoices: [(title: String, value: MicDiagnostics.Source)] = [
        ("System default", .systemDefault), ("Built-in mic", .builtIn),
    ]

    private weak var mic: MicCapture?
    private weak var coach: CoachController?
    private let audioState = CoreAudioStateProvider()
    private var panel: NSPanel?
    private var label: NSTextField?
    private var voiceProcessingPopup: NSPopUpButton?
    private var micSourcePopup: NSPopUpButton?
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
        syncControls()
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

    /// The status line item of the coach menu; `menuNeedsUpdate` refreshes it each time the menu opens.
    func statusMenuItem() -> NSMenuItem {
        let m = NSMenuItem(title: Self.statusLine(for: mic), action: nil, keyEquivalent: "")
        m.isEnabled = false
        m.tag = Self.statusTag
        return m
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.item(withTag: Self.statusTag)?.title = Self.statusLine(for: mic)
    }

    private func makePanel() -> NSPanel {
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 620, height: 420),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        p.title = Self.heading
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.delegate = self
        let l = NSTextField(wrappingLabelWithString: "")
        l.font = .monospacedSystemFont(ofSize: NSFont.systemFontSize, weight: .regular)
        l.isSelectable = true
        l.preferredMaxLayoutWidth = 596
        l.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .vertical)
        label = l

        let heading = NSTextField(labelWithString: Self.diagnosticsHeading)
        heading.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
        let voiceProcessing = popup(Self.voiceProcessingChoices.map { $0.title }, action: #selector(voiceProcessingChanged(_:)))
        let micSource = popup(Self.micSourceChoices.map { $0.title }, action: #selector(micSourceChanged(_:)))
        voiceProcessingPopup = voiceProcessing
        micSourcePopup = micSource
        let note = NSTextField(wrappingLabelWithString: Self.diagnosticsNote)
        note.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
        note.textColor = .secondaryLabelColor
        note.preferredMaxLayoutWidth = 596

        let stack = NSStackView(views: [
            heading,
            row("Speakers: voice processing", voiceProcessing),
            row("Speakers: mic source", micSource),
            note,
            l,
        ])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 8
        stack.translatesAutoresizingMaskIntoConstraints = false
        if let content = p.contentView {
            content.addSubview(stack)
            NSLayoutConstraint.activate([
                stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 12),
                stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -12),
                stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 12),
                stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -12),
                note.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
                l.trailingAnchor.constraint(equalTo: stack.trailingAnchor),
            ])
        }
        syncControls()
        p.center()
        return p
    }

    private func popup(_ titles: [String], action: Selector) -> NSPopUpButton {
        let b = NSPopUpButton(frame: .zero, pullsDown: false)
        b.addItems(withTitles: titles)
        b.target = self
        b.action = action
        return b
    }

    private func row(_ title: String, _ control: NSView) -> NSStackView {
        let name = NSTextField(labelWithString: title)
        name.widthAnchor.constraint(equalToConstant: 190).isActive = true
        let r = NSStackView(views: [name, control])
        r.orientation = .horizontal
        r.alignment = .centerY
        r.spacing = 8
        return r
    }

    private func syncControls() {
        voiceProcessingPopup?.isEnabled = mic != nil
        micSourcePopup?.isEnabled = mic != nil
        guard let mic else { return }
        let d = mic.diagnostics
        if let i = Self.voiceProcessingChoices.firstIndex(where: { $0.value == d.speakerVoiceProcessing }) {
            voiceProcessingPopup?.selectItem(at: i)
        }
        if let i = Self.micSourceChoices.firstIndex(where: { $0.value == d.speakerMicSource }) {
            micSourcePopup?.selectItem(at: i)
        }
    }

    @objc private func voiceProcessingChanged(_ sender: Any?) { applyControls() }

    @objc private func micSourceChanged(_ sender: Any?) { applyControls() }

    private func applyControls() {
        guard let mic else { return }
        var d = mic.diagnostics
        if let i = voiceProcessingPopup?.indexOfSelectedItem, Self.voiceProcessingChoices.indices.contains(i) {
            d.speakerVoiceProcessing = Self.voiceProcessingChoices[i].value
        }
        if let i = micSourcePopup?.indexOfSelectedItem, Self.micSourceChoices.indices.contains(i) {
            d.speakerMicSource = Self.micSourceChoices[i].value
        }
        mic.diagnostics = d
        update()
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
            let state = mic.isMuted ? "muted" : (mic.plan == nil ? "closed" : "open")
            out.append("Mic: \(state), engine \(mic.isRunning ? "running" : "stopped"), restarts \(mic.restartCount)")
            let current = mic.plan
            let plan = current ?? mic.currentPlan()
            let would = current == nil ? " (would open)" : ""
            out.append("Route: \(plan.route.rawValue), mic source: \(plan.micSource.rawValue), voice processing \(plan.processing.voiceProcessing ? "on" : "off")\(would)")
            out.append("Voice processing (applied): \(mic.applied.map(Self.describe) ?? "off (no engine)")")
            out.append("Mic device: planned \(Self.deviceName(plan.device)), engine reports \(Self.deviceName(mic.deviceID))")
            let d = mic.diagnostics
            let vp = d.speakerVoiceProcessing.map { $0 ? "on" : "off" } ?? "standard"
            out.append("Diagnostics: speakers voice processing \(vp), mic source \(d.speakerMicSource.rawValue)")
        } else {
            out.append("Mic: not created (coach off)")
        }
        out.append("Input:  \(Self.device(kAudioHardwarePropertyDefaultInputDevice, scope: kAudioObjectPropertyScopeInput))")
        out.append("Output: \(Self.device(kAudioHardwarePropertyDefaultOutputDevice, scope: kAudioObjectPropertyScopeOutput))")
        let call = CoreAudioRoutes.outputCallState()
        let callRate = call.sampleRate.map { "\(Int($0)) Hz" } ?? "?"
        let callMode = mic.map { Self.yesNo($0.headphonesInCallMode()) } ?? "n/a"
        out.append("Output call state: transport \(call.transport?.rawValue ?? "none"), input stream active \(Self.yesNo(call.inputStreamActive)), sample rate \(callRate), call mode \(callMode)")
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

    static func deviceName(_ id: UInt32?) -> String {
        guard let id else { return "none" }
        return string(AudioObjectID(id), kAudioObjectPropertyName) ?? "id \(id)"
    }

    /// e.g. "Mic: built-in · voice processing off · bluetooth".
    static func statusLine(for mic: MicCapture?) -> String {
        guard let mic else { return "Mic: closed" }
        if mic.isMuted { return "Mic: muted" }
        guard let plan = mic.plan else { return "Mic: closed" }
        let route = routeName(plan.route)
        let source: String
        switch plan.micSource {
        case .systemDefault: source = "system default"
        case .builtIn: source = "built-in"
        case .none: return "Mic: none, call audio only · \(route)"
        }
        let processing = mic.applied ?? plan.processing
        let voice: String
        if !processing.voiceProcessing {
            voice = "off"
        } else if let d = processing.ducking {
            voice = "on (\(d.level))"
        } else {
            voice = "on"
        }
        return "Mic: \(source) · voice processing \(voice) · \(route)"
    }

    static func routeName(_ r: OutputRoute) -> String {
        switch r {
        case .speakers: "speakers"
        case .wiredHeadphones: "headphones"
        case .bluetooth: "bluetooth"
        case .other: "other output"
        }
    }

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
