import Foundation

/// What `CoachSession` polls to drive `CoachTrigger`, and what the Chromium helper fallback asks.
public protocol CallSignal: AnyObject {
    /// App keys (lowercased bundle IDs, as `TriggerSettings.appKey` makes them) with a live call, and
    /// whether the default input device is running.
    func poll(_ settings: TriggerSettings) -> (liveApps: Set<String>, inputRunning: Bool)
    /// True if helper processes of the captured app (not the app process itself) are producing
    /// output, i.e. per-app capture may be missing their audio.
    func helpersAudible(bundleIds: [String]) -> Bool
    /// The Core Audio state behind the last `poll`, for the detection diagnostics; nil for signals
    /// that don't read it.
    func detectionSnapshot() -> AudioStateSnapshot?
}

public extension CallSignal {
    func detectionSnapshot() -> AudioStateSnapshot? { nil }
}

/// Core Audio running state: an app (with its helpers) has input AND output running. Used by hosts
/// that coach any call app (MeetingCard). Reads only "is running" flags, never audio.
public final class AudioActivitySignal: CallSignal {
    public let provider: AudioStateProvider
    private var last = AudioStateSnapshot(defaultInputRunning: false, processes: [])

    public init(provider: AudioStateProvider) {
        self.provider = provider
    }

    public func poll(_ settings: TriggerSettings) -> (liveApps: Set<String>, inputRunning: Bool) {
        last = provider.snapshot()
        let live = Set(settings.group(last).filter { $0.value.both }.keys)
        return (live, last.defaultInputRunning)
    }

    public func detectionSnapshot() -> AudioStateSnapshot? { last }

    public func helpersAudible(bundleIds: [String]) -> Bool {
        last.processes.contains { p in
            guard p.isRunningOutput else { return false }
            let id = p.bundleId ?? p.owningBundleId ?? ""
            return bundleIds.contains { parent in
                BundleIds.belongs(id, to: parent) && (p.bundleId == nil || id.lowercased() != parent.lowercased())
            }
        }
    }
}

/// Window titles plus per-process output flags (`MeetingDetector`): Zoom / native app meeting window
/// titles, or a Meet tab, with the app producing audio. Used by the standalone menu-bar app.
public final class WindowTitleSignal: CallSignal {
    public let probe: MeetingProbe
    public let targets: [CaptureTarget]
    public let meetTitleRegex: String
    public private(set) var lastDetection: Detection = .inactive

    public init(probe: MeetingProbe, targets: [CaptureTarget], meetTitleRegex: String) {
        self.probe = probe
        self.targets = targets
        self.meetTitleRegex = meetTitleRegex
    }

    public func poll(_ settings: TriggerSettings) -> (liveApps: Set<String>, inputRunning: Bool) {
        lastDetection = MeetingDetector.detect(windows: probe.windows(), audioActive: probe.audioActive(),
                                               targets: targets, meetTitleRegex: meetTitleRegex)
        let key = lastDetection.bundleId.flatMap { id in
            settings.excludedBundleIds.contains { BundleIds.belongs(id, to: $0) } ? nil : id.lowercased()
        }
        return (Set([key].compactMap { $0 }), true)
    }

    public func helpersAudible(bundleIds: [String]) -> Bool {
        probe.audioActive().contains { bundle, on in
            on && bundleIds.contains { bundle.lowercased().hasPrefix($0.lowercased() + ".") }
        }
    }
}
