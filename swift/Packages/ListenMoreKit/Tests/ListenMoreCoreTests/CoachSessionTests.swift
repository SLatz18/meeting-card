import Foundation
import XCTest
@testable import ListenMoreCore

@MainActor
final class CoachSessionTests: XCTestCase {
    var config: ListenMoreConfig!
    var engine: RecordingEngine!
    var mic: FakeMic!
    var call: FakeCall!
    var probe: FakeProbe!
    var renderer: FakeRenderer!
    var delegate: RecordingDelegate!
    let clock = ManualClock(1000)

    override func setUp() async throws {
        config = try TestConfig.load()
        engine = RecordingEngine()
        mic = FakeMic()
        call = FakeCall()
        probe = FakeProbe()
        renderer = FakeRenderer()
        delegate = RecordingDelegate()
    }

    /// Window-title signal (the standalone app's): starts at once, stops 8 s after the meeting ends.
    func makeSession(keys: FakeKeys = FakeKeys(key: nil), excluded: [String] = []) -> CoachSession {
        var settings = TriggerSettings(config: config, anyApp: false, ownPid: 1, ownBundleId: "com.example.hostapp",
                                       excludedBundleIds: excluded)
        settings.startAfterS = 0
        settings.stopAfterS = 8
        let signal = WindowTitleSignal(probe: probe, targets: config.captureTargets, meetTitleRegex: config.meetTitleRegex)
        return makeSession(signal: signal, settings: settings, keys: keys)
    }

    func makeSession(signal: CallSignal, settings: TriggerSettings, keys: FakeKeys = FakeKeys(key: nil),
                     enabled: Bool = true) -> CoachSession {
        let clock = clock
        let s = CoachSession(config: config, engine: engine, mic: mic, call: call, signal: signal, keys: keys,
                             renderer: renderer, settings: settings, enabled: enabled, wallClock: { clock.now() })
        s.delegate = delegate
        return s
    }

    func meetInDia() {
        probe.windowList = [WindowInfo(bundleId: "company.thebrowser.dia", title: "Meet - abc-defg-hij")]
        probe.audio = ["company.thebrowser.dia.helper.renderer": true]
    }

    func endMeeting() {
        probe.windowList = []
        probe.audio = [:]
    }

    func testAutoOnStartsMicCallAndEngine() async {
        let s = makeSession(keys: FakeKeys(key: APIKey("sk-test")))
        s.tick()
        XCTAssertEqual(s.indicator, .hidden)
        XCTAssertEqual(mic.started, 0)
        meetInDia()
        s.tick()
        XCTAssertEqual(s.indicator, .listening)
        XCTAssertEqual(s.session?.reason, .audio)
        XCTAssertEqual(s.capturingBundleIds, ["company.thebrowser.dia"])
        XCTAssertEqual(mic.started, 1)
        let started = await eventually { self.call.starts.count == 1 }
        XCTAssertTrue(started)
        XCTAssertEqual(call.starts.first?.stage, .parentApps)
        XCTAssertEqual(call.starts.first?.bundleIds, ["company.thebrowser.dia"])
        let engineStarted = await eventually { self.engine.startedWithKey == [true] }
        XCTAssertTrue(engineStarted)
        XCTAssertTrue(delegate.indicators.contains(.listening))
    }

    func testAudioFlowsIntoEngine() async {
        let s = makeSession()
        meetInDia()
        s.tick()
        _ = await eventually { self.call.handler != nil }
        mic.handler?([Float](repeating: 0, count: 480))
        call.handler?([Float](repeating: 0, count: 240))
        let flowed = await eventually { self.engine.ingested[.mic] == 480 && self.engine.ingested[.call] == 240 }
        XCTAssertTrue(flowed)
    }

    func testMeetingEndStopsAfterGracePeriod() async {
        let s = makeSession()
        meetInDia()
        s.tick()
        endMeeting()
        clock.advance(1)
        s.tick()
        clock.advance(7.5)
        s.tick()
        XCTAssertFalse(s.capturingBundleIds.isEmpty)
        clock.advance(0.5)
        s.tick()
        XCTAssertTrue(s.capturingBundleIds.isEmpty)
        XCTAssertEqual(s.indicator, .hidden)
        XCTAssertEqual(mic.stopped, 1)
        let stopped = await eventually { self.call.stops == 1 }
        XCTAssertTrue(stopped)
        XCTAssertGreaterThanOrEqual(renderer.clears, 1)
    }

    func testPauseStopsCaptureAndSuppressesCues() async {
        let s = makeSession()
        meetInDia()
        s.tick()
        s.setPaused(true)
        XCTAssertEqual(s.indicator, .paused)
        XCTAssertTrue(s.capturingBundleIds.isEmpty)
        XCTAssertEqual(mic.stopped, 1)
        s.deliverForTesting(CueSuggestion(type: .interrupt, t: 1, onset: 0.7, source: .local))
        XCTAssertTrue(renderer.rendered.isEmpty)
        s.setPaused(false)
        XCTAssertEqual(s.indicator, .listening)
        XCTAssertEqual(s.capturingBundleIds, ["company.thebrowser.dia"])
    }

    func testPausedGateDropsLateBuffers() async {
        let s = makeSession()
        meetInDia()
        s.tick()
        _ = await eventually { self.call.handler != nil }
        let lateMic = mic.handler
        let lateCall = call.handler
        s.setPaused(true)
        lateMic?([Float](repeating: 0, count: 480))
        lateCall?([Float](repeating: 0, count: 480))
        s.drainEngineForTesting()
        XCTAssertNil(engine.ingested[.mic])
        XCTAssertNil(engine.ingested[.call])
        s.setPaused(false)
        lateMic?([Float](repeating: 0, count: 480))
        s.drainEngineForTesting()
        XCTAssertNil(engine.ingested[.mic], "a buffer from before the pause never reaches the next session")
    }

    func testManualStartCapturesEveryTarget() async {
        let s = makeSession()
        s.startManual()
        XCTAssertEqual(s.session?.reason, .manual)
        XCTAssertEqual(s.indicator, .listening)
        XCTAssertEqual(s.capturingBundleIds, config.captureTargets.map(\.bundleId))
        s.stopManual()
        XCTAssertTrue(s.capturingBundleIds.isEmpty)
        XCTAssertEqual(s.indicator, .hidden)
    }

    func testManualStartAdoptsTheCallLater() async {
        let s = makeSession()
        s.startManual()
        meetInDia()
        s.tick()
        XCTAssertEqual(s.session?.appKey, "company.thebrowser.dia")
        XCTAssertEqual(s.capturingBundleIds, ["company.thebrowser.dia"])
    }

    func testCuesRenderOnceAndCooldownIsReported() async {
        let s = makeSession()
        meetInDia()
        s.tick()
        s.deliverForTesting(CueSuggestion(type: .interrupt, t: 3.3, onset: 3.0, source: .local))
        s.deliverForTesting(CueSuggestion(type: .interrupt, t: 9, onset: 8.7, source: .local))
        s.deliverForTesting(CueSuggestion(type: .missedQuestion, t: 10, onset: 6, source: .text, level: .soft))
        s.deliverForTesting(CueSuggestion(type: .missedQuestion, t: 24, onset: 20, source: .text, level: .strong))
        s.deliverForTesting(CueSuggestion(type: .notListening, t: 50, onset: 49, source: .gpt, confidence: 0.4))
        XCTAssertEqual(renderer.rendered.map(\.type), [.interrupt, .missedQuestion])
        XCTAssertEqual(renderer.rendered.map(\.color), [.red, .amber])
        XCTAssertEqual(renderer.rendered.last?.level, .strong)
        XCTAssertEqual(delegate.cues.count, 2)
        XCTAssertEqual(s.cuesShown, 2)
        clock.advance(5)
        XCTAssertEqual(s.cooldowns()[.interrupt] ?? 0, 15, accuracy: 1e-9)
        clock.advance(16)
        XCTAssertNil(s.cooldowns()[.interrupt])
    }

    func testEngineSuggestionReachesRendererOnMain() async {
        let s = makeSession()
        meetInDia()
        s.tick()
        _ = await eventually { self.engine.isRunning }
        engine.emit(CueSuggestion(type: .talkOver, t: 4, onset: 3, source: .local))
        let shown = await eventually { self.renderer.rendered.count == 1 }
        XCTAssertTrue(shown)
        _ = s
    }

    func testGptStopIsReportedAndClearedOnNextSession() async {
        let s = makeSession()
        meetInDia()
        s.tick()
        _ = await eventually { self.engine.isRunning }
        engine.stopGpt(.budgetCap)
        let stopped = await eventually { s.gptStopped == .budgetCap }
        XCTAssertTrue(stopped)
        s.stopManual()
        s.startManual()
        XCTAssertNil(s.gptStopped)
    }

    func testJudgeStopReasonIsReportedAndClearedOnNextSession() async {
        let s = makeSession()
        meetInDia()
        s.tick()
        _ = await eventually { self.engine.isRunning }
        engine.stopJudge(.http(401))
        let stopped = await eventually { s.judgeStopped == .http(401) }
        XCTAssertTrue(stopped)
        XCTAssertEqual(s.judgeStopped?.kind, .auth)
        XCTAssertNil(s.gptStopped, "only judging stopped; transcription is on")
        s.stopManual()
        XCTAssertEqual(s.judgeStopped, .http(401), "kept after the call so Settings can still say why")
        s.startManual()
        XCTAssertNil(s.judgeStopped)
    }

    func testCaptionsReachTheHostOnlyWhileCapturingAndCuesOutliveAGptStop() async {
        let s = makeSession(keys: FakeKeys(key: APIKey("sk-test")))
        s.deliverCaptionForTesting(.final(.others, text: "idle"))
        XCTAssertEqual(delegate.captions, [], "no session: dropped")
        meetInDia()
        s.tick()
        _ = await eventually { self.engine.isRunning }
        engine.emitCaption(.partial(.others, item: "a", text: "alpha"))
        engine.emitMeter(CostReading(transcribeUsd: 0.01))
        let got = await eventually { self.delegate.captions.count == 1 && self.delegate.meters.count == 1 }
        XCTAssertTrue(got)
        engine.stopGpt(.budgetCap)
        _ = await eventually { s.gptStopped == .budgetCap }
        s.deliverForTesting(CueSuggestion(type: .interrupt, t: 1, onset: 1, source: .local))
        XCTAssertEqual(renderer.rendered.count, 1, "local cues continue after the cap")
        s.setPaused(true)
        s.deliverCaptionForTesting(.final(.others, text: "paused"))
        XCTAssertEqual(delegate.captions.count, 1, "paused: nothing is captured, nothing is forwarded")
    }

    func testCueWhileIdleIsDropped() async {
        let s = makeSession()
        s.deliverForTesting(CueSuggestion(type: .interrupt, t: 1, onset: 1, source: .local))
        XCTAssertTrue(renderer.rendered.isEmpty)
    }

    func testHelperFallbackEscalates() async {
        let s = makeSession()
        meetInDia()
        s.tick()
        _ = await eventually { self.call.starts.count == 1 }
        // Helpers produce audio but the call stream stays silent.
        for _ in 0..<5 {
            clock.advance(1)
            s.tick()
        }
        XCTAssertEqual(s.captureStage, .helperApps)
        XCTAssertTrue(delegate.problems.contains(.fallbackEngaged(stage: .helperApps)))
        _ = await eventually { self.call.starts.count == 2 }
        for _ in 0..<5 {
            clock.advance(1)
            s.tick()
        }
        XCTAssertEqual(s.captureStage, .processTap)
        let stages = await eventually { self.call.starts.map(\.stage) == [.parentApps, .helperApps, .processTap] }
        XCTAssertTrue(stages, "\(call.starts.map(\.stage))")
        XCTAssertEqual(mic.started, 1, "mic keeps running across call-capture restarts")
    }

    func testSupersededStartIsSkipped() async {
        let s = makeSession()
        meetInDia()
        s.tick()
        s.setPaused(true)
        s.setPaused(false)
        let settled = await eventually { self.call.starts.count >= 1 && self.call.stops >= 1 }
        XCTAssertTrue(settled)
        XCTAssertEqual(call.starts.count, 1, "the first start was superseded by pause before it ran")
        XCTAssertEqual(s.capturingBundleIds, ["company.thebrowser.dia"])
    }

    func testNoFallbackForZoom() async {
        let s = makeSession()
        probe.windowList = [WindowInfo(bundleId: "us.zoom.xos", title: "Zoom Meeting")]
        probe.audio = ["us.zoom.xos": true]
        for _ in 0..<10 {
            clock.advance(1)
            s.tick()
        }
        XCTAssertEqual(s.captureStage, .parentApps)
    }

    func testProblemsAreReported() async {
        mic.failNext = true
        call.failStages = [.parentApps]
        let s = makeSession(keys: FakeKeys(key: nil, fails: true))
        meetInDia()
        s.tick()
        XCTAssertTrue(delegate.problems.contains(.keyUnreadable))
        XCTAssertTrue(delegate.problems.contains(.micUnavailable))
        XCTAssertTrue(s.captureProblem)
        let failed = await eventually { self.delegate.problems.contains(.callCaptureFailed(stage: .parentApps)) }
        XCTAssertTrue(failed)
    }

    func testFaceTimeViaAvconferencedAudio() async {
        let s = makeSession()
        probe.windowList = [WindowInfo(bundleId: "com.apple.FaceTime", title: "FaceTime")]
        probe.audio = ["com.apple.avconferenced": true]
        s.tick()
        XCTAssertEqual(s.session?.appKey, "com.apple.facetime")
        XCTAssertEqual(s.capturingBundleIds, ["com.apple.facetime"])
    }

    func testHostExcludedBundleNeverStarts() async {
        let s = makeSession(excluded: ["company.thebrowser.dia"])
        meetInDia()
        s.tick()
        XCTAssertNil(s.session)
        XCTAssertEqual(mic.started, 0)
    }

    func testDisabledSessionNeverCaptures() async {
        let signal = WindowTitleSignal(probe: probe, targets: config.captureTargets, meetTitleRegex: config.meetTitleRegex)
        let s = makeSession(signal: signal, settings: TriggerSettings(config: config, anyApp: false, ownPid: 1, ownBundleId: nil),
                            enabled: false)
        meetInDia()
        for _ in 0..<10 {
            clock.advance(1)
            s.tick()
        }
        s.startManual()
        XCTAssertNil(s.session)
        XCTAssertEqual(mic.started, 0)
        s.setEnabled(true)
        s.startManual()
        XCTAssertNotNil(s.session)
        s.setEnabled(false)
        XCTAssertNil(s.session)
        XCTAssertTrue(s.capturingBundleIds.isEmpty)
    }

    // MARK: Core Audio signal: indicator and skip this call

    func audioSession() -> (CoachSession, FakeAudioStateProvider) {
        let provider = FakeAudioStateProvider()
        let settings = TriggerSettings(config: config, anyApp: false, ownPid: 1, ownBundleId: "com.example.hostapp")
        return (makeSession(signal: AudioActivitySignal(provider: provider), settings: settings), provider)
    }

    func poll(_ s: CoachSession, seconds: Double) {
        var t = 0.0
        while t < seconds - 1e-9 {
            clock.advance(0.5)
            s.tick()
            t += 0.5
        }
    }

    final class FakeCallState: CallStateProvider {
        var states: [String: CallState] = [:]
        func callStates() -> [String: CallState] { states }
    }

    func testEndedCallStateStopsCaptureInThreeSeconds() async {
        let provider = FakeAudioStateProvider()
        let calls = FakeCallState()
        let settings = TriggerSettings(config: config, anyApp: false, ownPid: 1, ownBundleId: "com.example.hostapp")
        let clock = clock
        let s = CoachSession(config: config, engine: engine, mic: mic, call: call, signal: AudioActivitySignal(provider: provider),
                             keys: FakeKeys(key: nil), renderer: renderer, settings: settings, callState: calls,
                             wallClock: { clock.now() })
        provider.zoomCall()
        s.tick()
        poll(s, seconds: 3)
        XCTAssertEqual(s.indicator, .listening)
        calls.states = ["us.zoom.xos": .ended]
        poll(s, seconds: 2.5)
        XCTAssertNotNil(s.session)
        poll(s, seconds: 1)
        XCTAssertNil(s.session, "Zoom still holds its devices, but the call ended: stopped after 3 s")
        XCTAssertTrue(s.capturingBundleIds.isEmpty)
        XCTAssertEqual(mic.stopped, 1)
        poll(s, seconds: 10)
        XCTAssertNil(s.session, "no restart while the app stays ended")
    }

    /// Local-only: with no key the session still captures and runs local cues; only GPT is off.
    func testNoKeyStillCoachesLocally() async {
        let (s, provider) = audioSession()
        provider.zoomCall()
        s.tick()
        poll(s, seconds: 3)
        XCTAssertEqual(s.indicator, .listening)
        XCTAssertEqual(mic.started, 1)
        let started = await eventually { self.engine.startedWithKey == [false] }
        XCTAssertTrue(started, "the engine runs without a key (no GPT layer)")
    }

    /// A call from detection to its end leaves event names, the app's bundle ID and the key's presence in the coach log:
    /// never the key.
    func testCoachLogFollowsACallAndNeverHoldsTheKey() async {
        let sink = CaptureSink()
        CoachLog.install(sink)
        defer { CoachLog.install(nil) }
        let s = makeSession(keys: FakeKeys(key: APIKey("sk-test-not-real")))
        meetInDia()
        s.tick()
        let started = await eventually { self.engine.startedWithKey == [true] }
        XCTAssertTrue(started)
        s.setMicMuted(true)
        s.setPaused(true)
        s.setPaused(false)
        endMeeting()
        s.tick()
        clock.advance(9)
        s.tick()
        XCTAssertNil(s.session)
        let lines = sink.lines
        XCTAssertEqual(lines.first, "call.detected app=company.thebrowser.dia")
        XCTAssertTrue(lines.contains("session.started reason=audio app=company.thebrowser.dia"))
        XCTAssertTrue(lines.contains("key.read state=present"))
        XCTAssertTrue(lines.contains("mic.muted on=true"))
        XCTAssertTrue(lines.contains("session.paused on=true"))
        XCTAssertTrue(lines.contains("call.ended app=company.thebrowser.dia reason=audioEnded"))
        XCTAssertTrue(lines.contains("session.stopped reason=audioEnded"))
        XCTAssertFalse(lines.contains { $0.contains("sk-") || $0.contains("test-not-real") })
    }

    /// A failed call-audio start is logged with its error domain and code.
    func testCoachLogRecordsACallCaptureFailureCode() async {
        let sink = CaptureSink()
        CoachLog.install(sink)
        defer { CoachLog.install(nil) }
        call.failStages = [.parentApps]
        let s = makeSession()
        meetInDia()
        s.tick()
        let logged = await eventually { sink.lines.contains { $0.hasPrefix("callAudio.failed") } }
        XCTAssertTrue(logged)
        XCTAssertTrue(sink.lines.contains("callAudio.failed stage=parentApps domain=FakeCall code=2"), "\(sink.lines)")
        XCTAssertTrue(sink.lines.contains("key.read state=absent"))
    }

    func testIndicatorOnWhilePrewarmedThenListening() async {
        let (s, provider) = audioSession()
        provider.zoomCall()
        s.tick()
        XCTAssertEqual(s.indicator, .on, "pre-warmed during the start debounce")
        XCTAssertEqual(mic.started, 0, "nothing is captured while pre-warmed")
        poll(s, seconds: 3)
        XCTAssertEqual(s.indicator, .listening)
        XCTAssertEqual(s.capturingBundleIds, ["us.zoom.xos"])
        s.toggleFromIndicator()
        XCTAssertEqual(s.indicator, .paused)
        XCTAssertTrue(s.capturingBundleIds.isEmpty)
        s.toggleFromIndicator()
        XCTAssertEqual(s.indicator, .listening)
    }

    func testSkipThisCallWhilePrewarmed() async {
        let (s, provider) = audioSession()
        provider.zoomCall()
        s.tick()
        XCTAssertEqual(s.indicator, .on)
        s.toggleFromIndicator()
        XCTAssertEqual(s.indicator, .hidden)
        poll(s, seconds: 20)
        XCTAssertNil(s.session, "the skipped call never starts")
        XCTAssertEqual(mic.started, 0)
        provider.silence()
        poll(s, seconds: 1)
        provider.zoomCall()
        poll(s, seconds: 4)
        XCTAssertEqual(s.indicator, .listening, "the next call starts normally")
    }

    func testSkipThisCallClearsJoinHint() async {
        let (s, _) = audioSession()
        s.joinHint(endsAt: clock.now() + 600)
        XCTAssertEqual(s.indicator, .on)
        s.skipThisCall()
        XCTAssertEqual(s.indicator, .hidden)
    }

    /// Stop (the coach card's, replacing Skip this call) ends the coach for the rest of the call:
    /// it doesn't restart while the call goes on, and the next call starts normally.
    func testStopEndsTheCoachForTheRestOfTheCall() async {
        let (s, provider) = audioSession()
        provider.zoomCall()
        s.tick()
        poll(s, seconds: 3)
        XCTAssertEqual(s.indicator, .listening)
        s.stopForThisCall()
        XCTAssertNil(s.session)
        XCTAssertEqual(s.indicator, .hidden)
        XCTAssertTrue(s.capturingBundleIds.isEmpty)
        XCTAssertEqual(mic.stopped, 1)
        poll(s, seconds: 120)
        XCTAssertEqual(s.indicator, .hidden, "no restart, no pre-warm while the call goes on")
        XCTAssertEqual(mic.started, 1)
        provider.silence()
        poll(s, seconds: 1)
        provider.zoomCall()
        poll(s, seconds: 4)
        XCTAssertEqual(s.indicator, .listening, "the next call starts normally")
    }

    func testStopWhilePausedOrMutedEndsTheCall() async {
        let (s, provider) = audioSession()
        provider.zoomCall()
        s.tick()
        poll(s, seconds: 3)
        s.setPaused(true)
        XCTAssertEqual(s.indicator, .paused)
        s.stopForThisCall()
        poll(s, seconds: 60)
        XCTAssertEqual(s.indicator, .hidden)
    }

    /// While pre-warmed (a Join hint pending, the call app inside its start debounce), Stop means
    /// nothing starts for this call, and the hint can't pre-warm it again.
    func testStopWhilePrewarmedKeepsTheCallFromStarting() async {
        let (s, provider) = audioSession()
        s.joinHint(endsAt: clock.now() + 600)
        provider.zoomCall()
        s.tick()
        XCTAssertEqual(s.indicator, .on)
        s.stopForThisCall()
        XCTAssertEqual(s.indicator, .hidden)
        poll(s, seconds: 30)
        XCTAssertNil(s.session)
        XCTAssertEqual(s.indicator, .hidden)
        XCTAssertEqual(mic.started, 0)
    }

    /// A Join hint pending when a running session is stopped doesn't bring the coach back.
    func testStopDropsAPendingJoinHint() async {
        let (s, provider) = audioSession()
        s.joinHint(endsAt: clock.now() + 600)
        provider.zoomCall()
        poll(s, seconds: 4)
        XCTAssertEqual(s.indicator, .listening)
        s.stopForThisCall()
        poll(s, seconds: 5)
        XCTAssertEqual(s.indicator, .hidden)
    }

    func testJoinHintEndsTheSessionAtTheEventEnd() async {
        let (s, provider) = audioSession()
        s.joinHint(endsAt: clock.now() + 10)
        provider.zoomCall()
        poll(s, seconds: 4)
        XCTAssertEqual(s.indicator, .listening)
        poll(s, seconds: 7)
        XCTAssertNil(s.session)
        XCTAssertTrue(s.capturingBundleIds.isEmpty)
    }

    func testHelpersAudibleDrivesFallbackWithAudioSignal() async {
        let (s, provider) = audioSession()
        provider.processes = [
            AudioProcessState(pid: 10, bundleId: "com.google.Chrome.helper", isRunningInput: true, isRunningOutput: false),
            AudioProcessState(pid: 11, bundleId: "com.google.Chrome.helper.renderer", isRunningInput: false, isRunningOutput: true),
        ]
        poll(s, seconds: 4)
        XCTAssertEqual(s.capturingBundleIds, ["com.google.chrome"])
        _ = await eventually { self.call.starts.count == 1 }
        poll(s, seconds: 5)
        XCTAssertEqual(s.captureStage, .helperApps)
    }
}

final class LocalCoachEngineTests: XCTestCase {
    final class Collector: CoachEngineDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private var _cues: [CueSuggestion] = []
        var cues: [CueSuggestion] { lock.withLock { _cues } }

        func engine(_ engine: CoachEngine, didSuggest cue: CueSuggestion) {
            lock.withLock { _cues.append(cue) }
        }
    }

    func testCutInScenarioSuggestsOneInterruptCue() throws {
        let config = try TestConfig.load()
        let mic = Synthetic.track(8, [(3.0, 6.0)], f0: 120)
        let call = Synthetic.track(8, [(1.0, 5.5)], f0: 210)
        let engine = LocalCoachEngine()
        let collector = Collector()
        engine.delegate = collector
        engine.start(config: config, apiKey: APIKey("sk-ignored-without-transports"))
        XCTAssertFalse(engine.hasGptLayer)
        // Irregular chunk sizes, like real capture callbacks.
        var i = 0
        let chunks = [512, 1024, 333, 2048]
        var k = 0
        while i < mic.count {
            let n = min(chunks[k % chunks.count], mic.count - i)
            engine.ingest(.mic, samples: Array(mic[i..<(i + n)]), time: 0)
            engine.ingest(.call, samples: Array(call[i..<(i + n)]), time: 0)
            i += n
            k += 1
        }
        XCTAssertEqual(engine.framesProcessed, 400)
        // 600 ms of overlap, then the other side keeps going for 500 ms; the talk-over that follows is
        // held by the global cooldown.
        XCTAssertEqual(collector.cues.map(\.type), [.interrupt])
        XCTAssertEqual(collector.cues.first?.t ?? 0, 4.2, accuracy: 1e-9)
        XCTAssertEqual(collector.cues.first?.onset ?? 0, 3.0, accuracy: 1e-9)
        XCTAssertTrue(collector.cues.allSatisfy { $0.source == .local })
        engine.stop()
        XCTAssertFalse(engine.isRunning)
    }

    func testSilentCallCaptureIsPadded() throws {
        let config = try TestConfig.load()
        let engine = LocalCoachEngine(maxLagMs: 200)
        engine.start(config: config, apiKey: nil)
        engine.ingest(.mic, samples: [Float](repeating: 0, count: 24000), time: 0)
        XCTAssertGreaterThanOrEqual(engine.framesProcessed, 40)
    }

    func testGptLayerStartsOnlyWithKeyAndTransports() async throws {
        let config = try TestConfig.load()
        let connector = FakeConnector()
        let transports = GptTransports(http: FakeHTTP(), webSocket: connector, scheduler: InstantScheduler())
        let noKey = LocalCoachEngine(transports: transports)
        noKey.start(config: config, apiKey: nil)
        XCTAssertFalse(noKey.hasGptLayer)
        let withKey = LocalCoachEngine(transports: transports)
        withKey.start(config: config, apiKey: APIKey("sk-test"))
        XCTAssertTrue(withKey.hasGptLayer)
        let connected = await eventually { connector.connections.count == 2 }
        XCTAssertTrue(connected)
        let snap = await withKey.gptSnapshot()
        XCTAssertEqual(snap?.enabled, true)
        withKey.stop()
    }
}

final class CoachStyleTests: XCTestCase {
    func testHexParsing() {
        let c = CoachStyle.RGBA(hex: "#FF2E29D9")
        XCTAssertEqual(c?.red ?? 0, 1, accuracy: 1e-9)
        XCTAssertEqual(c?.green ?? 0, 46.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(c?.alpha ?? 0, 217.0 / 255, accuracy: 1e-9)
        XCTAssertEqual(CoachStyle.RGBA(hex: "00FF00")?.alpha, 1)
        XCTAssertNil(CoachStyle.RGBA(hex: "#12345"))
        XCTAssertNil(CoachStyle.RGBA(hex: "zzzzzz"))
    }

    func testColorFallbackStaysInsideTheHostTheme() {
        let teal = CoachStyle.RGBA(red: 0, green: 0.5, blue: 0.5, alpha: 1)
        let style = CoachStyle(colors: [.amber: teal], fadeIn: 0.2, fadeOut: 2.5, bandWidth: 20, cooldownDisplay: .hidden)
        XCTAssertEqual(style.color(for: .red), teal)
        XCTAssertEqual(style.color(for: .amber), teal)
    }

    func testDarkColorsFollowTheAppearance() {
        let light = CoachStyle.RGBA(red: 0.6, green: 0.3, blue: 0.3, alpha: 1)
        let dark = CoachStyle.RGBA(red: 0.8, green: 0.5, blue: 0.5, alpha: 1)
        var style = CoachStyle(colors: [.red: light, .amber: light], fadeIn: 0.2, fadeOut: 2.5, bandWidth: 20,
                               cooldownDisplay: .hidden)
        XCTAssertEqual(style.color(for: .red, dark: true), light, "no dark colors: one set for both")
        style.darkColors = [.red: dark]
        XCTAssertEqual(style.color(for: .red, dark: false), light)
        XCTAssertEqual(style.color(for: .red, dark: true), dark)
        XCTAssertEqual(style.color(for: .amber, dark: true), dark, "a missing dark tone takes the other dark tone")
    }
}
