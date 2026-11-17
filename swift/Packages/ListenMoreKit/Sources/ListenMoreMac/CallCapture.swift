import AVFoundation
import CoreMedia
import ListenMoreCore
import ScreenCaptureKit

/// Call output ("everyone else") via ScreenCaptureKit audio, filtered to the session's app(s).
/// Audio-only: only an `.audio` output is ever added, so SCK has nowhere to deliver video and no
/// frame is retained. Our own process is excluded twice: never in the filter, and
/// `excludesCurrentProcessAudio`.
public final class CallCapture: NSObject, SCStreamOutput, SCStreamDelegate {
    public enum CaptureError: Error {
        case noDisplay
        case noMatchingApps
        case noHelperAudioObjects
    }

    /// The only stream outputs this class adds.
    public static let outputTypes: [SCStreamOutputType] = [.audio]

    private let config: ListenMoreConfig
    private let resampler: MonoResampler
    private let queue = DispatchQueue(label: "com.slatz.meetingcard.coach.call-audio", qos: .userInteractive)
    private var stream: SCStream?
    private var tap: AnyObject?
    private var handler: (([Float]) -> Void)?
    public private(set) var stage: CaptureStage = .parentApps

    public init(config: ListenMoreConfig) {
        self.config = config
        resampler = MonoResampler(sampleRate: Double(config.audio.sampleRate))
    }

    public static func streamConfiguration(sampleRate: Int) -> SCStreamConfiguration {
        let c = SCStreamConfiguration()
        c.capturesAudio = true
        c.excludesCurrentProcessAudio = true
        c.sampleRate = sampleRate
        c.channelCount = 1
        // SCK still wants a video size; keep it tiny and slow. No screen output is added, so no
        // frame is delivered or kept.
        c.width = 2
        c.height = 2
        c.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        c.queueDepth = 3
        c.showsCursor = false
        return c
    }

    /// Starts (or restarts) capture of `bundleIds` at `stage`. `handler` runs on a capture queue.
    public func start(bundleIds: [String], stage: CaptureStage, handler: @escaping ([Float]) -> Void) async throws {
        await stop()
        self.handler = handler
        self.stage = stage
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
        let apps = content.applications.map { CapturableApp(pid: $0.processID, bundleId: $0.bundleIdentifier) }
        let processTable = stage >= .helperApps ? ProcessTable.snapshot() : []
        let targets = CapturePlan.targets(for: bundleIds, configured: config.captureTargets)
        let selected = CapturePlan.selectApps(from: apps, bundleIds: bundleIds, targets: targets,
                                              stage: stage, processTable: processTable, ownPid: getpid())

        if stage == .processTap {
            try startProcessTap(bundleIds: bundleIds, targets: targets, apps: apps, processTable: processTable)
            return
        }
        guard let display = content.displays.first else { throw CaptureError.noDisplay }
        let pids = Set(selected.map(\.pid))
        let scApps = content.applications.filter { pids.contains($0.processID) }
        guard !scApps.isEmpty else { throw CaptureError.noMatchingApps }

        let filter = SCContentFilter(display: display, including: scApps, exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: Self.streamConfiguration(sampleRate: config.audio.sampleRate),
                              delegate: self)
        for type in Self.outputTypes {
            try stream.addStreamOutput(self, type: type, sampleHandlerQueue: queue)
        }
        try await stream.startCapture()
        self.stream = stream
        Log.capture.info("call capture started: stage \(stage.rawValue, privacy: .public), apps count \(scApps.count, privacy: .public)")
    }

    public func stop() async {
        handler = nil
        if let stream {
            try? await stream.stopCapture()
            self.stream = nil
        }
        if let tap = tap as? ProcessTapCapture {
            tap.stop()
        }
        tap = nil
    }

    /// PIDs of the helper processes for `bundleIds` (for the fallback's "helpers audible" check).
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

    private func startProcessTap(bundleIds: [String], targets: [CaptureTarget], apps: [CapturableApp],
                                 processTable: [ProcessEntry]) throws {
        let wanted = Set(bundleIds.map { $0.lowercased() })
        var pids = Set<Int32>()
        for t in targets where wanted.contains(t.bundleId.lowercased()) {
            pids.formUnion(CapturePlan.helperPids(of: t, apps: apps, processTable: processTable))
        }
        pids.remove(getpid())
        // Helpers' audio process objects come and go; the caller restarts capture to re-resolve.
        let objects = pids.compactMap { CoreAudioStateProvider.objectID(forPid: $0) }
        guard !objects.isEmpty else { throw CaptureError.noHelperAudioObjects }
        let tap = ProcessTapCapture()
        let resampler = resampler
        try tap.start(processObjects: objects, queue: queue) { [weak self] buffer in
            let samples = resampler.convert(buffer)
            if !samples.isEmpty { self?.handler?(samples) }
        }
        self.tap = tap
        Log.capture.info("call capture started: process tap, objects count \(objects.count, privacy: .public)")
    }

    public func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio, sampleBuffer.isValid, let pcm = MonoResampler.pcmBuffer(from: sampleBuffer) else { return }
        let samples = resampler.convert(pcm)
        if !samples.isEmpty { handler?(samples) }
    }

    public func stream(_ stream: SCStream, didStopWithError error: Error) {
        let code = (error as NSError).code
        Log.capture.error("call capture stopped with error code \(code, privacy: .public)")
    }
}
