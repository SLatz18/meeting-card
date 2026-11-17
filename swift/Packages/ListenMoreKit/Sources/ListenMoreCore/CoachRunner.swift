import Foundation

/// Mic + call-audio capture as the runner sees it. The macOS implementation wraps AVAudioEngine and
/// ScreenCaptureKit; tests use a fake. `stop` must stop delivering audio before it returns.
public protocol CoachCapture: AnyObject {
    func start(bundleIds: [String], onMic: @escaping ([Float]) -> Void, onCall: @escaping ([Float]) -> Void)
    func stop()
}

/// Turns trigger actions into capture + engine lifecycles. Capture and the engine (and with it the
/// OpenAI sessions) run only while a session is active AND not paused: Pause, Stop and switching
/// the coach off all stop capture and close the streams, so nothing is captured or sent.
public final class CoachRunner {
    public let config: ListenMoreConfig
    public let engine: CoachEngine
    public let capture: CoachCapture
    let readKey: () -> APIKey?
    public private(set) var isCapturing = false
    public private(set) var captureBundleIds: [String] = []

    public init(config: ListenMoreConfig, engine: CoachEngine, capture: CoachCapture, readKey: @escaping () -> APIKey?) {
        self.config = config
        self.engine = engine
        self.capture = capture
        self.readKey = readKey
    }

    /// `session` is the trigger's session after the actions were produced.
    public func apply(_ actions: [TriggerAction], session: CoachSession?) {
        for a in actions {
            switch a {
            case .start(let s):
                begin(s)
            case .pause(true), .stop:
                end()
            case .pause(false):
                if let session { begin(session) }
            }
        }
    }

    /// What to capture for a session: its app, or every configured call app for a manual start
    /// with no call yet.
    public func bundleIds(for s: CoachSession) -> [String] {
        s.appKey.map { [$0] } ?? config.captureTargets.map(\.bundleId)
    }

    private func begin(_ s: CoachSession) {
        end()
        captureBundleIds = bundleIds(for: s)
        engine.start(config: config, apiKey: readKey())
        let engine = engine
        capture.start(bundleIds: captureBundleIds,
                      onMic: { engine.ingest(.mic, samples: $0) },
                      onCall: { engine.ingest(.call, samples: $0) })
        isCapturing = true
    }

    private func end() {
        guard isCapturing else { return }
        capture.stop()
        engine.stop()
        isCapturing = false
        captureBundleIds = []
    }
}
