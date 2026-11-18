import Foundation
@testable import ListenMoreCore

// Test doubles for every seam. They hold content only in memory and never touch disk or network.

final class FakeMic: MicSource {
    var started = 0
    var stopped = 0
    var failNext = false
    /// A failed `start` still keeps the handler, as `RoutedMic` does while it retries the open.
    var keepsHandlerOnFailedStart = false
    var handler: (@Sendable ([Float]) -> Void)?

    func start(sampleRate: Int, handler: @escaping @Sendable ([Float]) -> Void) throws {
        if failNext {
            failNext = false
            if keepsHandlerOnFailedStart { self.handler = handler }
            throw NSError(domain: "FakeMic", code: 1)
        }
        started += 1
        self.handler = handler
    }

    func stop() {
        stopped += 1
        handler = nil
        isMuted = false
    }

    /// Every `setMuted` call, in order.
    var muted: [Bool] = []
    private(set) var isMuted = false
    /// Started and not muted: the device would be open.
    var isOpen: Bool { handler != nil && !isMuted }

    /// `failNext` also fails the next unmute's reopen (the device stays closed).
    func setMuted(_ muted: Bool) -> Bool {
        self.muted.append(muted)
        isMuted = muted
        if !muted && failNext {
            failNext = false
            isMuted = true
            return false
        }
        return true
    }
}

final class FakeCall: CallSource, @unchecked Sendable {
    private let lock = NSLock()
    private var _starts: [(bundleIds: [String], stage: CaptureStage)] = []
    private var _handler: (@Sendable ([Float]) -> Void)?
    private var _stops = 0
    var failStages: Set<CaptureStage> = []

    var starts: [(bundleIds: [String], stage: CaptureStage)] { lock.withLock { _starts } }
    var stops: Int { lock.withLock { _stops } }
    var handler: (@Sendable ([Float]) -> Void)? { lock.withLock { _handler } }

    func start(bundleIds: [String], stage: CaptureStage, sampleRate: Int, handler: @escaping @Sendable ([Float]) -> Void) async throws {
        let fail = lock.withLock { () -> Bool in
            _starts.append((bundleIds, stage))
            _handler = handler
            return failStages.contains(stage)
        }
        if fail { throw NSError(domain: "FakeCall", code: 2) }
    }

    func stop() async {
        lock.withLock { _stops += 1 }
    }
}

final class FakeProbe: MeetingProbe {
    var windowList: [WindowInfo] = []
    var audio: [String: Bool] = [:]

    func windows() -> [WindowInfo] { windowList }
    func audioActive() -> [String: Bool] { audio }
}

struct FakeKeys: APIKeyProvider {
    var key: APIKey?
    var fails = false

    func readKey() throws -> APIKey? {
        if fails { throw NSError(domain: "FakeKeys", code: 3) }
        return key
    }
}

@MainActor
final class FakeRenderer: CueRenderer {
    var rendered: [Cue] = []
    var clears = 0

    func render(_ cue: Cue) { rendered.append(cue) }
    func clear() { clears += 1 }
}

final class FakeAudioStateProvider: AudioStateProvider {
    var inputRunning = true
    var processes: [AudioProcessState] = []

    func snapshot() -> AudioStateSnapshot { AudioStateSnapshot(defaultInputRunning: inputRunning, processes: processes) }

    func zoomCall() {
        inputRunning = true
        processes = [AudioProcessState(pid: 50, bundleId: "us.zoom.xos", isRunningInput: true, isRunningOutput: true)]
    }

    func silence() {
        inputRunning = false
        processes = []
    }
}

@MainActor
final class RecordingDelegate: CoachSessionDelegate {
    var indicators: [CoachIndicator] = []
    var cues: [Cue] = []
    var problems: [CoachSession.Problem] = []
    var captions: [CaptionEvent] = []
    var meters: [CostReading] = []

    func coachSessionDidChange(_ session: CoachSession) {
        if indicators.last != session.indicator { indicators.append(session.indicator) }
    }
    func coachSession(_ session: CoachSession, didShow cue: Cue) { cues.append(cue) }
    func coachSession(_ session: CoachSession, didReport problem: CoachSession.Problem) { problems.append(problem) }
    func coachSession(_ session: CoachSession, didCaption event: CaptionEvent) { captions.append(event) }
    func coachSession(_ session: CoachSession, didMeter reading: CostReading) { meters.append(reading) }
}

/// Engine double that records calls and lets tests emit suggestions.
final class RecordingEngine: CoachEngine, @unchecked Sendable {
    // Ingest runs on the session's engine queue while tests poll from theirs.
    private let lock = NSLock()
    private weak var _delegate: CoachEngineDelegate?
    private var _isRunning = false
    private var _startedWithKey: [Bool] = []
    private var _ingested: [AudioStream: Int] = [:]
    private var _stops = 0
    private var _micMutes: [Bool] = []

    var delegate: CoachEngineDelegate? {
        get { lock.withLock { _delegate } }
        set { lock.withLock { _delegate = newValue } }
    }
    var isRunning: Bool { lock.withLock { _isRunning } }
    var startedWithKey: [Bool] { lock.withLock { _startedWithKey } }
    var ingested: [AudioStream: Int] { lock.withLock { _ingested } }
    var stops: Int { lock.withLock { _stops } }
    /// Every `setMicMuted` call, in order.
    var micMutes: [Bool] { lock.withLock { _micMutes } }

    func setMicMuted(_ muted: Bool) {
        lock.withLock { _micMutes.append(muted) }
    }

    func start(config: ListenMoreConfig, apiKey: APIKey?) {
        lock.withLock {
            _isRunning = true
            _startedWithKey.append(apiKey != nil)
        }
    }

    func ingest(_ stream: AudioStream, samples: [Float], time: TimeInterval) {
        lock.withLock { _ingested[stream, default: 0] += samples.count }
    }

    func stop() {
        lock.withLock {
            _isRunning = false
            _stops += 1
        }
    }

    func emit(_ s: CueSuggestion) {
        delegate?.engine(self, didSuggest: s)
    }

    func stopGpt(_ reason: GptStopReason) {
        delegate?.engine(self, gptStopped: reason)
    }

    func stopJudge(_ failure: JudgeFailure) {
        delegate?.engine(self, judgeStopped: failure)
    }

    func emitCaption(_ e: CaptionEvent) {
        delegate?.engine(self, caption: e)
    }

    func emitMeter(_ r: CostReading) {
        delegate?.engine(self, meter: r)
    }
}

/// Settable wall clock.
final class ManualClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval

    init(_ t: TimeInterval = 1000) { self.t = t }

    func now() -> TimeInterval { lock.withLock { t } }
    func advance(_ dt: TimeInterval) { lock.withLock { t += dt } }
    func set(_ v: TimeInterval) { lock.withLock { t = v } }
}

// MARK: network fakes

/// Records requests; answers with a canned Responses API reply.
final class FakeHTTP: HTTPTransport, @unchecked Sendable {
    struct Request {
        var url: URL
        var headers: [String: String]
        var body: [String: Any]
        var timeout: TimeInterval
    }

    private let lock = NSLock()
    private var _requests: [Request] = []
    var status = 200
    var reply: (cue: String, confidence: Double) = ("none", 0.9)
    var usage = (input: 1000, cached: 200, output: 30)
    /// Replies served before the canned one, oldest first (status, body).
    var queued: [(Int, Data)] = []

    var requests: [Request] { lock.withLock { _requests } }

    func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval) async throws -> (status: Int, body: Data) {
        let parsed = (try? JSONSerialization.jsonObject(with: body) as? [String: Any]) ?? [:]
        let (next, status, reply, usage) = lock.withLock { () -> ((Int, Data)?, Int, (cue: String, confidence: Double), (input: Int, cached: Int, output: Int)) in
            _requests.append(Request(url: url, headers: headers, body: parsed, timeout: timeout))
            let next = queued.isEmpty ? nil : queued.removeFirst()
            return (next, self.status, self.reply, self.usage)
        }
        if let next { return next }
        let inner = try JSONSerialization.data(withJSONObject: ["cue": reply.cue, "confidence": reply.confidence, "short_reason": "test reason"])
        let response: [String: Any] = [
            "output": [["type": "message", "content": [["type": "output_text", "text": String(data: inner, encoding: .utf8)!]]]],
            "usage": ["input_tokens": usage.input, "input_tokens_details": ["cached_tokens": usage.cached], "output_tokens": usage.output],
        ]
        return (status, try JSONSerialization.data(withJSONObject: response))
    }
}

/// In-memory WebSocket: records sent messages and replays scripted server messages.
final class FakeSocket: WebSocketConnection, @unchecked Sendable {
    private let lock = NSLock()
    private var _sent: [String] = []
    private var inbox: [String] = []
    private var waiters: [CheckedContinuation<String, Error>] = []
    private var closed = false

    private var _sendsAfterClose = 0

    var sent: [String] { lock.withLock { _sent } }
    var isClosed: Bool { lock.withLock { closed } }
    /// Sends attempted on a closed socket (a send after Pause would show up here).
    var sendsAfterClose: Int { lock.withLock { _sendsAfterClose } }
    var appends: Int { sent.filter { $0.contains("\"input_audio_buffer.append\"") }.count }

    func send(_ text: String) async throws {
        let isClosed = lock.withLock { () -> Bool in
            if closed { _sendsAfterClose += 1 } else { _sent.append(text) }
            return closed
        }
        if isClosed { throw GptError.notConnected }
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { c in
            lock.lock()
            if closed {
                lock.unlock()
                c.resume(throwing: GptError.notConnected)
            } else if !inbox.isEmpty {
                let m = inbox.removeFirst()
                lock.unlock()
                c.resume(returning: m)
            } else {
                waiters.append(c)
                lock.unlock()
            }
        }
    }

    func push(_ message: String) {
        lock.lock()
        if let w = waiters.first {
            waiters.removeFirst()
            lock.unlock()
            w.resume(returning: message)
        } else {
            inbox.append(message)
            lock.unlock()
        }
    }

    func close() {
        let ws = lock.withLock { () -> [CheckedContinuation<String, Error>] in
            closed = true
            defer { waiters.removeAll() }
            return waiters
        }
        ws.forEach { $0.resume(throwing: GptError.notConnected) }
    }
}

final class FakeConnector: WebSocketConnector, @unchecked Sendable {
    private let lock = NSLock()
    private var _connections: [(url: URL, headers: [String: String], socket: FakeSocket)] = []
    var fail = false

    var connections: [(url: URL, headers: [String: String], socket: FakeSocket)] { lock.withLock { _connections } }

    func connect(url: URL, headers: [String: String]) async throws -> WebSocketConnection {
        if fail { throw URLError(.cannotConnectToHost) }
        let s = FakeSocket()
        lock.withLock { _connections.append((url, headers, s)) }
        return s
    }
}

/// Scheduler with no real waiting: sleeps return at once, monotonic time is settable.
final class InstantScheduler: GptScheduler, @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval = 100
    private var _sleeps: [Double] = []

    var sleeps: [Double] { lock.withLock { _sleeps } }

    func monotonic() -> TimeInterval { lock.withLock { t } }
    func advance(_ dt: Double) { lock.withLock { t += dt } }

    func sleep(seconds: Double) async throws {
        lock.withLock { _sleeps.append(seconds) }
        await Task.yield()
    }
}

/// Transcription double: records audio and commits, emits scripted text on commit.
final class FakeTranscriber: TranscriptionSession, @unchecked Sendable {
    private let lock = NSLock()
    private var _bytes = 0
    private var _commits: [TimeInterval] = []
    private var _clears = 0
    private var script: [String]
    private let speaker: Speaker
    private let onEvent: @Sendable (TranscriptEvent) -> Void
    var failSend = false
    /// Billed seconds reported (as a usage event) for each commit; nil = the API reports none.
    var billedPerCommit: Double?
    /// Emit each scripted line word by word as realtime deltas before its final text.
    var deltas = false
    private(set) var closed = false

    init(speaker: Speaker, script: [String], onEvent: @escaping @Sendable (TranscriptEvent) -> Void) {
        self.speaker = speaker
        self.script = script
        self.onEvent = onEvent
    }

    var bytesSent: Int { lock.withLock { _bytes } }
    var commits: [TimeInterval] { lock.withLock { _commits } }
    var clears: Int { lock.withLock { _clears } }

    func clear() async throws {
        lock.withLock { _clears += 1 }
    }

    func start() async throws {}

    func sendAudio(_ pcm16: Data) async throws {
        if failSend { throw URLError(.networkConnectionLost) }
        lock.withLock { _bytes += pcm16.count }
    }

    func commit(refT: TimeInterval) async throws {
        let (text, n) = lock.withLock { () -> (String?, Int) in
            _commits.append(refT)
            return (script.isEmpty ? nil : script.removeFirst(), _commits.count)
        }
        if deltas, let text {
            for word in text.split(separator: " ") { onEvent(.delta(speaker, word + " ", item: "item\(n)")) }
        }
        if let billedPerCommit { onEvent(.usage(speaker, billedPerCommit)) }
        if let text { onEvent(.text(speaker, text, refT: refT)) }
    }

    func close() async { lock.withLock { closed = true } }
}

/// Judge double: records prompts, answers from a queue (defaults to "none").
final class FakeJudge: CueJudge, @unchecked Sendable {
    private let lock = NSLock()
    private var _prompts: [String] = []
    private var answers: [JudgeResult]
    var fail = false
    /// Thrown (once each, oldest first) before answering.
    var errors: [Error] = []

    init(answers: [JudgeResult] = []) {
        self.answers = answers
    }

    var prompts: [String] { lock.withLock { _prompts } }

    func judge(prompt: String) async throws -> (JudgeResult, JudgeUsage) {
        if fail { throw GptError.http(401) }
        if let e = lock.withLock({ errors.isEmpty ? nil : errors.removeFirst() }) { throw e }
        let r = lock.withLock { () -> JudgeResult in
            _prompts.append(prompt)
            return answers.isEmpty ? JudgeResult(cue: "none", confidence: 0.9, shortReason: "") : answers.removeFirst()
        }
        return (r, JudgeUsage(inputTokens: 500, cachedTokens: 0, outputTokens: 20))
    }
}

/// Polls `condition` until true or timeout (async work hops queues).
func eventually(timeout: TimeInterval = 3, _ condition: () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
    return await condition()
}
