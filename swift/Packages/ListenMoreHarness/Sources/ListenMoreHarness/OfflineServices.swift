import Foundation
import ListenMoreCore

/// Offline stand-in for OpenAI realtime transcription, at the wire level `LiveTranscriber` speaks:
/// `session.update`, `input_audio_buffer.append` / `commit` / `clear` in; `committed`, word deltas,
/// `completed` (with a duration usage) and `cleared` out. A commit is answered with the scripted text
/// of the lines whose audio this socket actually received since the last commit, so a line spoken
/// while muted or paused, or cleared by Mute, is never transcribed. Nothing is stored or logged.
public final class ScriptedRealtime: WebSocketConnector, @unchecked Sendable {
    public struct Append: Sendable {
        public var t: Double
        public var stream: AudioStream
        public var samples: Int
        public var loud: Bool
    }

    struct ScriptLine {
        let id: String
        let stream: AudioStream
        let text: String
        let start: Double
        let end: Double
    }

    private let lock = NSLock()
    private let clock: HarnessClock
    private let sampleRate: Int
    private var lines: [ScriptLine] = []
    private var tracks: Tracks?
    private var origin = 0.0
    private var heard: Set<String> = []
    private var emitted: Set<String> = []
    private var pendingSeconds: [AudioStream: Double] = [:]
    private var items = 0
    private var _connections = 0
    private var _closes = 0
    private var _appends: [Append] = []
    private var _commits: [(t: Double, stream: AudioStream)] = []
    private var _clears: [(t: Double, stream: AudioStream)] = []
    private var _routingMismatches = 0
    private var _sendsAfterClose = 0
    private var _authorizedConnects = 0
    private var _segments: [TranscribedSegment] = []
    /// Final transcripts sent (the runner waits until the session has delivered as many captions).
    public let finalsSent = AsyncCounter()
    private var dropsRemaining = 0

    public init(clock: HarnessClock, sampleRate: Int) {
        self.clock = clock
        self.sampleRate = sampleRate
    }

    /// Test hook: the next `n` final transcripts are counted as sent but never delivered, as when the GPT
    /// layer drops a final (text from a muted You, or after the layer is disabled).
    func dropNextFinals(_ n: Int) { lock.withLock { dropsRemaining = n } }

    func shouldDeliverFinal() -> Bool {
        lock.withLock {
            guard dropsRemaining > 0 else { return true }
            dropsRemaining -= 1
            return false
        }
    }

    /// The script and the device tracks, with the run time at which scenario time 0 starts.
    public func load(timeline: Timeline, tracks: Tracks, origin: Double) {
        lock.withLock {
            lines = timeline.lines.map {
                ScriptLine(id: $0.line.id, stream: $0.line.voice.stream, text: $0.line.text, start: $0.start, end: $0.end)
            }
            self.tracks = tracks
            self.origin = origin
        }
    }

    public var connections: Int { lock.withLock { _connections } }
    public var closes: Int { lock.withLock { _closes } }
    public var appends: [Append] { lock.withLock { _appends } }
    public var commits: [(t: Double, stream: AudioStream)] { lock.withLock { _commits } }
    public var clears: [(t: Double, stream: AudioStream)] { lock.withLock { _clears } }
    public var routingMismatches: Int { lock.withLock { _routingMismatches } }
    public var sendsAfterClose: Int { lock.withLock { _sendsAfterClose } }
    public var authorizedConnects: Int { lock.withLock { _authorizedConnects } }
    public var segments: [TranscribedSegment] { lock.withLock { _segments } }

    /// `GptLayer` connects the ME transcriber, then OTHERS, on every engine start.
    public func connect(url: URL, headers: [String: String]) async throws -> WebSocketConnection {
        let stream: AudioStream = lock.withLock {
            defer { _connections += 1 }
            if headers["Authorization"]?.hasPrefix("Bearer ") == true { _authorizedConnects += 1 }
            return _connections % 2 == 0 ? .mic : .call
        }
        return ScriptedSocket(server: self, stream: stream)
    }

    private var scenarioNow: Double { clock.now() - lock.withLock { origin } }

    func onAppend(_ stream: AudioStream, pcm: Data) {
        let t = scenarioNow
        let samples = pcm.count / 2
        let loud = Self.loud(pcm)
        lock.withLock {
            pendingSeconds[stream, default: 0] += Double(samples) / Double(sampleRate)
            for l in lines where l.stream == stream && !emitted.contains(l.id) && t >= l.start - 0.4 && t <= l.end + 0.45 {
                heard.insert(l.id)
            }
            if loud, let tracks {
                let other: AudioStream = stream == .mic ? .call : .mic
                let mine = stride(from: t - 0.5, through: t + 0.05, by: 0.02).contains { tracks.voiced(stream, at: $0) }
                if !mine && tracks.voiced(other, at: t) { _routingMismatches += 1 }
            }
            _appends.append(Append(t: t, stream: stream, samples: samples, loud: loud))
        }
    }

    /// The scripted text for a commit, its item id and the audio seconds billed.
    func onCommit(_ stream: AudioStream) -> (item: String, text: String, seconds: Double) {
        let t = scenarioNow
        return lock.withLock {
            let due = lines.filter { $0.stream == stream && heard.contains($0.id) && !emitted.contains($0.id) }
            for l in due { emitted.insert(l.id) }
            items += 1
            let seconds = (pendingSeconds[stream] ?? 0).rounded(.up)
            pendingSeconds[stream] = 0
            _commits.append((t, stream))
            let text = due.map(\.text).joined(separator: " ")
            _segments.append(TranscribedSegment(stream: stream, committedAt: t, transcribedAt: t, text: text))
            return ("item_\(items)", text, seconds)
        }
    }

    func onClear(_ stream: AudioStream) {
        let t = scenarioNow
        lock.withLock {
            heard = heard.filter { id in !(lines.contains { $0.id == id && $0.stream == stream } && !emitted.contains(id)) }
            pendingSeconds[stream] = 0
            _clears.append((t, stream))
        }
    }

    func onClose() { lock.withLock { _closes += 1 } }
    func onSendAfterClose() { lock.withLock { _sendsAfterClose += 1 } }

    static func loud(_ pcm: Data) -> Bool {
        guard pcm.count >= 2 else { return false }
        var sum = 0.0
        pcm.withUnsafeBytes { raw in
            for s in raw.bindMemory(to: Int16.self) {
                let v = Double(Int16(littleEndian: s)) / 32768
                sum += v * v
            }
        }
        let rms = (sum / Double(pcm.count / 2)).squareRoot()
        return 20 * log10(max(rms, 1e-9)) > -45
    }
}

final class ScriptedSocket: WebSocketConnection, @unchecked Sendable {
    private let server: ScriptedRealtime
    private let stream: AudioStream
    private let lock = NSLock()
    private var inbox: [String] = []
    private var waiters: [CheckedContinuation<String, Error>] = []
    private var closed = false

    init(server: ScriptedRealtime, stream: AudioStream) {
        self.server = server
        self.stream = stream
    }

    func send(_ text: String) async throws {
        if lock.withLock({ closed }) {
            server.onSendAfterClose()
            throw GptError.notConnected
        }
        guard let data = text.data(using: .utf8),
              let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        switch msg["type"] as? String ?? "" {
        case "input_audio_buffer.append":
            server.onAppend(stream, pcm: Data(base64Encoded: msg["audio"] as? String ?? "") ?? Data())
        case "input_audio_buffer.commit":
            let (item, said, seconds) = server.onCommit(stream)
            push(["type": "input_audio_buffer.committed", "item_id": item])
            for word in said.split(separator: " ") {
                push(["type": "conversation.item.input_audio_transcription.delta", "item_id": item, "delta": word + " "])
            }
            if server.shouldDeliverFinal() {
                push(["type": "conversation.item.input_audio_transcription.completed", "item_id": item, "transcript": said,
                      "usage": ["type": "duration", "seconds": seconds]])
            }
            server.finalsSent.add()
        case "input_audio_buffer.clear":
            server.onClear(stream)
            push(["type": "input_audio_buffer.cleared"])
        default:
            break
        }
    }

    func receive() async throws -> String {
        try await withCheckedThrowingContinuation { c in
            lock.lock()
            if !inbox.isEmpty {
                let m = inbox.removeFirst()
                lock.unlock()
                c.resume(returning: m)
            } else if closed {
                lock.unlock()
                c.resume(throwing: GptError.notConnected)
            } else {
                waiters.append(c)
                lock.unlock()
            }
        }
    }

    func close() {
        let ws = lock.withLock { () -> [CheckedContinuation<String, Error>] in
            guard !closed else { return [] }
            closed = true
            defer { waiters.removeAll() }
            return waiters
        }
        server.onClose()
        ws.forEach { $0.resume(throwing: GptError.notConnected) }
    }

    private func push(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object), let s = String(data: data, encoding: .utf8) else { return }
        lock.lock()
        if let w = waiters.first {
            waiters.removeFirst()
            lock.unlock()
            w.resume(returning: s)
        } else {
            inbox.append(s)
            lock.unlock()
        }
    }
}

/// Offline judge endpoint: every Responses call answers `none` (no not_listening cue), with token usage;
/// with `notListeningOn`, a request whose transcript has that text gets `not_listening`.
public final class StubJudgeHTTP: HTTPTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var _calls = 0
    private let notListeningOn: String?

    public init(notListeningOn: String? = nil) {
        self.notListeningOn = notListeningOn
    }

    public var calls: Int { lock.withLock { _calls } }

    public func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval) async throws -> (status: Int, body: Data) {
        lock.withLock { _calls += 1 }
        let flagged = notListeningOn.map { String(decoding: body, as: UTF8.self).contains($0) } ?? false
        let inner = flagged ? #"{"cue":"not_listening","confidence":0.9,"short_reason":"stub"}"#
                            : #"{"cue":"none","confidence":0.9,"short_reason":"stub"}"#
        let reply: [String: Any] = [
            "output": [["type": "message", "content": [["type": "output_text", "text": inner]]]],
            "usage": ["input_tokens": 400, "input_tokens_details": ["cached_tokens": 0], "output_tokens": 20],
        ]
        return (200, try JSONSerialization.data(withJSONObject: reply))
    }
}

/// No real waiting offline: the judge's rate-limit sleeps return at once.
public struct InstantScheduler: GptScheduler {
    let clock: HarnessClock

    public init(clock: HarnessClock) {
        self.clock = clock
    }

    public func monotonic() -> TimeInterval { clock.now() }
    public func sleep(seconds: Double) async throws { await Task.yield() }
}
