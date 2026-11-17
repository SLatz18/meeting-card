import Foundation

/// An application ScreenCaptureKit offers for an audio filter (pid + bundle ID of an `SCRunningApplication`).
public struct CapturableApp: Equatable, Hashable, Sendable {
    public var pid: Int32
    public var bundleId: String

    public init(pid: Int32, bundleId: String) {
        self.pid = pid
        self.bundleId = bundleId
    }
}

/// How hard we are trying to get a browser's call audio (see the Kit README, "Chromium helper audio").
public enum CaptureStage: Int, Comparable, CaseIterable, Sendable {
    /// SCK filter with the parent app(s) only. Community reports say this already includes helper audio.
    case parentApps
    /// SCK filter plus helper apps matched by bundle-ID prefix or parent PID, if SCK lists them.
    case helperApps
    /// Core Audio process tap on the helpers' audio process objects (macOS 14.2+).
    case processTap

    public static func < (a: CaptureStage, b: CaptureStage) -> Bool { a.rawValue < b.rawValue }
}

public enum CapturePlan {
    /// Capture targets for a session: the configured ones, plus an ad-hoc target for an app the
    /// "coach any app" option picked up, so helper matching works for it too.
    public static func targets(for bundleIds: [String], configured: [CaptureTarget]) -> [CaptureTarget] {
        var out = configured
        for b in bundleIds where !configured.contains(where: { $0.bundleId.caseInsensitiveCompare(b) == .orderedSame }) {
            out.append(CaptureTarget(name: "app", kind: .native, processName: "", bundleId: b))
        }
        return out
    }

    /// Picks the SCK applications to include for `bundleIds`. Our own process is never included.
    public static func selectApps(from apps: [CapturableApp], bundleIds: [String], targets: [CaptureTarget],
                                  stage: CaptureStage, processTable: [ProcessEntry], ownPid: Int32) -> [CapturableApp] {
        let wanted = Set(bundleIds.map { $0.lowercased() })
        var owned = wanted
        for t in targets where wanted.contains(t.bundleId.lowercased()) {
            owned.formUnion(t.ownedBundleIds.map { $0.lowercased() })
        }
        var pids = Set(apps.filter { owned.contains($0.bundleId.lowercased()) }.map(\.pid))
        if stage >= .helperApps {
            for t in targets where wanted.contains(t.bundleId.lowercased()) {
                pids.formUnion(helperPids(of: t, apps: apps, processTable: processTable))
            }
        }
        pids.remove(ownPid)
        return apps.filter { pids.contains($0.pid) }
    }

    public enum Decision: Equatable {
        /// ScreenCaptureKit display filter including exactly these application PIDs.
        case screenCapture(pids: [Int32])
        /// Core Audio process tap on these helper PIDs.
        case processTap(pids: [Int32])
        case nothingToCapture
    }

    /// What `CallCapture` should do for `bundleIds` at `stage`. Our own PID is never included.
    public static func decide(apps: [CapturableApp], bundleIds: [String], targets: [CaptureTarget], stage: CaptureStage,
                              processTable: [ProcessEntry], ownPid: Int32) -> Decision {
        if stage == .processTap {
            let wanted = Set(bundleIds.map { $0.lowercased() })
            var pids = Set<Int32>()
            for t in targets where wanted.contains(t.bundleId.lowercased()) {
                pids.formUnion(helperPids(of: t, apps: apps, processTable: processTable))
            }
            pids.remove(ownPid)
            return pids.isEmpty ? .nothingToCapture : .processTap(pids: pids.sorted())
        }
        let selected = selectApps(from: apps, bundleIds: bundleIds, targets: targets, stage: stage,
                                  processTable: processTable, ownPid: ownPid)
        return selected.isEmpty ? .nothingToCapture : .screenCapture(pids: selected.map(\.pid).sorted())
    }

    /// Helper PIDs for a target, from SCK's app list (bundle prefix) and the process table (prefix or ppid).
    public static func helperPids(of target: CaptureTarget, apps: [CapturableApp], processTable: [ProcessEntry]) -> Set<Int32> {
        let fromApps = apps.map { ProcessEntry(pid: $0.pid, parentPid: 0, bundleId: $0.bundleId) }
        var table = processTable
        let known = Set(table.map(\.pid))
        table += fromApps.filter { !known.contains($0.pid) }
        return Set(HelperProcessMatcher.helpers(of: target, in: table).map(\.pid))
    }
}

/// Decides when to escalate the capture stage: the call stream has been silent for `silenceS`
/// while Core Audio says the target's helpers are producing output, i.e. per-app filtering missed them.
public struct CaptureFallbackPolicy: Sendable {
    public let silenceS: TimeInterval
    public let silenceDbfs: Float
    public private(set) var stage: CaptureStage = .parentApps
    private var silentSince: TimeInterval?

    public init(silenceS: TimeInterval = 4, silenceDbfs: Float = -70) {
        self.silenceS = silenceS
        self.silenceDbfs = silenceDbfs
    }

    public static func rmsDbfs(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return -.infinity }
        let ms = samples.reduce(Float(0)) { $0 + $1 * $1 } / Float(samples.count)
        return ms > 0 ? 10 * log10(ms) : -.infinity
    }

    /// Feed one observation; returns the new stage when it should escalate, else nil.
    public mutating func observe(callDbfs: Float, helpersAudible: Bool, now: TimeInterval) -> CaptureStage? {
        guard helpersAudible, callDbfs < silenceDbfs else {
            silentSince = nil
            return nil
        }
        let since = silentSince ?? now
        silentSince = since
        guard now - since >= silenceS, let next = CaptureStage(rawValue: stage.rawValue + 1) else { return nil }
        stage = next
        silentSince = nil
        return next
    }

    public mutating func reset() {
        stage = .parentApps
        silentSince = nil
    }
}
