import Foundation

public enum KeyCheckSource: String, Equatable, Sendable {
    /// The stored key, checked when the coach turns on or the app starts with it on.
    case stored
    /// A key typed in Settings.
    case save
}

public enum KeyReadState: String, Equatable, Sendable {
    case present
    /// The Keychain has no key.
    case absent
    /// The Keychain refused or failed (the OSStatus is logged with it): not the same as no key.
    case unreadable
}

/// Where a Keychain read happened.
public enum KeyReadContext: String, Equatable, Sendable {
    /// Loading the stored key when the coach starts or the key is checked.
    case stored
    /// Handing the key to a call's engine.
    case call
}

public enum KeyStoreAction: String, Equatable, Sendable {
    case save
    case remove
}

public enum CaptureMethod: String, Equatable, Sendable {
    case screenCapture
    case processTap
}

extension CaptureStage {
    /// `parentApps`, `helperApps` or `processTap`, for the diagnostics file.
    var name: String {
        switch self {
        case .parentApps: return "parentApps"
        case .helperApps: return "helperApps"
        case .processTap: return "processTap"
        }
    }
}

public enum PermissionKind: String, Equatable, Sendable {
    case microphone
    case screenRecording
}

public enum PermissionState: String, Equatable, Sendable {
    case granted
    /// The user refused it (the OS reports "denied").
    case denied
    /// The OS only says "not granted" and cannot tell denied from never asked (the screen-recording preflight).
    case notGranted
    case notDetermined
    case restricted
}

/// Why a session is held (no capture): by the user's pause or by the call app's own mute.
public enum HoldCause: String, Equatable, Sendable {
    case none
    case user
    case callMuted
}

/// The step of opening the mic that failed.
public enum MicOpenStep: String, Equatable, Sendable {
    case voiceProcessing
    case inputUnit
    case device
    case format
    case engineStart
}

/// A mic open failure that knows its step and OSStatus.
public protocol MicOpenFailure: Error {
    var step: MicOpenStep { get }
    var status: Int? { get }
}

/// The step of starting call-audio capture that failed (a Core Audio process tap).
public enum CaptureStep: String, Equatable, Sendable {
    case createTap
    case tapFormat
    case createAggregate
    case ioProc
    case start
}

/// A failure the code that raised it has already logged, with its step and status: the session does not log it again.
public protocol LoggedFailure: Error {}

/// Why the GPT layer (transcription and the cue judge) is on or off for a call.
public enum GptLayerReason: String, Equatable, Sendable {
    case keyPresent
    /// No key was handed to the engine: none stored, or it could not be read.
    case noKey
    /// A key is stored but OpenAI rejected it, so it is withheld from the engine.
    case keyRejected
    /// The engine was built without network transports (local cues only).
    case noTransports
}

/// Everything the coach diagnostics file can say. Each case carries only counts, flags, enums,
/// OS error codes and `LogToken`s: there is no case, and no initializer, that takes free text, so
/// transcript text, audio, the key, headers and request or response bodies cannot reach the file.
public enum CoachLogEvent: Equatable, Sendable {
    case coachEnabled(Bool)
    /// "Show Coach in Screenshots" turned on or off.
    case screenshotSharing(Bool)
    /// The result of asking OpenAI about the key, with the HTTP status when it answered (a number only).
    case keyCheck(KeyCheck, source: KeyCheckSource, httpStatus: Int?)
    case keyRead(KeyReadState, status: Int?, at: KeyReadContext)
    /// Whether the stored key is withheld from calls (rejected) or let through (unchecked, accepted).
    case keyGate(KeyGateState)
    /// Saving or removing the key in the Keychain; `status` is the OSStatus of a failure.
    case keyStore(KeyStoreAction, ok: Bool, status: Int?)
    case callDetected(bundleId: LogToken?)
    case callEnded(bundleId: LogToken?, reason: CoachStopReason)
    /// `held`: the session starts with capture held (the call app already muted), and `cause` says by what.
    case sessionStarted(reason: CoachStartReason, bundleId: LogToken?, held: Bool, cause: HoldCause)
    case sessionStopped(reason: CoachStopReason)
    case sessionPaused(Bool, cause: HoldCause)
    case micMuted(Bool)
    case micOpened(route: LogToken, source: LogToken, voiceProcessing: Bool, device: LogToken?)
    case micClosed
    case micRouteRestart(count: Int)
    /// Opening the mic failed at `step` with `status` (an OSStatus), when known.
    case micOpenFailed(route: LogToken, source: LogToken, step: MicOpenStep?, status: Int?)
    case micSilent
    case callAudioStarted(stage: CaptureStage, method: CaptureMethod, targets: Int)
    case callAudioFailed(stage: CaptureStage, step: CaptureStep?, domain: LogToken, code: Int)
    /// The app started: its version and build and the macOS version.
    case appStarted(version: LogToken?, build: LogToken?, os: LogToken)
    case callAudioStopped(code: Int)
    /// One call-detection check: which app holds the mic, whether it plays audio, and why a session did
    /// or did not start.
    case detectCheck(DetectionCheck)
    /// What a source delivered over `seconds`: buffers, buffers with sound, and the peak in dBFS (-120 is silence).
    case audioFlow(source: AudioSource, seconds: Int, buffers: Int, voiced: Int, peakDb: Int)
    /// A source with no sound for `seconds`: no buffers at all, or buffers of zeros (which is what a refused
    /// System Audio Recording permission delivers).
    case callAudioSilent(source: AudioSource, seconds: Int, kind: SilenceKind, buffers: Int)
    case callAudioSound(source: AudioSource)
    /// Per-app capture heard nothing while the app's helper processes were audible, so capture moved to `stage`.
    case fallbackEngaged(stage: CaptureStage)
    case permission(PermissionKind, PermissionState)
    /// The socket was opened and the session update sent. The server has not confirmed anything yet: see `transcriberReady`.
    case transcriberOpened(speaker: Speaker, model: LogToken)
    /// The server confirmed the session update, so the session is configured and will transcribe.
    case transcriberReady(speaker: Speaker, model: LogToken)
    case transcriberCounts(speaker: Speaker, counters: TranscriberCounters)
    case transcriberDisconnected(speaker: Speaker)
    case transcriberError(speaker: Speaker?, model: LogToken, httpStatus: Int?, code: LogToken)
    /// The socket under a transcriber failed: the HTTP status of its handshake (when it got one), the
    /// URL error code and the WebSocket close code (-1 when there is none).
    case transcriberTransport(httpStatus: Int?, urlErrorCode: Int?, closeCode: Int)
    /// Caption events the host received over `seconds`: finished segments and partial updates (counts only).
    case captionsReceived(seconds: Int, final: Int, partial: Int)
    /// The captions and saving settings and whether they can run (a usable key and a call in progress).
    case captionsState(captions: Bool, saving: Bool, keyUsable: Bool, inCall: Bool)
    case gptLayer(enabled: Bool, reason: GptLayerReason)
    case gptStopped(reason: GptStopReason)
    case judgeStopped(kind: JudgeFailureKind, httpStatus: Int?)

    /// The event's name and `key=value` fields, one line, no free text.
    public var rendered: String {
        switch self {
        case .coachEnabled(let on): return line("coach.enabled", ("on", .flag(on)))
        case .screenshotSharing(let on): return line("coach.screenshots", ("on", .flag(on)))
        case .keyCheck(let result, let source, let status):
            return line("key.check", ("result", .word(result.rawValue)), ("source", .word(source.rawValue)), ("http", .number(status)))
        case .keyRead(let state, let status, let context):
            return line("key.read", ("result", .word(state.rawValue)), ("status", .number(status)), ("at", .word(context.rawValue)))
        case .keyGate(let state): return line("key.gate", ("state", .word(state.rawValue)))
        case .keyStore(let action, let ok, let status):
            return line("key.store", ("action", .word(action.rawValue)), ("result", .word(ok ? "ok" : "failed")), ("status", .number(status)))
        case .callDetected(let app): return line("call.detected", ("app", .token(app)))
        case .callEnded(let app, let reason): return line("call.ended", ("app", .token(app)), ("reason", .word(reason.rawValue)))
        case .sessionStarted(let reason, let app, let held, let cause):
            let why: String
            switch reason {
            case .audio: why = "audio"
            case .manual: why = "manual"
            }
            return line("session.started", ("reason", .word(why)), ("app", .token(app)), ("held", .flag(held)), ("cause", .word(cause.rawValue)))
        case .sessionStopped(let reason): return line("session.stopped", ("reason", .word(reason.rawValue)))
        case .sessionPaused(let on, let cause): return line("session.paused", ("on", .flag(on)), ("cause", .word(cause.rawValue)))
        case .appStarted(let version, let build, let os):
            return line("app.started", ("version", .token(version)), ("build", .token(build)), ("os", .token(os)))
        case .micMuted(let on): return line("mic.muted", ("on", .flag(on)))
        case .micOpened(let route, let source, let vp, let device):
            return line("mic.opened", ("route", .token(route)), ("source", .token(source)), ("voiceProcessing", .flag(vp)), ("device", .token(device)))
        case .micClosed: return line("mic.closed")
        case .micRouteRestart(let count): return line("mic.routeRestart", ("count", .number(count)))
        case .micOpenFailed(let route, let source, let step, let status):
            return line("mic.openFailed", ("route", .token(route)), ("source", .token(source)), ("step", .word(step?.rawValue ?? "unknown")),
                        ("status", .number(status)))
        case .micSilent: return line("mic.silent")
        case .callAudioStarted(let stage, let method, let targets):
            return line("callAudio.started", ("stage", .word(stage.name)), ("method", .word(method.rawValue)), ("targets", .number(targets)))
        case .callAudioFailed(let stage, let step, let domain, let code):
            return line("callAudio.failed", ("stage", .word(stage.name)), ("step", .word(step?.rawValue ?? "unknown")), ("domain", .token(domain)),
                        ("code", .number(code)))
        case .callAudioStopped(let code): return line("callAudio.stopped", ("code", .number(code)))
        case .detectCheck(let c):
            return line("detect.check", ("micApp", .word(c.micApp?.value ?? "none")), ("callAudio", .flag(c.callAudio)),
                        ("result", .word(c.result.rawValue)), ("reason", .word(c.reason.rawValue)), ("timerS", .number(c.timerSeconds)),
                        ("perm", .word(c.permission.rawValue)))
        case .audioFlow(let source, let seconds, let buffers, let voiced, let peak):
            return line("audio.flow", ("source", .word(source.rawValue)), ("seconds", .number(seconds)), ("buffers", .number(buffers)),
                        ("voiced", .number(voiced)), ("peakDb", .number(peak)))
        case .callAudioSilent(let source, let seconds, let kind, let buffers):
            return line("callAudio.silent", ("source", .word(source.rawValue)), ("seconds", .number(seconds)), ("kind", .word(kind.rawValue)),
                        ("buffers", .number(buffers)))
        case .callAudioSound(let source): return line("callAudio.sound", ("source", .word(source.rawValue)))
        case .fallbackEngaged(let stage): return line("callAudio.fallbackEngaged", ("stage", .word(stage.name)))
        case .permission(let kind, let state): return line("permission", ("kind", .word(kind.rawValue)), ("state", .word(state.rawValue)))
        case .transcriberOpened(let speaker, let model):
            return line("transcriber.opened", ("speaker", .word(Self.name(speaker))), ("model", .token(model)))
        case .transcriberReady(let speaker, let model):
            return line("transcriber.ready", ("speaker", .word(Self.name(speaker))), ("model", .token(model)))
        case .transcriberCounts(let speaker, let c):
            return line("transcriber.counts", ("speaker", .word(Self.name(speaker))), ("appends", .number(c.appends)), ("commits", .number(c.commits)),
                        ("acks", .number(c.acks)), ("completions", .number(c.completions)), ("empty", .number(c.emptyCompletions)))
        case .transcriberDisconnected(let speaker): return line("transcriber.disconnected", ("speaker", .word(Self.name(speaker))))
        case .transcriberError(let speaker, let model, let status, let code):
            return line("transcriber.error", ("speaker", .word(speaker.map(Self.name) ?? "unknown")), ("model", .token(model)),
                        ("http", .number(status)), ("code", .token(code)))
        case .transcriberTransport(let status, let url, let close):
            return line("transcriber.transport", ("http", .number(status)), ("urlError", .number(url)), ("close", .number(close)))
        case .captionsReceived(let seconds, let final, let partial):
            return line("captions.received", ("seconds", .number(seconds)), ("final", .number(final)), ("partial", .number(partial)))
        case .captionsState(let captions, let saving, let keyUsable, let inCall):
            return line("captions.state", ("captions", .flag(captions)), ("saving", .flag(saving)), ("keyUsable", .flag(keyUsable)),
                        ("inCall", .flag(inCall)))
        case .gptLayer(let on, let reason): return line("gpt.layer", ("enabled", .flag(on)), ("reason", .word(reason.rawValue)))
        case .gptStopped(let reason): return line("gpt.stopped", ("reason", .word(reason.rawValue)))
        case .judgeStopped(let kind, let status): return line("judge.stopped", ("kind", .word(kind.rawValue)), ("http", .number(status)))
        }
    }

    private static func name(_ s: Speaker) -> String {
        switch s {
        case .me: return "me"
        case .others: return "others"
        }
    }

    private enum Field {
        case flag(Bool)
        case number(Int?)
        case token(LogToken?)
        case word(String)
    }

    private func line(_ name: String, _ fields: (String, Field)...) -> String {
        var out = name
        for (key, field) in fields {
            switch field {
            case .flag(let b): out += " \(key)=\(b)"
            case .number(let n): if let n { out += " \(key)=\(n)" }
            case .token(let t): if let t { out += " \(key)=\(t.value)" }
            case .word(let w): out += " \(key)=\(LogToken.serverCode(w).value)"
            }
        }
        return out
    }
}

/// One line of the diagnostics file: a time and an event.
public struct CoachLogEntry: Equatable, Sendable {
    public let date: Date
    public let event: CoachLogEvent

    public init(date: Date, event: CoachLogEvent) {
        self.date = date
        self.event = event
    }

    /// `2026-01-31T09:05:00.123Z name key=value ...`, UTC.
    public var line: String { "\(Self.stamp(date)) \(event.rendered)" }

    public static func stamp(_ date: Date) -> String {
        let ms = Int((date.timeIntervalSince1970 * 1000).rounded(.down))
        let secs = Date(timeIntervalSince1970: Double(ms / 1000))
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let c = cal.dateComponents([.year, .month, .day, .hour, .minute, .second], from: secs)
        return String(format: "%04d-%02d-%02dT%02d:%02d:%02d.%03dZ", c.year!, c.month!, c.day!, c.hour!, c.minute!, c.second!, ms % 1000)
    }

    /// The time at the start of a line, or nil for a line that doesn't begin with one.
    public static func date(ofLine line: Substring) -> Date? {
        guard line.count >= 24 else { return nil }
        let s = String(line.prefix(24))
        let parts = s.split(whereSeparator: { "-T:.Z".contains($0) }).compactMap { Int($0) }
        guard parts.count == 7, s.hasSuffix("Z") else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        guard let base = cal.date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2],
                                                       hour: parts[3], minute: parts[4], second: parts[5])) else { return nil }
        return base.addingTimeInterval(Double(parts[6]) / 1000)
    }
}

/// An error that carries a numeric status (an OSStatus) and nothing else worth logging.
public protocol StatusCarryingError: Error {
    var statusCode: Int { get }
}

public protocol CoachLogSink: AnyObject, Sendable {
    func write(_ entry: CoachLogEntry)
}

/// The coach's diagnostics, local only. Nothing is written until a host installs a sink; the
/// only way in is a typed `CoachLogEvent`.
public enum CoachLog {
    private static let lock = NSLock()
    private static var sink: CoachLogSink?

    public static func install(_ sink: CoachLogSink?) {
        lock.withLock { Self.sink = sink }
    }

    public static func record(_ event: CoachLogEvent, at date: Date = Date()) {
        let target = lock.withLock { sink }
        target?.write(CoachLogEntry(date: date, event: event))
    }

    /// The HTTP status and a short code for an error from the GPT layer, with no message text:
    /// a status from `GptError.http`, `URLError<code>`, or the error's domain and code.
    public static func describe(_ error: Error) -> (httpStatus: Int?, code: LogToken) {
        if let g = error as? GptError {
            switch g {
            case .http(let status): return (status, LogToken.constant("http"))
            case .badResponse: return (nil, LogToken.constant("badResponse"))
            case .notConnected: return (nil, LogToken.constant("notConnected"))
            case .budgetExhausted: return (nil, LogToken.constant("budgetExhausted"))
            // The 401 was the first host's; this error is about the retry on the regional host, so no status is claimed.
            case .hostRejected: return (nil, LogToken.constant("hostRejected"))
            }
        }
        if let u = error as? URLError { return (nil, LogToken.serverCode("URLError\(u.code.rawValue)")) }
        let ns = error as NSError
        return (nil, LogToken.serverCode("\(ns.domain):\(ns.code)"))
    }

    /// The OSStatus or code an error carries, without any message text: a `StatusCarryingError`'s status,
    /// or the code of an `NSOSStatusErrorDomain` error.
    public static func status(of error: Error) -> Int? {
        if let e = error as? StatusCarryingError { return e.statusCode }
        let ns = error as NSError
        return ns.domain == NSOSStatusErrorDomain ? ns.code : nil
    }

    /// The error's domain and code, for failures with no HTTP side (capture start).
    public static func domainAndCode(_ error: Error) -> (domain: LogToken, code: Int) {
        let ns = error as NSError
        return (LogToken.errorDomain(ns.domain), ns.code)
    }
}
