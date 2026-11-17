import AVFoundation
import CoreMedia
import ListenMoreCore
import ScreenCaptureKit

/// Call output ("everyone else"): ScreenCaptureKit audio filtered by bundle to the session's app(s),
/// then the Chromium helper fallback (helper apps by bundle prefix / parent PID), then a Core Audio
/// process tap on the helpers. `CapturePlan.decide` makes every choice; this type only executes it.
/// Audio-only: only an `.audio` output is ever added, so SCK has nowhere to deliver video and no frame
/// is retained. Our own process is excluded twice: never in the filter, and `excludesCurrentProcessAudio`.
public final class CallCapture: NSObject, CallSource, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    public enum CaptureError: Error, Equatable {
        case noDisplay
        case nothingToCapture
        case processTapUnavailable
    }

    /// The only stream outputs this class adds.
    public static let outputTypes: [SCStreamOutputType] = [.audio]

    private let config: ListenMoreConfig
    private let queue = DispatchQueue(label: "com.listenmore.kit.call-audio", qos: .userInteractive)
    private let lock = NSLock()
    private var stream: SCStream?
    private var tap: AnyObject?
    private var resampler: MonoResampler?
    private var handler: (@Sendable ([Float]) -> Void)?
    public private(set) var stage: CaptureStage = .parentApps

    public init(config: ListenMoreConfig) {
        self.config = config
    }

    public static func streamConfiguration(sampleRate: Int) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.capturesAudio = true
        c.excludesCurrentProcessAudio = true
        c.sampleRate = sampleRate
        c.channelCount = 1
        // SCK still wants a video size; keep it tiny and slow. No screen output is added, so no frame
        // is delivered or kept.
        c.width = 2
        c.height = 2
        c.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        c.queueDepth = 3
        c.showsCursor = false
        return c
    }

    public func start(bundleIds: [String], stage: CaptureStage, sampleRate: Int,
                      handler: @escaping @Sendable ([Float]) -> Void) async throws {
        await stop()
        let resampler = MonoResampler(sampleRate: Double(sampleRate))
        lock.withLock {
            self.handler = handler
            self.resampler = resampler
            self.stage = stage
        }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let apps = content.applications.map { CapturableApp(pid: $0.processID, bundleId: $0.bundleIdentifier) }
        let table = stage >= .helperApps ? ProcessTable.snapshot() : []
        let targets = CapturePlan.targets(for: bundleIds, configured: config.captureTargets)
        switch CapturePlan.decide(apps: apps, bundleIds: bundleIds, targets: targets, stage: stage,
                                  processTable: table, ownPid: getpid()) {
        case .nothingToCapture:
            throw CaptureError.nothingToCapture
        case .processTap(let pids):
            try startProcessTap(pids: pids, resampler: resampler, handler: handler)
        case .screenCapture(let pids):
            guard let display = content.displays.first else { throw CaptureError.noDisplay }
            let wanted = Set(pids)
            let scApps = content.applications.filter { wanted.contains($0.processID) }
            let filter = SCContentFilter(display: display, including: scApps, exceptingWindows: [])
            let stream = SCStream(filter: filter, configuration: Self.streamConfiguration(sampleRate: sampleRate), delegate: self)
            for type in Self.outputTypes {
                try stream.addStreamOutput(self, type: type, sampleHandlerQueue: queue)
            }
            try await stream.startCapture()
            lock.withLock { self.stream = stream }
            Log.capture.info("call capture started: stage \(stage.rawValue, privacy: .public), apps count \(scApps.count, privacy: .public)")
        }
    }

    public func stop() async {
        let (stream, tap) = lock.withLock { () -> (SCStream?, AnyObject?) in
            defer {
                self.stream = nil
                self.tap = nil
                self.handler = nil
            }
            return (self.stream, self.tap)
        }
        if let stream { try? await stream.stopCapture() }
        if #available(macOS 14.2, *), let tap = tap as? ProcessTapCapture { tap.stop() }
    }

    /// PIDs of the helper processes for `bundleIds`.
    public func helperPids(bundleIds: [String]) async -> Set<pid_t> {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false) else { return [] }
        let apps = content.applications.map { CapturableApp(pid: $0.processID, bundleId: $0.bundleIdentifier) }
        let table = ProcessTable.snapshot()
        let wanted = Set(bundleIds.map { $0.lowercased() })
        var pids = Set<Int32>()
        for t in CapturePlan.targets(for: bundleIds, configured: config.captureTargets) where wanted.contains(t.bundleId.lowercased()) {
            pids.formUnion(CapturePlan.helperPids(of: t, apps: apps, processTable: table))
        }
        pids.remove(getpid())
        return pids
    }

    private func startProcessTap(pids: [Int32], resampler: MonoResampler, handler: @escaping @Sendable ([Float]) -> Void) throws {
        guard #available(macOS 14.2, *) else { throw CaptureError.processTapUnavailable }
        // Helpers' audio process objects come and go; the session restarts capture to re-resolve.
        let objects = pids.compactMap { CoreAudioStateProvider.objectID(forPid: $0) }
        guard !objects.isEmpty else { throw CaptureError.nothingToCapture }
        let tap = ProcessTapCapture()
        try tap.start(processObjects: objects, queue: queue) { buffer in
            let samples = resampler.convert(buffer)
            if !samples.isEmpty { handler(samples) }
        }
        lock.withLock { self.tap = tap }
        Log.capture.info("call capture started: process tap, objects count \(objects.count, privacy: .public)")
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let pcm = MonoResampler.pcmBuffer(from: sampleBuffer) else { return }
        let (resampler, handler) = lock.withLock { (self.resampler, self.handler) }
        guard let resampler, let handler else { return }
        let samples = resampler.convert(pcm)
        if !samples.isEmpty { handler(samples) }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        let code = (error as NSError).code
        Log.capture.error("call capture stopped with error code \(code, privacy: .public)")
    }
}
