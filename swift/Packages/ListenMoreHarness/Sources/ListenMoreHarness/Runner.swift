import Foundation
import ListenMoreCore

public enum Mode: String, Sendable, Codable {
    /// Synthetic audio, scripted transcription, stub judge, simulated clock. Deterministic.
    case offline
    /// OpenAI TTS for every voice, real realtime transcription and judge, wall clock.
    case live
}

/// What the transcription sockets saw (offline: the scripted server; live: a metering wrapper).
public struct SocketStats: Sendable {
    public var connections = 0
    public var closes = 0
    public var appends: [ScriptedRealtime.Append] = []
    public var commits: [(t: Double, stream: AudioStream)] = []
    public var clears: [(t: Double, stream: AudioStream)] = []
    public var sendsAfterClose = 0
    /// Offline only: loud audio sent on one stream's socket while only the other stream was voiced.
    public var routingMismatches: Int?
    /// Billed transcription seconds the service reported.
    public var billedSeconds = 0.0

    public init() {}
}

public protocol SocketObserver: AnyObject, Sendable {
    /// Run time of scenario time 0; stats are reported in scenario time.
    func setOrigin(_ origin: Double)
    func stats() -> SocketStats
}

extension ScriptedRealtime: SocketObserver {
    public func setOrigin(_ origin: Double) {}

    public func stats() -> SocketStats {
        var s = SocketStats()
        s.connections = connections
        s.closes = closes
        s.appends = appends
        s.commits = commits
        s.clears = clears
        s.sendsAfterClose = sendsAfterClose
        s.routingMismatches = routingMismatches
        return s
    }
}

/// Everything a run needs from outside the session: config, key, transports, the audio for each line.
public struct RunServices: @unchecked Sendable {
    public var mode: Mode
    /// The rules the oracle and the checks hold the engine to.
    public var config: ListenMoreConfig
    /// What the engine runs with: `config` unless a test simulates an engine regression.
    public var engineConfig: ListenMoreConfig
    /// Test hook: controls the runner records but doesn't perform (a broken Mute or Pause).
    public var ignoredControls: Set<ControlKind> = []
    public var key: APIKey?
    public var transports: GptTransports?
    public var clock: HarnessClock
    public var sockets: SocketObserver?
    public var offlineServer: ScriptedRealtime?
    public var judgeCalls: () -> Int
    public var clips: [String: [Float]]
    public var shapes: [String: ClipShape]
}

public struct CaptionRecord: Sendable {
    public var t: Double
    public var speaker: Speaker
    public var text: String
    public var isFinal: Bool
}

public struct CueRecord: Sendable {
    /// Scenario time the session showed it.
    public var t: Double
    /// Engine audio time (seconds since that engine started).
    public var engineT: Double
    public var type: CueType
    public var level: CueLevel?
    public var source: CueSource
    public var latencyMs: Int
}

public struct CaptionView: Sendable {
    public struct Row: Sendable {
        public var label: String
        public var speaker: Speaker
        public var text: String
    }

    public var t: Double
    public var rows: [Row]
}

public struct FileFact: Sendable {
    public var name: String
    public var mode: Int
    public var contents: String
}

public struct TranscriptObservation: Sendable {
    public var phase: String
    public var t: Double
    public var folderExists: Bool
    public var files: [FileFact]
}

/// One scenario's raw observations, in scenario seconds (0 = the first audio sample).
public struct RunRecord: @unchecked Sendable {
    public var scenario: Scenario
    public var mode: Mode
    public var timeline: Timeline
    public var config: ListenMoreConfig
    public var captions: [CaptionRecord] = []
    public var cues: [CueRecord] = []
    public var captionViews: [CaptionView] = []
    public var indicators: [(t: Double, indicator: CoachIndicator)] = []
    public var sessionStarts: [Double] = []
    public var sessionStops: [Double] = []
    public var gptStop: (t: Double, reason: GptStopReason)?
    public var captionStates: [(t: Double, state: LiveTranscript.CaptionState)] = []
    public var visibleLinesAfterCall: Int?
    public var themLabelAfterCall: String?
    public var engineIngests: [MeteredEngine.Ingest] = []
    public var engineStarts: [Double] = []
    public var engineStops: [Double] = []
    public var sockets = SocketStats()
    public var micOfferedWhileMuted = 0
    public var micMuteCalls: [Bool] = []
    public var judgeCalls = 0
    public var meters: [CostReading] = []
    public var transcripts: [TranscriptObservation] = []
    public var deleteResults: [(t: Double, deleted: Bool)] = []
    public var transcriptDeletedAtTeardown = false
    /// When each control took effect: the first 20 ms frame boundary at or after its scripted time.
    public var applied: [(kind: ControlKind, t: Double)] = []
    /// When the engine itself handled each Mute / Unmute (on its queue, after every frame queued before it).
    public var engineMicMutes: [(t: Double, muted: Bool)] = []
    /// Every call the transcript store got: folders prepared, files written.
    public var storePrepared: [URL] = []
    public var storeWritten: [URL] = []
    public var transcriptsFolder: URL?
    /// The recorder's last file before teardown (nil when nothing was ever written).
    public var recorderLastURL: URL?
    public var barrierTimeouts = 0
    public var problems: [String] = []
    /// Filled in by the harness after teardown.
    public var diskViolations: [String] = []
    public var workDirWiped = false

    init(scenario: Scenario, mode: Mode, timeline: Timeline, config: ListenMoreConfig) {
        self.scenario = scenario
        self.mode = mode
        self.timeline = timeline
        self.config = config
    }

    public func samples(_ stream: AudioStream, in window: ClosedRange<Double>) -> Int {
        engineIngests.filter { $0.stream == stream && window.contains($0.t) }.reduce(0) { $0 + $1.samples }
    }

    /// Spans between each applied `open` control and the next applied `close` (or the end).
    public func appliedWindows(_ open: ControlKind, _ close: ControlKind) -> [ClosedRange<Double>] {
        var out: [ClosedRange<Double>] = []
        var from: Double?
        for c in applied {
            if c.kind == open, from == nil { from = c.t }
            if c.kind == close, let f = from {
                out.append(f...max(f, c.t))
                from = nil
            }
        }
        if let f = from { out.append(f...max(f, timeline.duration)) }
        return out
    }
}

/// Drives one scenario through the real `CoachSession` (and with it `LocalCoachEngine`, `GptLayer`,
/// `LiveTranscriber`) on synthetic devices, as a host would: Core Audio state starts the session,
/// captions and the opt-in transcript go through `LiveTranscript` and `FileTranscriptStore`.
@MainActor
public final class ScenarioRun: CoachSessionDelegate {
    public let scenario: Scenario
    let services: RunServices
    let workDir: URL
    let transcriptsDir: URL
    let clock: HarnessClock
    let mic = HarnessMic()
    let call = HarnessCall()
    let audioState = HarnessAudioState()
    let renderer = HarnessRenderer()
    let store = CountingTranscriptStore()
    let finalsDelivered = AsyncCounter()
    var origin = 0.0
    var record: RunRecord!
    var live: LiveTranscript!
    var session: CoachSession!
    var callActive = false
    var lastIndicator: CoachIndicator?

    public init(scenario: Scenario, services: RunServices, workDir: URL) {
        self.scenario = scenario
        self.services = services
        self.workDir = workDir
        transcriptsDir = workDir.appendingPathComponent("transcripts", isDirectory: true)
        clock = services.clock
    }

    var now: Double { clock.now() - origin }
    var offline: Bool { services.mode == .offline }

    public func run() async throws -> RunRecord {
        let config = services.engineConfig
        let sr = config.audio.sampleRate
        let hop = config.frameSamples
        let frameS = config.frameS
        let timeline = try Timeline.realize(scenario, shapes: services.shapes)
        let tracks = Tracks(timeline: timeline, clips: services.clips, sampleRate: sr)
        record = RunRecord(scenario: scenario, mode: services.mode, timeline: timeline, config: services.config)

        let base = Date(timeIntervalSince1970: 1_800_000_000)
        let clock = self.clock
        live = LiveTranscript(settings: .init(captions: true, saving: scenario.saving, folder: transcriptsDir,
                                              keyUsable: services.key != nil),
                              store: store, timeZone: TimeZone(identifier: "UTC") ?? .current,
                              clock: { base.addingTimeInterval(clock.now()) })
        let engine = MeteredEngine(inner: LocalCoachEngine(transports: services.key == nil ? nil : services.transports),
                                   clock: clock, lockstep: offline)
        let settings = TriggerSettings(allowlist: [HarnessAudioState.appBundleId], excludedBundleIds: [], ownPid: 1,
                                       startAfterS: config.trigger.startAfterS, stopAfterS: config.trigger.stopAfterS,
                                       endedStopAfterS: config.trigger.endedStopAfterS)
        session = CoachSession(config: config, engine: engine, mic: mic, call: call, signal: AudioActivitySignal(provider: audioState),
                               keys: HarnessKeys(key: services.key), renderer: renderer, settings: settings, enabled: true,
                               wallClock: { clock.now() })
        session.delegate = self

        // The call app starts: the session starts after `trigger.start_after_s`, as on a Mac.
        audioState.live = true
        let poll = config.trigger.pollS
        let preStart = clock.now()
        while !session.isCapturing {
            session.tick()
            if session.isCapturing { break }
            guard clock.now() - preStart < 15 else { throw HarnessError.script("the session never started") }
            await advance(by: poll)
        }
        await waitForCallCapture(after: 0)
        origin = clock.now()
        services.offlineServer?.load(timeline: timeline, tracks: tracks, origin: origin)
        services.sockets?.setOrigin(origin)

        let controls = timeline.controls.sorted { $0.t < $1.t }
        var nextControl = 0
        var nextTick = poll
        var expectedCallFrames = engine.callIngests.current
        var droppedFinals = 0
        var wasCapturing = true
        var callAudioOn = true
        let steps = tracks.mic.count / hop
        for k in 0..<steps {
            let tStart = Double(k) * frameS
            let generationBefore = call.generation
            while nextControl < controls.count && controls[nextControl].t <= tStart + 1e-9 {
                let c = controls[nextControl]
                if c.control.kind == .callEnds { callAudioOn = false }
                record.applied.append((c.control.kind, offline ? tStart : max(tStart, now)))
                await apply(c.control)
                nextControl += 1
            }
            if session.isCapturing && !wasCapturing { await waitForCallCapture(after: generationBefore) }
            wasCapturing = session.isCapturing
            let tEnd = Double(k + 1) * frameS
            if offline { clock.advance(to: origin + tEnd) }
            let range = (k * hop)..<((k + 1) * hop)
            mic.deliver(Array(tracks.mic[range]))
            let callChunk = callAudioOn ? Array(tracks.call[range]) : [Float](repeating: 0, count: hop)
            let capturing = session.isCapturing
            let delivered = call.deliver(callChunk)
            if offline {
                if capturing && delivered {
                    expectedCallFrames += 1
                    if !(await engine.callIngests.wait(atLeast: expectedCallFrames, timeout: 10)) {
                        record.barrierTimeouts += 1
                        expectedCallFrames = engine.callIngests.current
                    }
                }
                if let server = services.offlineServer, session.gptStopped == nil, capturing {
                    if !(await finalsDelivered.wait(atLeast: server.finalsSent.current - droppedFinals, timeout: 10)) {
                        record.barrierTimeouts += 1
                        droppedFinals = server.finalsSent.current - finalsDelivered.current
                    }
                }
                await mainQueueFlush()
                if record.barrierTimeouts >= 5 {
                    record.problems.append("lockstep stalled")
                    break
                }
            } else {
                let wait = origin + tEnd - clock.now()
                if wait > 0 { try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000)) }
            }
            if tEnd + 1e-9 >= nextTick {
                session.tick()
                nextTick += poll
            }
        }

        // Teardown: the coach stops for the call, the session shuts down, sockets close.
        if session.session != nil { session.stopForThisCall() }
        session.shutdown()
        await settle(engine: engine)
        observeTranscripts("teardown")
        record.recorderLastURL = live.recorder.lastURL
        if live.recorder.lastURL != nil {
            let deleted = (try? live.deleteTranscript()) ?? false
            record.transcriptDeletedAtTeardown = deleted
        }
        observeTranscripts("after-teardown")

        record.engineIngests = engine.ingests.map { MeteredEngine.Ingest(t: $0.t - origin, stream: $0.stream, samples: $0.samples) }
        record.engineStarts = engine.starts.map { $0 - origin }
        record.engineStops = engine.stops.map { $0 - origin }
        record.engineMicMutes = engine.micMutes.map { ($0.t - origin, $0.muted) }
        record.storePrepared = store.prepared
        record.storeWritten = store.written
        record.transcriptsFolder = transcriptsDir
        record.barrierTimeouts += engine.barrierTimeouts
        record.sockets = services.sockets?.stats() ?? SocketStats()
        record.micOfferedWhileMuted = mic.offeredWhileMuted
        record.micMuteCalls = mic.muteCalls
        record.judgeCalls = services.judgeCalls()
        record.captionStates.append((now, live.captionState))
        return record
    }

    // MARK: controls

    func apply(_ c: Control) async {
        if services.ignoredControls.contains(c.kind) { return }
        switch c.kind {
        case .mute: session.setMicMuted(true)
        case .unmute: session.setMicMuted(false)
        case .pause: session.setPaused(true)
        case .resume: session.setPaused(false)
        case .callEnds: audioState.live = false
        case .renameThem: live.rename(.others, to: c.tag)
        case .deleteTranscript:
            let deleted = (try? live.deleteTranscript()) ?? false
            record.deleteResults.append((now, deleted))
            observeTranscripts("after-delete")
        case .stopCoach: session.stopForThisCall()
        }
        record.captionStates.append((now, live.captionState))
    }

    // MARK: pacing

    func advance(by dt: Double) async {
        if offline {
            clock.advance(to: clock.now() + dt)
            await mainQueueFlush()
        } else {
            try? await Task.sleep(nanoseconds: UInt64(dt * 1_000_000_000))
        }
    }

    /// The session starts call capture in a task; wait for it so no call audio is dropped.
    func waitForCallCapture(after generation: Int) async {
        let deadline = Date().addingTimeInterval(5)
        while call.generation <= generation && Date() < deadline {
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        if call.generation <= generation { record?.problems.append("call capture did not start") }
    }

    /// Everything already queued on the main queue (engine callbacks to the session) has run.
    func mainQueueFlush() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            DispatchQueue.main.async { c.resume() }
        }
    }

    func settle(engine: MeteredEngine) async {
        let deadline = Date().addingTimeInterval(offline ? 5 : 10)
        while Date() < deadline {
            let s = services.sockets?.stats()
            if engine.inner.isRunning == false && (s == nil || s!.closes >= s!.connections) { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        await mainQueueFlush()
    }

    // MARK: transcript files

    func observeTranscripts(_ phase: String) {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: transcriptsDir.path, isDirectory: &isDir) && isDir.boolValue
        var files: [FileFact] = []
        if exists, let names = try? fm.contentsOfDirectory(atPath: transcriptsDir.path) {
            for name in names.sorted() {
                let url = transcriptsDir.appendingPathComponent(name)
                let mode = ((try? fm.attributesOfItem(atPath: url.path))?[.posixPermissions] as? NSNumber)?.intValue ?? -1
                let contents = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
                files.append(FileFact(name: name, mode: mode, contents: contents))
            }
        }
        record?.transcripts.append(TranscriptObservation(phase: phase, t: now, folderExists: exists, files: files))
    }

    // MARK: CoachSessionDelegate

    public func coachSessionDidChange(_ s: CoachSession) {
        let t = now
        if s.indicator != lastIndicator {
            lastIndicator = s.indicator
            record?.indicators.append((t, s.indicator))
        }
        let active = s.session != nil
        if active && !callActive {
            callActive = true
            record?.sessionStarts.append(t)
            live.callStarted()
        } else if !active && callActive {
            callActive = false
            record?.sessionStops.append(t)
            observeTranscripts("call-ended")
            live.callEnded()
            record?.visibleLinesAfterCall = live.visibleLines.count
            record?.themLabelAfterCall = live.labels.label(.others)
        }
        if let reason = s.gptStopped, record?.gptStop == nil {
            record?.gptStop = (t, reason)
            live.gptStopped(reason)
            record?.captionStates.append((t, live.captionState))
        }
    }

    public func coachSession(_ session: CoachSession, didShow cue: Cue) {
        record?.cues.append(CueRecord(t: now, engineT: cue.t, type: cue.type, level: cue.level, source: cue.source,
                                      latencyMs: cue.latencyMs))
    }

    public func coachSession(_ session: CoachSession, didCaption event: CaptionEvent) {
        let t = now
        live.receive(event)
        switch event {
        case let .partial(speaker, _, text):
            record?.captions.append(CaptionRecord(t: t, speaker: speaker, text: text, isFinal: false))
        case let .final(speaker, text):
            record?.captions.append(CaptionRecord(t: t, speaker: speaker, text: text, isFinal: true))
            record?.captionViews.append(CaptionView(t: t, rows: live.visibleLines.map {
                CaptionView.Row(label: live.labels.label($0.speaker), speaker: $0.speaker, text: $0.text)
            }))
            finalsDelivered.add()
        }
    }

    public func coachSession(_ session: CoachSession, didMeter reading: CostReading) {
        record?.meters.append(reading)
    }

    public func coachSession(_ session: CoachSession, didReport problem: CoachSession.Problem) {
        record?.problems.append(String(describing: problem))
    }
}
