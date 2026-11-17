import Foundation

/// A Core Audio device as the mic policy sees it: an id and how it's connected.
public struct AudioDeviceInfo: Equatable, Sendable {
    public enum Transport: String, Equatable, Sendable {
        case builtIn, bluetooth, usb, other
    }

    public var id: UInt32
    public var transport: Transport

    public init(id: UInt32, transport: Transport) {
        self.id = id
        self.transport = transport
    }
}

/// The routes the mic policy reads: the default output and what it plays through, the default
/// input, and the Mac's own microphone if it has one (desktop Macs often don't).
public struct AudioRoutes: Equatable, Sendable {
    /// What a built-in output plays through.
    public enum OutputSource: String, Equatable, Sendable {
        case speakers, headphones, unknown
    }

    public var output: AudioDeviceInfo?
    public var outputSource: OutputSource
    public var defaultInput: AudioDeviceInfo?
    public var builtInInput: AudioDeviceInfo?

    public init(output: AudioDeviceInfo?, outputSource: OutputSource = .unknown, defaultInput: AudioDeviceInfo?,
                builtInInput: AudioDeviceInfo?) {
        self.output = output
        self.outputSource = outputSource
        self.defaultInput = defaultInput
        self.builtInInput = builtInInput
    }
}

/// Where other audio is heard.
public enum OutputRoute: String, Equatable, Sendable {
    case speakers, wiredHeadphones, bluetooth
    /// USB, HDMI, AirPlay, aggregate or no output: treated like speakers.
    case other

    public var isHeadphones: Bool { self == .wiredHeadphones || self == .bluetooth }
}

/// Which mic the coach opens.
public enum MicSourceKind: String, Equatable, Sendable {
    case systemDefault, builtIn
    /// No mic: the coach runs on call audio only.
    case none
}

/// Test-build switches for the speakers route (`.standard` everywhere else). Headphone routes ignore them.
public struct MicDiagnostics: Equatable, Sendable {
    public enum Source: String, CaseIterable, Equatable, Sendable {
        case systemDefault, builtIn
    }

    /// nil: the standard choice (voice processing on, from macOS 14).
    public var speakerVoiceProcessing: Bool?
    public var speakerMicSource: Source

    public init(speakerVoiceProcessing: Bool? = nil, speakerMicSource: Source = .systemDefault) {
        self.speakerVoiceProcessing = speakerVoiceProcessing
        self.speakerMicSource = speakerMicSource
    }

    public static let standard = MicDiagnostics()
}

/// What the mic does on the current routes.
/// - Headphones (wired or Bluetooth): no voice processing, so nothing is ducked. With Bluetooth
///   output the Mac's own mic is used, so a headset never switches to its hands-free profile; with no
///   built-in mic there is no mic at all.
/// - Speakers (and other outputs): voice processing at minimum ducking with the system's input, unless
///   the diagnostics say otherwise.
/// - A Bluetooth input is never opened on any route.
public struct MicPlan: Equatable, Sendable {
    public var route: OutputRoute
    public var micSource: MicSourceKind
    /// The device to open; nil with no mic.
    public var device: UInt32?
    public var processing: MicProcessing

    public init(route: OutputRoute, micSource: MicSourceKind, device: UInt32?, processing: MicProcessing) {
        self.route = route
        self.micSource = micSource
        self.device = device
        self.processing = processing
    }

    static let noProcessing = MicProcessing(voiceProcessing: false, ducking: nil)

    public static func route(_ r: AudioRoutes) -> OutputRoute {
        guard let output = r.output else { return .other }
        switch output.transport {
        case .bluetooth: return .bluetooth
        case .builtIn: return r.outputSource == .headphones ? .wiredHeadphones : .speakers
        case .usb, .other: return .other
        }
    }

    public static func plan(routes r: AudioRoutes, macOS: OperatingSystemVersion,
                            diagnostics: MicDiagnostics = .standard) -> MicPlan {
        let route = route(r)
        let builtIn = r.builtInInput.flatMap { $0.transport == .bluetooth ? nil : $0 }
        let systemDefault = r.defaultInput.flatMap { $0.transport == .bluetooth ? nil : $0 }
        var source: (MicSourceKind, AudioDeviceInfo?)
        switch route {
        case .bluetooth:
            source = builtIn.map { (.builtIn, $0) } ?? (.none, nil)
        case .wiredHeadphones:
            source = systemDefault.map { (.systemDefault, $0) } ?? builtIn.map { (.builtIn, $0) } ?? (.none, nil)
        case .speakers, .other:
            if diagnostics.speakerMicSource == .builtIn, let b = builtIn {
                source = (.builtIn, b)
            } else {
                source = systemDefault.map { (.systemDefault, $0) } ?? builtIn.map { (.builtIn, $0) } ?? (.none, nil)
            }
        }
        var processing = noProcessing
        if !route.isHeadphones, source.0 != .none {
            let standard = MicProcessing.plan(macOS: macOS)
            if standard.voiceProcessing && (diagnostics.speakerVoiceProcessing ?? true) { processing = standard }
        }
        return MicPlan(route: route, micSource: source.0, device: source.1?.id, processing: processing)
    }
}

/// When to reopen the mic after route changes: once they've been quiet for `debounce`, and only if
/// the plan differs from the open one or the open input stopped by itself. At most `maxBurst`
/// restarts happen in any `window`, so a flapping route can't cause a restart loop. The mic's own
/// device changes (voice processing adds a private aggregate device) leave the plan unchanged and
/// so never restart it.
public struct MicRestartPolicy: Equatable, Sendable {
    public enum Step: Equatable, Sendable {
        case idle
        case wait(until: TimeInterval)
        case evaluate
    }

    public var debounce: TimeInterval = 0.5
    public var window: TimeInterval = 30
    public var maxBurst = 3
    public private(set) var lastChange: TimeInterval?
    public private(set) var restarts: [TimeInterval] = []

    public init() {}

    /// A route change at `now`; returns when to evaluate.
    public mutating func changed(at now: TimeInterval) -> TimeInterval {
        lastChange = now
        return dueTime() ?? now + debounce
    }

    public func dueTime() -> TimeInterval? {
        guard let c = lastChange else { return nil }
        let due = c + debounce
        guard restarts.count >= maxBurst, let oldest = restarts.first else { return due }
        return max(due, oldest + window)
    }

    /// The timer fired at `now`.
    public mutating func fire(at now: TimeInterval) -> Step {
        guard let due = dueTime() else { return .idle }
        guard now + 1e-9 >= due else { return .wait(until: due) }
        lastChange = nil
        return .evaluate
    }

    public mutating func didRestart(at now: TimeInterval) {
        restarts.append(now)
        if restarts.count > maxBurst { restarts.removeFirst(restarts.count - maxBurst) }
    }

    /// Restart only for a different plan or an input that is no longer running.
    public static func shouldRestart(open: MicPlan?, next: MicPlan, inputRunning: Bool) -> Bool {
        guard let open else { return true }
        return open != next || (open.device != nil && !inputRunning)
    }
}
