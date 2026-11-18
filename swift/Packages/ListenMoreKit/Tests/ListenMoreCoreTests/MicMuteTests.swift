import Foundation
import XCTest
@testable import ListenMoreCore

// The coach's own Mute (mic only): the session's state and capture, the real path down to the
// realtime sockets, and each layer that drops or suspends what reads the user's speech.

@MainActor
final class MicMuteSessionTests: XCTestCase {
    var config: ListenMoreConfig!
    var engine: RecordingEngine!
    var mic: FakeMic!
    var call: FakeCall!
    var probe: FakeProbe!
    var delegate: RecordingDelegate!
    let clock = ManualClock(1000)
    let buffer = [Float](repeating: 0, count: 480)

    override func setUp() async throws {
        config = try TestConfig.load()
        engine = RecordingEngine()
        mic = FakeMic()
        call = FakeCall()
        probe = FakeProbe()
        delegate = RecordingDelegate()
    }

    final class FakeCallState: CallStateProvider {
        var states: [String: CallState] = [:]
        func callStates() -> [String: CallState] { states }
    }

    /// Window-title signal: starts at once, stops 8 s after the meeting ends.
    func makeSession() -> CoachSession {
        var settings = TriggerSettings(config: config, anyApp: false, ownPid: 1, ownBundleId: "com.example.hostapp")
        settings.startAfterS = 0
        settings.stopAfterS = 8
        let signal = WindowTitleSignal(probe: probe, targets: config.captureTargets, meetTitleRegex: config.meetTitleRegex)
        let clock = clock
        let s = CoachSession(config: config, engine: engine, mic: mic, call: call, signal: signal, keys: FakeKeys(key: nil),
                             renderer: FakeRenderer(), settings: settings, wallClock: { clock.now() })
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

    func listening() async -> CoachSession {
        let s = makeSession()
        meetInDia()
        s.tick()
        XCTAssertEqual(s.indicator, .listening)
        _ = await eventually { self.call.handler != nil }
        return s
    }

    /// Checks the session ended unmuted and that `start` begins the next one with the mic running.
    func assertNextSessionStartsUnmuted(_ s: CoachSession, start: () -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertNil(s.session, file: file, line: line)
        XCTAssertFalse(s.micMuted, "reset when the session ends", file: file, line: line)
        let started = mic.started
        start()
        XCTAssertNotNil(s.session, file: file, line: line)
        XCTAssertFalse(s.micMuted, file: file, line: line)
        XCTAssertEqual(s.indicator, .listening, file: file, line: line)
        XCTAssertEqual(mic.started, started + 1, "the mic runs in the next session", file: file, line: line)
        XCTAssertNotNil(mic.handler, file: file, line: line)
        s.drainEngineForTesting()
        XCTAssertEqual(engine.micMutes, [true], "the next session's engine isn't muted", file: file, line: line)
    }

    /// Mute while listening stops the mic and tells the engine; call capture keeps going.
    func testMuteWhileListeningStopsOnlyTheMic() async {
        let s = await listening()
        s.setMicMuted(true)
        XCTAssertTrue(s.micMuted)
        XCTAssertEqual(s.indicator, .micOff)
        XCTAssertEqual(mic.muted, [true], "the device is closed through MicSource.setMuted")
        XCTAssertFalse(mic.isOpen)
        XCTAssertEqual(mic.stopped, 0, "the mic stays started with the session's handler")
        XCTAssertTrue(s.isCapturing)
        XCTAssertEqual(s.capturingBundleIds, ["company.thebrowser.dia"])
        s.drainEngineForTesting()
        XCTAssertEqual(engine.micMutes, [true])
        XCTAssertEqual(engine.stops, 0)
        XCTAssertEqual(engine.startedWithKey.count, 1)
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertEqual(call.stops, 0, "call capture is not stopped")
        XCTAssertEqual(call.starts.count, 1)
        XCTAssertNotNil(call.handler)
        XCTAssertTrue(delegate.indicators.contains(.micOff))
    }

    /// Unmute reopens the device for the kept handler on the same engine and goes back to Listening.
    func testUnmuteRestartsTheMic() async {
        let s = await listening()
        s.setMicMuted(true)
        s.setMicMuted(false)
        XCTAssertFalse(s.micMuted)
        XCTAssertEqual(s.indicator, .listening)
        XCTAssertEqual(mic.muted, [true, false])
        XCTAssertTrue(mic.isOpen)
        XCTAssertEqual(mic.started, 1, "the kept handler: no second start")
        s.drainEngineForTesting()
        XCTAssertEqual(engine.micMutes, [true, false])
        XCTAssertEqual(engine.startedWithKey.count, 1, "the engine keeps running")
        mic.handler?(buffer)
        s.drainEngineForTesting()
        XCTAssertEqual(engine.ingested[.mic], 480)
        XCTAssertEqual(Array(delegate.indicators.suffix(2)), [.micOff, .listening])
    }

    /// Muting while paused only flips the flag; Resume starts a new engine told to mute and leaves the mic off.
    func testMuteWhilePausedKeepsTheMicOffOnResume() async {
        let s = await listening()
        s.setPaused(true)
        s.setMicMuted(true)
        XCTAssertTrue(s.micMuted)
        XCTAssertEqual(s.indicator, .paused, "Pause shows over Mute")
        s.drainEngineForTesting()
        XCTAssertEqual(engine.micMutes, [])
        s.setPaused(false)
        XCTAssertEqual(s.indicator, .micOff)
        XCTAssertEqual(mic.muted.last, true, "muted before it starts")
        XCTAssertFalse(mic.isOpen, "the device is never opened")
        s.drainEngineForTesting()
        XCTAssertEqual(engine.startedWithKey.count, 2)
        XCTAssertEqual(engine.micMutes, [true])
    }

    /// Unmuting while paused only flips the flag; Resume starts the mic.
    func testUnmuteWhilePausedStartsTheMicOnResume() async {
        let s = await listening()
        s.setMicMuted(true)
        s.setPaused(true)
        s.setMicMuted(false)
        XCTAssertEqual(s.indicator, .paused)
        XCTAssertEqual(mic.started, 1)
        s.setPaused(false)
        XCTAssertEqual(s.indicator, .listening)
        XCTAssertEqual(mic.started, 2)
        XCTAssertNotNil(mic.handler)
        s.drainEngineForTesting()
        XCTAssertEqual(engine.micMutes, [true], "the resumed engine starts unmuted")
    }

    /// Muted in the call app shows over the coach's Mute; when the app unmutes, capture resumes with the mic still off.
    func testCallAppMuteShowsOverMuteAndResumesToMicOff() async {
        let audio = FakeAudioStateProvider()
        audio.zoomCall()
        let calls = FakeCallState()
        var settings = TriggerSettings(config: config, anyApp: false, ownPid: 1, ownBundleId: nil)
        settings.startAfterS = 0
        let clock = clock
        let s = CoachSession(config: config, engine: engine, mic: mic, call: call, signal: AudioActivitySignal(provider: audio),
                             keys: FakeKeys(key: nil), renderer: FakeRenderer(), settings: settings, callState: calls,
                             wallClock: { clock.now() })
        s.delegate = delegate
        s.tick()
        XCTAssertEqual(s.indicator, .listening)
        calls.states = ["us.zoom.xos": .muted]
        s.tick()
        XCTAssertEqual(s.indicator, .muted)
        XCTAssertFalse(s.isCapturing)
        s.setMicMuted(true)
        XCTAssertTrue(s.micMuted)
        XCTAssertEqual(s.indicator, .muted)
        s.drainEngineForTesting()
        XCTAssertEqual(engine.micMutes, [], "nothing is capturing")
        calls.states = ["us.zoom.xos": .started]
        s.tick()
        XCTAssertEqual(s.indicator, .micOff)
        XCTAssertTrue(s.isCapturing)
        XCTAssertEqual(mic.muted.last, true, "muted before it starts")
        XCTAssertFalse(mic.isOpen, "the device is never opened")
        s.drainEngineForTesting()
        XCTAssertEqual(engine.startedWithKey.count, 2)
        XCTAssertEqual(engine.micMutes, [true])
        s.shutdown()
    }

    /// Manual Stop ends Mute with the session.
    func testStopManualResetsMute() async {
        let s = await listening()
        s.setMicMuted(true)
        s.stopManual()
        assertNextSessionStartsUnmuted(s) { s.startManual() }
    }

    /// Stop for this call ends Mute with the session.
    func testStopForThisCallResetsMute() async {
        let s = await listening()
        s.setMicMuted(true)
        s.stopForThisCall()
        assertNextSessionStartsUnmuted(s) { s.startManual() }
    }

    /// The meeting ending ends Mute with the session; the next meeting starts unmuted.
    func testMeetingEndResetsMute() async {
        let s = await listening()
        s.setMicMuted(true)
        endMeeting()
        clock.advance(1)
        s.tick()
        clock.advance(8)
        s.tick()
        assertNextSessionStartsUnmuted(s) {
            meetInDia()
            s.tick()
        }
    }

    /// Switching the coach off ends Mute with the session.
    func testSwitchingOffResetsMute() async {
        let s = await listening()
        s.setMicMuted(true)
        s.setEnabled(false)
        assertNextSessionStartsUnmuted(s) {
            s.setEnabled(true)
            s.startManual()
        }
    }

    /// Without a session there is nothing to mute; repeating the current state changes nothing.
    func testMuteWithoutASessionOrUnchangedIsANoOp() async {
        let s = makeSession()
        s.setMicMuted(true)
        XCTAssertFalse(s.micMuted)
        XCTAssertEqual(s.indicator, .hidden)
        XCTAssertEqual(delegate.indicators, [])
        meetInDia()
        s.tick()
        s.setMicMuted(false)
        s.setMicMuted(true)
        s.setMicMuted(true)
        XCTAssertEqual(mic.started, 1)
        XCTAssertEqual(mic.muted, [true])
        s.drainEngineForTesting()
        XCTAssertEqual(engine.micMutes, [true])
    }

    /// The indicator's one control pauses from Mic off, and Resume returns to Mic off.
    func testIndicatorTogglePausesFromMicOffAndResumesToMicOff() async {
        let s = await listening()
        s.setMicMuted(true)
        s.toggleFromIndicator()
        XCTAssertEqual(s.indicator, .paused)
        XCTAssertFalse(s.isCapturing)
        XCTAssertTrue(s.micMuted)
        s.toggleFromIndicator()
        XCTAssertEqual(s.indicator, .micOff)
        XCTAssertFalse(mic.isOpen, "Resume never opens the device while muted")
        s.drainEngineForTesting()
        XCTAssertEqual(engine.micMutes, [true, true])
    }

    /// A buffer the mic was already delivering when muted never reaches the engine while muted; call
    /// buffers still do. Unmute reopens the gate for the kept handler; a handler from before a Pause
    /// (an earlier capture) never gets in again.
    func testLateMicBufferAfterMuteNeverReachesTheEngine() async {
        let s = await listening()
        let lateMic = mic.handler
        let callHandler = call.handler
        lateMic?(buffer)
        s.drainEngineForTesting()
        XCTAssertEqual(engine.ingested[.mic], 480)
        s.setMicMuted(true)
        lateMic?(buffer)
        callHandler?([Float](repeating: 0, count: 240))
        s.drainEngineForTesting()
        XCTAssertEqual(engine.ingested[.mic], 480)
        XCTAssertEqual(engine.ingested[.call], 240)
        s.setMicMuted(false)
        XCTAssertTrue(mic.handler != nil && mic.isOpen, "the same handler, the device open again")
        mic.handler?(buffer)
        s.drainEngineForTesting()
        XCTAssertEqual(engine.ingested[.mic], 960)
        s.setPaused(true)
        s.setPaused(false)
        lateMic?(buffer)
        s.drainEngineForTesting()
        XCTAssertEqual(engine.ingested[.mic], 960, "a handler from before the Pause stays out")
    }

    /// A mic that fails to start again on unmute is reported like at session start.
    func testMicFailingToRestartOnUnmuteIsReported() async {
        let s = await listening()
        s.setMicMuted(true)
        XCTAssertFalse(s.captureProblem)
        mic.failNext = true
        s.setMicMuted(false)
        XCTAssertTrue(s.captureProblem)
        XCTAssertEqual(delegate.problems.filter { $0 == .micUnavailable }.count, 1)
        XCTAssertFalse(mic.isOpen)
        XCTAssertFalse(s.micMuted)
        XCTAssertEqual(s.indicator, .listening)
    }

    /// The unmute's failed reopen is retried by the mic itself, and what it delivers once it opens
    /// reaches the engine: the gate isn't left closed by the failure.
    func testAFailedUnmuteReopenLeavesTheGateOpenForTheRetry() async {
        let s = await listening()
        s.setMicMuted(true)
        mic.failNext = true
        s.setMicMuted(false)
        XCTAssertTrue(s.captureProblem)
        mic.handler?(buffer)
        s.drainEngineForTesting()
        XCTAssertEqual(engine.ingested[.mic], 480)
    }
}

/// "No mic frames reach the transcriber while muted": the real session, audio gates, engine, GPT
/// layer, realtime transcribers and wire format, with only the mic, the call source and the sockets
/// faked. Mute stops the mic engine and clears the user's uncommitted audio; from then on not one
/// `input_audio_buffer.append` reaches the user's socket and no text of theirs is captioned, while
/// the other side's stream, socket and captions carry on. No socket is closed.
@MainActor
final class MicMuteSendsNoMicAudioTests: XCTestCase {
    var config: ListenMoreConfig!
    var connector: FakeConnector!
    var mic: FakeMic!
    var call: FakeCall!
    var session: CoachSession!
    var delegate: RecordingDelegate!

    override func setUp() async throws {
        config = try TestConfig.load()
        connector = FakeConnector()
        mic = FakeMic()
        call = FakeCall()
        delegate = RecordingDelegate()
        let engine = LocalCoachEngine(transports: GptTransports(http: FakeHTTP(), webSocket: connector))
        session = CoachSession(config: config, engine: engine, mic: mic, call: call,
                               signal: AudioActivitySignal(provider: FakeAudioStateProvider()),
                               keys: FakeKeys(key: APIKey("sk-test-not-real")), renderer: FakeRenderer(),
                               settings: TriggerSettings(config: config, anyApp: false, ownPid: 1, ownBundleId: nil))
        session.delegate = delegate
    }

    override func tearDown() async throws {
        session.shutdown()
    }

    var sockets: [FakeSocket] { connector.connections.map(\.socket) }

    /// Speech into both streams through the given capture callbacks, in 20 ms buffers.
    func feed(mic m: (@Sendable ([Float]) -> Void)?, call c: (@Sendable ([Float]) -> Void)?, seconds: Double, seed: Int = 0) {
        let speech = Synthetic.speechish(seconds, seed: seed)
        for i in stride(from: 0, to: speech.count, by: 480) {
            let chunk = Array(speech[i..<min(i + 480, speech.count)])
            m?(chunk)
            c?(chunk)
        }
        session.drainEngineForTesting()
    }

    func completed(_ item: String, _ text: String) -> String {
        #"{"type":"conversation.item.input_audio_transcription.completed","item_id":"\#(item)","transcript":"\#(text)"}"#
    }

    func speakers(_ captions: [CaptionEvent]) -> [Speaker] {
        captions.map {
            switch $0 {
            case let .partial(s, _, _), let .final(s, _): return s
            }
        }
    }

    /// Mute stops the mic engine and not one mic frame reaches the user's transcriber until Unmute.
    func testMuteStopsTheMicEngineAndNoMicFramesReachTheTranscriberUntilUnmute() async throws {
        session.startManual()
        let connected = await eventually { self.call.handler != nil && self.sockets.count == 2 }
        XCTAssertTrue(connected, "one realtime socket per stream")
        // The GPT layer connects in Speaker.allCases order, awaiting each: the user's socket first.
        let me = sockets[0], others = sockets[1]
        feed(mic: mic.handler, call: call.handler, seconds: 2)
        let streamed = await eventually { me.appends > 0 && others.appends > 0 }
        XCTAssertTrue(streamed, "both streams are transcribed while listening")

        let lateMic = mic.handler
        let lateCall = call.handler
        session.setMicMuted(true)
        XCTAssertEqual(session.indicator, .micOff)
        XCTAssertFalse(mic.isOpen, "the mic device is closed")
        XCTAssertEqual(mic.muted, [true])
        let cleared = await eventually { me.sent.contains { $0.contains("\"input_audio_buffer.clear\"") } }
        XCTAssertTrue(cleared, "the user's uncommitted audio is cleared")
        XCTAssertFalse(others.sent.contains { $0.contains("\"input_audio_buffer.clear\"") })
        let meAtMute = me.appends, othersAtMute = others.appends

        feed(mic: lateMic, call: lateCall, seconds: 2, seed: 1)
        let theirsFlow = await eventually { others.appends > othersAtMute }
        XCTAssertTrue(theirsFlow, "the other side keeps streaming")
        try await Task.sleep(nanoseconds: 300_000_000)
        XCTAssertEqual(me.appends, meAtMute, "no mic frames reach the transcriber while muted")
        XCTAssertTrue(me.sent.last?.contains("\"input_audio_buffer.clear\"") == true, "nothing reaches the user's socket after the clear")
        XCTAssertEqual(sockets.count, 2, "no socket opened")
        XCTAssertTrue(sockets.allSatisfy { !$0.isClosed }, "Mute closes no socket")
        XCTAssertEqual(call.stops, 0)

        me.push(completed("i1", "alpha bravo"))
        others.push(completed("i2", "charlie delta"))
        let theirCaption = await eventually { self.delegate.captions.contains(.final(.others, text: "charlie delta")) }
        XCTAssertTrue(theirCaption, "the other side is still captioned")
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(speakers(delegate.captions).contains(.me), "no text of the user's while muted")

        session.setMicMuted(false)
        XCTAssertEqual(session.indicator, .listening)
        XCTAssertNotNil(mic.handler)
        feed(mic: mic.handler, call: call.handler, seconds: 2, seed: 2)
        let resumed = await eventually { me.appends > meAtMute }
        XCTAssertTrue(resumed, "the user's speech streams again after Unmute")
        XCTAssertTrue(sockets.allSatisfy { !$0.isClosed })
        XCTAssertEqual(sockets.count, 2)
    }

    /// The server rejecting the clear is not fatal: the session reports it (the service logs the event
    /// type only), the other side keeps streaming and being captioned, and Unmute sends the clear again
    /// before any new mic audio.
    func testRejectedClearKeepsTheOtherSideStreaming() async throws {
        session.startManual()
        let connected = await eventually { self.call.handler != nil && self.sockets.count == 2 }
        XCTAssertTrue(connected)
        let me = sockets[0], others = sockets[1]
        feed(mic: mic.handler, call: call.handler, seconds: 2)
        _ = await eventually { me.appends > 0 && others.appends > 0 }
        let lateCall = call.handler
        session.setMicMuted(true)
        let clearSent = await eventually { me.sent.contains { $0.contains("\"input_audio_buffer.clear\"") } }
        XCTAssertTrue(clearSent)
        let clear = try XCTUnwrap(me.sent.last { $0.contains("\"input_audio_buffer.clear\"") })
        let id = try XCTUnwrap((try JSONSerialization.jsonObject(with: Data(clear.utf8)) as? [String: Any])?["event_id"] as? String)
        me.push(#"{"type":"error","error":{"type":"invalid_request_error","code":"rejected","event_id":"\#(id)"}}"#)
        let reported = await eventually { self.delegate.problems.contains(.transcriberClearRejected) }
        XCTAssertTrue(reported, "the rejection is reported, for the event-type-only log")

        let othersAtReject = others.appends
        feed(mic: nil, call: lateCall, seconds: 2, seed: 3)
        let theirsFlow = await eventually { others.appends > othersAtReject }
        XCTAssertTrue(theirsFlow, "the other side keeps streaming")
        others.push(completed("i3", "echo foxtrot"))
        let caption = await eventually { self.delegate.captions.contains(.final(.others, text: "echo foxtrot")) }
        XCTAssertTrue(caption, "and keeps being captioned")
        XCTAssertNil(session.gptStopped, "the GPT layer didn't stop")
        XCTAssertTrue(sockets.allSatisfy { !$0.isClosed })

        let meAtUnmute = me.appends, sentAtUnmute = me.sent.count
        session.setMicMuted(false)
        feed(mic: mic.handler, call: call.handler, seconds: 2, seed: 4)
        let resumed = await eventually { me.appends > meAtUnmute }
        XCTAssertTrue(resumed)
        let after = Array(me.sent.dropFirst(sentAtUnmute))
        XCTAssertTrue(after.first?.contains("\"input_audio_buffer.clear\"") == true, "the clear goes again before any new mic audio")
        XCTAssertEqual(after.filter { $0.contains("\"input_audio_buffer.clear\"") }.count, 1)
    }

    /// Resuming from Pause with the mic off opens fresh sockets and streams only the call.
    func testResumingWithTheMicOffStreamsOnlyTheCall() async throws {
        session.startManual()
        let connected = await eventually { self.call.handler != nil && self.sockets.count == 2 }
        XCTAssertTrue(connected)
        let lateMic = mic.handler
        session.setPaused(true)
        session.setMicMuted(true)
        _ = await eventually { self.sockets.allSatisfy(\.isClosed) }
        session.setPaused(false)
        XCTAssertEqual(session.indicator, .micOff)
        let reopened = await eventually { self.sockets.filter { !$0.isClosed }.count == 2 && self.call.starts.count == 2 }
        XCTAssertTrue(reopened)
        XCTAssertFalse(mic.isOpen, "the device is never opened while muted")
        let fresh = sockets.filter { !$0.isClosed }
        let me = fresh[0], others = fresh[1]
        feed(mic: lateMic, call: call.handler, seconds: 2)
        feed(mic: mic.handler, call: nil, seconds: 1, seed: 5)
        let theirsFlow = await eventually { others.appends > 0 }
        XCTAssertTrue(theirsFlow)
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(me.appends, 0)
    }
}

final class GptCoreMicMuteTests: XCTestCase {
    var config: ListenMoreConfig!
    let v = GptFrames.voiced, z = GptFrames.silent

    override func setUpWithError() throws {
        config = try TestConfig.load()
    }

    func sent(_ actions: [GptCore.TxAction]) -> Int {
        actions.reduce(0) { n, a in
            if case let .send(_, s) = a { return n + s.count }
            return n
        }
    }

    func commits(_ actions: [GptCore.TxAction]) -> [TimeInterval] {
        actions.compactMap { if case let .commit(_, ref) = $0 { return ref } else { return nil } }
    }

    /// Muting mid-segment clears it; the user's frames are ignored from then on, the other side's still go out.
    func testMuteMidSegmentClearsItAndIgnoresTheUsersFrames() {
        let core = GptCore(config: config)
        XCTAssertGreaterThan(sent(core.feed(.me, frame: v, vad: GptFrames.vad(raw: true, onset: 0.2), now: 0.22)), 0)
        XCTAssertNotNil(core.cost.openS[.me])
        XCTAssertEqual(core.setMeMuted(true), [.clear(.me)])
        XCTAssertTrue(core.meMuted)
        XCTAssertNil(core.cost.openS[.me])
        XCTAssertEqual(core.feed(.me, frame: v, vad: GptFrames.vad(raw: true), now: 0.24), [])
        XCTAssertEqual(core.feed(.me, frame: v, vad: GptFrames.vad(raw: true, onset: 0.26), now: 0.26), [], "not even an onset")
        XCTAssertEqual(core.feed(.me, frame: z, vad: GptFrames.vad(raw: false, offset: 0.26), now: 0.4), [], "no commit")
        XCTAssertGreaterThan(sent(core.feed(.others, frame: v, vad: GptFrames.vad(raw: true, onset: 0.4), now: 0.42)), 0)
        XCTAssertEqual(core.cost.segments, 0)
    }

    /// A commit still waiting on the commit gap is dropped with the segment.
    func testMuteDropsACommitWaitingOnTheGap() {
        config.gpt.transcribeCommitGapMs = 300
        let core = GptCore(config: config)
        _ = core.feed(.me, frame: v, vad: GptFrames.vad(raw: true, onset: 0.5), now: 0.52)
        XCTAssertEqual(commits(core.feed(.me, frame: z, vad: GptFrames.vad(raw: false, offset: 1.0), now: 1.0)), [])
        XCTAssertEqual(core.setMeMuted(true), [.clear(.me)])
        XCTAssertEqual(core.setMeMuted(false), [])
        XCTAssertEqual(commits(core.feed(.me, frame: z, vad: GptFrames.quiet, now: 1.4)), [])
        XCTAssertEqual(core.cost.segments, 0)
    }

    /// Back on, nothing held from before the mute (pre-roll, a paused utterance's tail) goes out with the next utterance.
    func testUnmuteStartsWithoutPrerollOrHeldTail() {
        let core = GptCore(config: config)
        for i in 0..<10 { _ = core.feed(.me, frame: v, vad: GptFrames.quiet, now: Double(i) * 0.02) }
        XCTAssertEqual(core.setMeMuted(true), [], "pre-roll alone is nothing to clear")
        XCTAssertEqual(core.setMeMuted(false), [])
        XCTAssertEqual(sent(core.feed(.me, frame: v, vad: GptFrames.vad(raw: true, onset: 0.3), now: 0.3)), 480, "no pre-roll from before the mute")
        for i in 0..<3 { _ = core.feed(.me, frame: z, vad: GptFrames.vad(raw: false), now: 0.32 + Double(i) * 0.02) }
        XCTAssertEqual(core.setMeMuted(true), [.clear(.me)])
        XCTAssertEqual(core.setMeMuted(false), [])
        XCTAssertEqual(sent(core.feed(.me, frame: v, vad: GptFrames.vad(raw: true, onset: 0.5), now: 0.5)), 480, "the held pause is dropped")
    }

    /// Nothing open, an unchanged state, unmuting or a stopped layer: no clear.
    func testNoClearWithNothingOpenOrTheLayerOff() {
        let core = GptCore(config: config)
        XCTAssertEqual(core.setMeMuted(true), [])
        XCTAssertEqual(core.setMeMuted(true), [])
        XCTAssertEqual(core.setMeMuted(false), [])
        XCTAssertFalse(core.meMuted)
        _ = core.feed(.me, frame: v, vad: GptFrames.vad(raw: true, onset: 0.2), now: 0.22)
        for i in 0..<4 { _ = core.feed(.me, frame: v, vad: GptFrames.vad(raw: true), now: 0.24 + Double(i) * 0.02) }
        XCTAssertEqual(commits(core.feed(.me, frame: z, vad: GptFrames.vad(raw: false, offset: 0.22), now: 0.3)), [0.22])
        XCTAssertEqual(core.setMeMuted(true), [], "the segment was already committed")
        XCTAssertEqual(core.setMeMuted(false), [])
        _ = core.feed(.me, frame: v, vad: GptFrames.vad(raw: true, onset: 0.5), now: 0.52)
        core.fail("stopped")
        XCTAssertEqual(core.setMeMuted(true), [])
        XCTAssertTrue(core.meMuted)
    }

    /// A refused clear is retried once, at Unmute, and then forgotten.
    func testRejectedClearIsRetriedAtUnmute() {
        let core = GptCore(config: config)
        _ = core.feed(.me, frame: v, vad: GptFrames.vad(raw: true, onset: 0.2), now: 0.22)
        XCTAssertEqual(core.setMeMuted(true), [.clear(.me)])
        core.clearRejected(.me)
        XCTAssertTrue(core.enabled, "a refused clear never stops the layer")
        XCTAssertEqual(core.setMeMuted(false), [.clear(.me)])
        XCTAssertEqual(core.setMeMuted(true), [])
        XCTAssertEqual(core.setMeMuted(false), [])
    }

    /// The user's text while muted is neither kept in the transcript nor judged; the other side's is kept.
    func testTheUsersTextWhileMutedIsNotKeptOrJudged() {
        let core = GptCore(config: config)
        XCTAssertNil(core.onText(.others, text: "how would that work in practice", refT: 1, now: 1.5).start)
        _ = core.setMeMuted(true)
        let r = core.onText(.me, text: "it depends", refT: 2, now: 2.5)
        XCTAssertNil(r.start)
        XCTAssertEqual(r.refT, 2)
        XCTAssertEqual(core.transcript.lines.map(\.speaker), [.others])
        XCTAssertNil(core.onText(.others, text: "and what about the rollout plan", refT: 3, now: 3.5).start)
        XCTAssertEqual(core.transcript.lines.map(\.speaker), [.others, .others])
    }

    /// The other side's turn during the gap (or before it) doesn't arm the judge for the user's first line back.
    func testTheirTurnAcrossTheGapDoesNotArmTheJudge() {
        let control = GptCore(config: config)
        XCTAssertNil(control.onText(.others, text: "how would that work in practice", refT: 1, now: 1.5).start)
        XCTAssertNotNil(control.onText(.me, text: "it depends", refT: 2, now: 2.5).start, "control: judged without a mute")

        let during = GptCore(config: config)
        _ = during.setMeMuted(true)
        XCTAssertNil(during.onText(.others, text: "how would that work in practice", refT: 1, now: 1.5).start)
        _ = during.setMeMuted(false)
        XCTAssertNil(during.onText(.me, text: "it depends", refT: 2, now: 2.5).start)

        let before = GptCore(config: config)
        XCTAssertNil(before.onText(.others, text: "how would that work in practice", refT: 1, now: 1.5).start)
        _ = before.setMeMuted(true)
        _ = before.setMeMuted(false)
        XCTAssertNil(before.onText(.me, text: "it depends", refT: 2, now: 2.5).start)
        XCTAssertEqual(before.snapshot.judgeCalls + during.snapshot.judgeCalls, 0)
    }
}

final class GptLayerMicMuteTests: XCTestCase {
    final class CaptionBox: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [CaptionEvent] = []
        var events: [CaptionEvent] { lock.withLock { _events } }
        func add(_ e: CaptionEvent) { lock.withLock { _events.append(e) } }
    }

    final class EmitBox: @unchecked Sendable {
        private let lock = NSLock()
        private var sinks: [Speaker: @Sendable (TranscriptEvent) -> Void] = [:]
        func set(_ s: Speaker, _ f: @escaping @Sendable (TranscriptEvent) -> Void) { lock.withLock { sinks[s] = f } }
        func emit(_ e: TranscriptEvent, as s: Speaker) { lock.withLock { sinks[s] }?(e) }
    }

    var config: ListenMoreConfig!
    let segments = SegmentBox()
    let captions = CaptionBox()
    let emit = EmitBox()
    var transcribers: [Speaker: FakeTranscriber] = [:]
    let v = GptFrames.voiced, z = GptFrames.silent

    override func setUpWithError() throws {
        config = try TestConfig.load()
    }

    func makeLayer(me: [String] = [], others: [String] = []) -> GptLayer {
        let segments = segments, captions = captions, emit = emit
        var made: [Speaker: FakeTranscriber] = [:]
        let layer = GptLayer(config: config, now: { 0 }, offer: { _, _, _, _ in },
                             onSegment: { s, t, r, _ in segments.add(s, t, r) }, onCaption: { captions.add($0) },
                             judge: FakeJudge(), scheduler: InstantScheduler()) { speaker, onEvent in
            emit.set(speaker, onEvent)
            let t = FakeTranscriber(speaker: speaker, script: speaker == .me ? me : others, onEvent: onEvent)
            made[speaker] = t
            return t
        }
        transcribers = made
        layer.start()
        return layer
    }

    /// Mute mid-utterance clears the user's transcriber and sends it nothing until unmute; the other side's stream is untouched.
    func testMuteClearsTheUsersTranscriberAndSendsItNothingUntilUnmute() async throws {
        let layer = makeLayer(me: ["one"], others: ["two"])
        layer.feed(me: v, meVad: GptFrames.vad(raw: true, onset: 1), others: z, othersVad: GptFrames.quiet, meRunS: 0)
        layer.setMicMuted(true)
        layer.feed(me: v, meVad: GptFrames.vad(raw: true), others: v, othersVad: GptFrames.vad(raw: true, onset: 1.1), meRunS: 0)
        for _ in 0..<5 { layer.feed(me: v, meVad: GptFrames.vad(raw: true), others: v, othersVad: GptFrames.vad(raw: true), meRunS: 0) }
        layer.feed(me: z, meVad: GptFrames.vad(raw: false, offset: 1.2), others: z, othersVad: GptFrames.vad(raw: false, offset: 1.2), meRunS: 0)
        _ = await layer.snapshot()
        let me = try XCTUnwrap(transcribers[.me]), others = try XCTUnwrap(transcribers[.others])
        XCTAssertEqual(me.clears, 1)
        XCTAssertEqual(me.bytesSent, 480 * 2, "only the frame before the mute")
        XCTAssertEqual(me.commits, [])
        XCTAssertEqual(others.clears, 0)
        XCTAssertEqual(others.commits, [1.2])

        layer.setMicMuted(false)
        layer.feed(me: v, meVad: GptFrames.vad(raw: true, onset: 2), others: z, othersVad: GptFrames.quiet, meRunS: 0)
        for _ in 0..<5 { layer.feed(me: v, meVad: GptFrames.vad(raw: true), others: z, othersVad: GptFrames.quiet, meRunS: 0) }
        layer.feed(me: z, meVad: GptFrames.vad(raw: false, offset: 2.2), others: z, othersVad: GptFrames.quiet, meRunS: 0)
        let both = await eventually { self.segments.segments.count == 2 }
        XCTAssertTrue(both)
        XCTAssertEqual(me.commits, [2.2])
        XCTAssertEqual(me.clears, 1)
        XCTAssertEqual(segments.segments.map { $0.0 }, [.others, .me])
        await layer.close()
    }

    /// While muted the user's partial and final text reach neither captions nor the transcript rules; the other side's do.
    func testTheUsersTextWhileMutedIsDropped() async {
        let layer = makeLayer()
        layer.setMicMuted(true)
        _ = await layer.snapshot()
        emit.emit(.delta(.me, "alpha ", item: "a"), as: .me)
        emit.emit(.text(.me, "alpha bravo", refT: 1), as: .me)
        emit.emit(.text(.others, "charlie delta", refT: 1), as: .others)
        let theirs = await eventually { self.captions.events.contains(.final(.others, text: "charlie delta")) }
        XCTAssertTrue(theirs)
        _ = await layer.snapshot()
        XCTAssertEqual(captions.events, [.final(.others, text: "charlie delta")])
        XCTAssertEqual(segments.segments.map { $0.0 }, [.others])

        layer.setMicMuted(false)
        emit.emit(.text(.me, "echo foxtrot", refT: 2), as: .me)
        let mine = await eventually { self.captions.events.contains(.final(.me, text: "echo foxtrot")) }
        XCTAssertTrue(mine, "back on, the user's text flows again")
        await layer.close()
    }
}

/// Mute in the local layer on synthetic two-stream audio (mic = the user, call = everyone else).
final class LocalLayerMicMuteTests: XCTestCase {
    var config: ListenMoreConfig!
    let meF0 = 120.0, othersF0 = 210.0

    override func setUpWithError() throws {
        config = try TestConfig.load()
    }

    /// Steps the local layer frame by frame, applying each mute change before the frame that starts at its time.
    func run(_ total: Double, me: [(Double, Double)], others: [(Double, Double)], participants: Int = 2,
             mutes: [(at: Double, muted: Bool)] = []) -> [LocalEvent] {
        let mic = Synthetic.track(total, me, f0: meF0), call = Synthetic.track(total, others, f0: othersF0)
        let layer = LocalLayer(config: config, participants: participants)
        let hop = config.frameSamples
        var changes = mutes
        var out: [LocalEvent] = []
        for i in 0..<(mic.count / hop) {
            while let next = changes.first, next.at <= Double(i) * config.frameS + 1e-9 {
                layer.setMicMuted(next.muted)
                changes.removeFirst()
            }
            out += layer.step(t: Double(i + 1) * config.frameS, mic: mic[(i * hop)..<((i + 1) * hop)],
                              call: call[(i * hop)..<((i + 1) * hop)]).events
        }
        return out
    }

    func cues(_ evs: [LocalEvent]) -> [LocalEvent.Kind] { evs.filter { $0.cueType != nil }.map(\.kind) }

    /// The user's onset within a second of unmuting opens no cut-in, even over the other side; later it does.
    func testOnsetRightAfterUnmuteOpensNoCutIn() {
        let me: [(Double, Double)] = [(3.0, 6.0)], others: [(Double, Double)] = [(1.0, 5.5)]
        XCTAssertEqual(cues(run(8, me: me, others: others)), [.interrupt], "control")
        let settling = run(8, me: me, others: others, mutes: [(0, true), (2.9, false)])
        XCTAssertEqual(cues(settling), [])
        XCTAssertTrue(settling.contains { $0.kind == .meOnset }, "the user is heard, just not as a cut-in")
        XCTAssertEqual(cues(run(8, me: me, others: others, mutes: [(0, true), (1.0, false)])), [.interrupt], "past the grace second")
    }

    /// The grace is the rules' `local.unmute_grace_s` (1 s by default), not a constant in the layer.
    func testUnmuteGraceComesFromTheRules() {
        XCTAssertEqual(config.local.unmuteGraceS, 1.0)
        let me: [(Double, Double)] = [(3.0, 6.0)], others: [(Double, Double)] = [(1.0, 5.5)]
        config.local.unmuteGraceS = 0
        XCTAssertEqual(cues(run(8, me: me, others: others, mutes: [(0, true), (2.9, false)])), [.interrupt], "no grace")
        config.local.unmuteGraceS = 2.5
        XCTAssertEqual(cues(run(8, me: me, others: others, mutes: [(0, true), (1.0, false)])), [], "a longer grace")
    }

    /// While muted the user's speech is not heard at all: no onset, no cut-in.
    func testMutedSpeechIsNotHeard() {
        let evs = run(8, me: [(3.0, 6.0)], others: [(1.0, 5.5)], mutes: [(0, true)])
        XCTAssertFalse(evs.contains { $0.kind == .meOnset || $0.kind == .meOffset })
        XCTAssertEqual(cues(evs), [])
        XCTAssertTrue(evs.contains { $0.kind == .othersOnset })
    }

    /// Mute drops the user's turn: talking again after unmute starts a new run, so no monologue spans the gap.
    func testMuteDropsTheTurnSoNoMonologueSpansTheGap() {
        config.local.monologueSoftS = 4
        config.local.monologueStrongS = 100
        config.local.monologueRelativeMinRuns = 1000
        let me: [(Double, Double)] = [(1.0, 4.0), (5.0, 7.5)]
        XCTAssertEqual(cues(run(9, me: me, others: [])), [.monologue], "control: a 1 s pause keeps the run going")
        XCTAssertEqual(cues(run(9, me: me, others: [], mutes: [(3.5, true), (4.5, false)])), [])
    }

    /// The utterance cut short by Mute never reports an offset or a prosody reading.
    func testUtteranceCutShortByMuteReportsNoOffset() {
        XCTAssertEqual(run(6, me: [(1.0, 4.0)], others: []).filter { $0.kind == .meOffset }.count, 1, "control")
        let evs = run(6, me: [(1.0, 4.0)], others: [], mutes: [(2.0, true)])
        XCTAssertTrue(evs.contains { $0.kind == .meOnset })
        XCTAssertFalse(evs.contains { $0.kind == .meOffset || $0.kind == .prosody })
    }

    /// Talk share counts the gap as the user silent (what the call heard): the other side's speech
    /// while muted still dilutes the user's share, so the gap can't raise a talk-share cue after unmute.
    func testTalkShareCountsTheGapAsTheUserSilent() {
        config.local.talkShareMinSpeechS = 3
        config.local.talkShareMaxGroup = 0.6
        config.local.monologueRelativeMinRuns = 1000
        let me: [(Double, Double)] = [(0.5, 2.0), (10.5, 14.0)], others: [(Double, Double)] = [(3.0, 10.0)]
        XCTAssertEqual(cues(run(15, me: me, others: others, participants: 3)), [], "control: their 7 s keep the user's share low")
        let muted = run(15, me: me, others: others, participants: 3, mutes: [(2.3, true), (10.2, false)])
        XCTAssertEqual(muted.filter { $0.kind == .talkShare }, [], "their speech in the gap still counts")
        let talkingWhileMuted = run(15, me: [(0.5, 2.0), (3.0, 10.0), (10.5, 14.0)], others: [(3.0, 10.0)], participants: 3,
                                    mutes: [(2.3, true), (10.2, false)])
        XCTAssertEqual(talkingWhileMuted.filter { $0.kind == .talkShare }, [], "the user's muted speech isn't counted")
    }

    /// The pipeline passes Mute to the local layer, the transcript rules and the GPT layer.
    func testPipelinePassesMuteToEveryLayer() {
        let gpt = StubPipelineGpt()
        let p = CoachPipeline(config: config, gpt: gpt)
        p.setMicMuted(true)
        XCTAssertTrue(p.local.micMuted)
        XCTAssertEqual(p.text?.micMuted, true)
        p.setMicMuted(false)
        XCTAssertFalse(p.local.micMuted)
        XCTAssertEqual(p.text?.micMuted, false)
        XCTAssertEqual(gpt.micMutes, [true, false])
    }

    /// A trailing cut-in waiting on the other side's last words is dropped by Mute, so it can't fire across it.
    func testMuteDropsAWaitingCutIn() {
        let mic = Synthetic.track(9, [(3.0, 6.5)], f0: meF0), call = Synthetic.track(9, [(1.0, 3.45)], f0: othersF0)
        let hop = config.frameSamples
        for mute in [false, true] {
            let gpt = StubPipelineGpt()
            let p = CoachPipeline(config: config, gpt: gpt)
            var cues: [Cue] = []
            var raised = false, landed = false
            for i in 0..<(mic.count / hop) {
                let t = Double(i + 1) * config.frameS
                if raised && !landed {
                    if mute { p.setMicMuted(true) }
                    gpt.queued = [.segment(.others, "We could ship it now but", refT: 3.4, now: t)]
                    landed = true
                }
                cues += p.process(t: t, mic: mic[(i * hop)..<((i + 1) * hop)], call: call[(i * hop)..<((i + 1) * hop)])
                if gpt.locals.contains(.interrupt) { raised = true }
            }
            XCTAssertTrue(raised, "mute=\(mute)")
            XCTAssertEqual(cues.map(\.type), mute ? [] : [.interrupt], "mute=\(mute)")
        }
    }
}

final class TextRulesMicMuteTests: XCTestCase {
    var config: ListenMoreConfig!
    let question = "Can you send the report by Friday?"
    let drift = "Well I was thinking about the garden over the long weekend"

    override func setUpWithError() throws {
        config = try TestConfig.load()
    }

    func quiet(_ r: TextRules, from: Double, to: Double) -> [CueSuggestion] {
        var out: [CueSuggestion] = []
        var t = from
        while t <= to + 1e-9 {
            out += r.onTick(now: t, userActive: false, frameS: 0.02)
            t += 0.02
        }
        return out
    }

    /// Mute drops the question pending on the user, so their unrelated first words back aren't a missed answer.
    func testMuteDropsAPendingQuestion() throws {
        let control = TextRules(config: config)
        _ = control.onSegment(.others, text: question, refT: 1, now: 1.5)
        XCTAssertNotNil(control.pending)
        let cue = try XCTUnwrap(control.onSegment(.me, text: drift, refT: 4, now: 4.5).first, "control")
        XCTAssertEqual(cue.type, .missedQuestion)
        XCTAssertEqual(cue.level, .soft)

        let r = TextRules(config: config)
        _ = r.onSegment(.others, text: question, refT: 1, now: 1.5)
        XCTAssertNotNil(r.pending)
        r.setMicMuted(true)
        XCTAssertNil(r.pending)
        r.setMicMuted(false)
        XCTAssertEqual(r.onSegment(.me, text: drift, refT: 4, now: 4.5), [])
        XCTAssertEqual(quiet(r, from: 5, to: 12), [])
    }

    /// A question the other side asks while the user is muted opens nothing.
    func testQuestionAskedWhileMutedOpensNothing() {
        let r = TextRules(config: config)
        r.setMicMuted(true)
        _ = r.onSegment(.others, text: question, refT: 1, now: 1.5)
        XCTAssertNil(r.pending)
        r.setMicMuted(false)
        XCTAssertEqual(r.onSegment(.me, text: drift, refT: 4, now: 4.5), [])
        XCTAssertEqual(quiet(r, from: 5, to: 12), [])
        _ = r.onSegment(.others, text: question, refT: 13, now: 13.5)
        XCTAssertNotNil(r.pending, "back on, questions are tracked again")
    }

    /// Through the pipeline: a question before the mute isn't a missed answer once the user is back.
    func testPipelineMuteKeepsTheReplyAfterTheGapFromBeingAMissedAnswer() {
        let silence = [Float](repeating: 0, count: 480)
        let gpt = StubPipelineGpt()
        let p = CoachPipeline(config: config, gpt: gpt)
        gpt.queued = [.segment(.others, question, refT: 1, now: 1.5)]
        XCTAssertEqual(p.process(t: 1.5, mic: silence[...], call: silence[...]), [])
        p.setMicMuted(true)
        p.setMicMuted(false)
        gpt.queued = [.segment(.me, drift, refT: 4, now: 4.5)]
        XCTAssertEqual(p.process(t: 4.5, mic: silence[...], call: silence[...]), [])
        XCTAssertEqual(gpt.micMutes, [true, false])
    }
}

final class FrameAlignerMicSilencedTests: XCTestCase {
    let hop = 480

    func filled(_ value: Float, _ n: Int) -> [Float] { [Float](repeating: value, count: n) }

    /// With the mic silenced, each call frame goes out at once paired with silence, with no wait for the mic.
    func testSilencedMicPairsEachCallFrameWithSilenceAtOnce() {
        var control = FrameAligner(hop: hop, maxLagSamples: 4800)
        control.append(.call, filled(0.5, hop))
        XCTAssertEqual(control.popFrames().count, 0, "control: waits up to maxLag for the mic")

        var a = FrameAligner(hop: hop, maxLagSamples: 4800)
        a.micSilenced = true
        a.append(.call, filled(0.5, hop * 2 + 100))
        let frames = a.popFrames()
        XCTAssertEqual(frames.count, 2)
        XCTAssertTrue(frames.allSatisfy { $0.mic == filled(0, hop) && $0.call == filled(0.5, hop) })
        XCTAssertEqual(a.buffered.call, 100)
        XCTAssertEqual(a.paddedFrames, 2)
    }

    /// Silencing drops mic samples already buffered and every mic sample appended while it lasts.
    func testSilencedMicDropsBufferedAndIncomingMicSamples() {
        var a = FrameAligner(hop: hop, maxLagSamples: 4800)
        a.append(.mic, filled(1, 300))
        a.micSilenced = true
        XCTAssertEqual(a.buffered.mic, 0)
        a.append(.mic, filled(1, hop * 2))
        XCTAssertEqual(a.buffered.mic, 0)
        a.append(.call, filled(0.5, hop))
        XCTAssertEqual(a.popFrames().first?.mic, filled(0, hop))
    }

    /// Once the silence is cleared, frames pair mic with call again and a lone call frame waits.
    func testClearingTheSilencePairsFramesNormally() {
        var a = FrameAligner(hop: hop, maxLagSamples: 4800)
        a.micSilenced = true
        a.append(.call, filled(0.5, hop))
        XCTAssertEqual(a.popFrames().count, 1)
        a.micSilenced = false
        a.append(.call, filled(0.5, hop))
        XCTAssertEqual(a.popFrames().count, 0)
        a.append(.mic, filled(1, hop))
        let frames = a.popFrames()
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.mic, filled(1, hop))
        XCTAssertEqual(frames.first?.call, filled(0.5, hop))
    }
}

final class LiveTranscriberClearTests: XCTestCase {
    func transcriber(_ connector: FakeConnector) throws -> LiveTranscriber {
        LiveTranscriber(config: try TestConfig.load(), key: try XCTUnwrap(APIKey("sk-test")), speaker: .me,
                        connector: connector, onEvent: { _ in })
    }

    /// Clear sends exactly `input_audio_buffer.clear`, tagged with an event id, on the open socket.
    func testClearSendsOnlyTheBufferClear() async throws {
        let connector = FakeConnector()
        let t = try transcriber(connector)
        try await t.start()
        let socket = try XCTUnwrap(connector.connections.first?.socket)
        let before = socket.sent.count
        try await t.clear()
        XCTAssertEqual(socket.sent.count, before + 1)
        let msg = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(try XCTUnwrap(socket.sent.last).utf8)) as? [String: Any])
        XCTAssertEqual(msg.count, 2)
        XCTAssertEqual(msg["type"] as? String, "input_audio_buffer.clear")
        XCTAssertEqual(msg["event_id"] as? String, "lm_clear_1")
        await t.close()
    }

    /// A server error naming a clear's event id is that clear's rejection (non-fatal); any other
    /// error, or one naming a clear the server already acknowledged, is still a session error.
    func testServerErrorForAClearIsARejectionNotAFailure() async throws {
        let connector = FakeConnector()
        let events = EventBox()
        let t = LiveTranscriber(config: try TestConfig.load(), key: try XCTUnwrap(APIKey("sk-test")), speaker: .me,
                                connector: connector) { events.append($0) }
        try await t.start()
        try await t.clear()
        try await t.clear()
        t.handle(#"{"type":"error","error":{"type":"invalid_request_error","code":"x","event_id":"lm_clear_2"}}"#)
        XCTAssertEqual(events.clearRejections, [.me])
        XCTAssertEqual(events.errors, [])
        t.handle(#"{"type":"input_audio_buffer.cleared","event_id":"server_1"}"#)
        t.handle(#"{"type":"error","error":{"type":"invalid_request_error","code":"x","event_id":"lm_clear_1"}}"#)
        t.handle(#"{"type":"error","error":{"type":"server_error","code":"y"}}"#)
        XCTAssertEqual(events.clearRejections, [.me])
        XCTAssertEqual(events.errors, ["realtime error invalid_request_error/x", "realtime error server_error/y"])
        await t.close()
    }

    /// Without a socket (before start, after close) clear does nothing and doesn't throw.
    func testClearWithoutASocketIsANoOp() async throws {
        let connector = FakeConnector()
        let t = try transcriber(connector)
        try await t.clear()
        XCTAssertTrue(connector.connections.isEmpty)
        try await t.start()
        await t.close()
        let socket = try XCTUnwrap(connector.connections.first?.socket)
        let sent = socket.sent.count
        try await t.clear()
        XCTAssertEqual(socket.sent.count, sent)
        XCTAssertEqual(socket.sendsAfterClose, 0)
    }
}

final class LocalCoachEngineMicMuteTests: XCTestCase {
    var config: ListenMoreConfig!

    override func setUpWithError() throws {
        config = try TestConfig.load()
    }

    /// Mute needs a running engine, and every start begins with the mic on.
    func testMuteNeedsARunningEngineAndStartResetsIt() {
        let engine = LocalCoachEngine()
        engine.setMicMuted(true)
        XCTAssertFalse(engine.micMuted, "ignored before start")
        engine.start(config: config, apiKey: nil)
        XCTAssertFalse(engine.micMuted)
        engine.setMicMuted(true)
        XCTAssertTrue(engine.micMuted)
        engine.start(config: config, apiKey: nil)
        XCTAssertFalse(engine.micMuted, "start resets it")
        engine.stop()
        engine.setMicMuted(true)
        XCTAssertFalse(engine.micMuted, "ignored after stop")
    }

    /// Muted mic samples drive no frames; call samples go out at once, with no wait for the mic.
    func testMutedMicDrivesNoFramesAndCallFramesGoOutAtOnce() {
        let engine = LocalCoachEngine(maxLagMs: 200)
        engine.start(config: config, apiKey: nil)
        engine.setMicMuted(true)
        engine.ingest(.mic, samples: [Float](repeating: 0, count: 24000), time: 0)
        XCTAssertEqual(engine.framesProcessed, 0)
        engine.ingest(.call, samples: [Float](repeating: 0, count: 480), time: 0)
        XCTAssertEqual(engine.framesProcessed, 1)
        engine.setMicMuted(false)
        engine.ingest(.call, samples: [Float](repeating: 0, count: 480), time: 0)
        XCTAssertEqual(engine.framesProcessed, 1, "unmuted, a call frame waits for the mic again")
        engine.ingest(.mic, samples: [Float](repeating: 0, count: 480), time: 0)
        XCTAssertEqual(engine.framesProcessed, 2)
    }

    /// Muted for the whole cut-in scenario: the call alone drives the frames and no cue fires.
    func testMutedThroughTheCutInScenarioSuggestsNothing() {
        let mic = Synthetic.track(8, [(3.0, 6.0)], f0: 120), call = Synthetic.track(8, [(1.0, 5.5)], f0: 210)
        let engine = LocalCoachEngine()
        let collector = LocalCoachEngineTests.Collector()
        engine.delegate = collector
        engine.start(config: config, apiKey: nil)
        engine.setMicMuted(true)
        for i in stride(from: 0, to: mic.count, by: 1024) {
            let end = min(i + 1024, mic.count)
            engine.ingest(.mic, samples: Array(mic[i..<end]), time: 0)
            engine.ingest(.call, samples: Array(call[i..<end]), time: 0)
        }
        XCTAssertEqual(engine.framesProcessed, 400)
        XCTAssertEqual(collector.cues.map(\.type), [])
        engine.stop()
    }
}
