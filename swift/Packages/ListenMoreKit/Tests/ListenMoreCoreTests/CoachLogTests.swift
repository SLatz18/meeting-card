import XCTest
@testable import ListenMoreCore

/// Collects what the coach logs, in memory.
final class CaptureSink: CoachLogSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _entries: [CoachLogEntry] = []
    var entries: [CoachLogEntry] { lock.withLock { _entries } }
    var lines: [String] { entries.map(\.event.rendered) }
    func write(_ entry: CoachLogEntry) { lock.withLock { _entries.append(entry) } }
}

/// The coach diagnostics: what an event can say, the redaction of its labels, and the file's size,
/// age and access limits.
final class CoachLogTests: XCTestCase {
    override func tearDown() {
        CoachLog.install(nil)
    }

    static let linePattern = #"^[A-Za-z.]+( [A-Za-z]+=[A-Za-z0-9._:/()+-]+)*$"#

    /// One of every event, with awkward labels: every rendering is a name and `key=value` tokens.
    static func everyEvent() -> [CoachLogEvent] {
        let hostile = LogToken("User's Headset Pro: \"hello, this is my transcript\"")
        let app = LogToken("us.zoom.xos")
        return [
            .coachEnabled(true), .coachEnabled(false),
            .keyCheck(.ok, source: .stored, httpStatus: 200), .keyCheck(.rejected, source: .save, httpStatus: 401),
            .keyCheck(.unreachable, source: .save, httpStatus: nil), .keyCheck(.empty, source: .stored, httpStatus: nil),
            .keyRead(.present, status: nil, at: .call), .keyRead(.absent, status: nil, at: .stored),
            .keyRead(.unreadable, status: -25308, at: .stored),
            .keyGate(.unchecked), .keyGate(.accepted), .keyGate(.rejected),
            .keyStore(.save, ok: true, status: nil), .keyStore(.remove, ok: false, status: -25244),
            .callDetected(bundleId: app), .callDetected(bundleId: nil),
            .callEnded(bundleId: app, reason: .audioEnded), .callEnded(bundleId: nil, reason: .manual),
            .sessionStarted(reason: .audio, bundleId: app), .sessionStarted(reason: .manual, bundleId: nil),
            .sessionStopped(reason: .callEnded), .sessionPaused(true), .micMuted(true),
            .micOpened(route: LogToken("speakers"), source: LogToken("builtIn"), voiceProcessing: true, device: hostile),
            .micOpened(route: LogToken("bluetooth"), source: LogToken("builtIn"), voiceProcessing: false, device: nil),
            .micClosed, .micRouteRestart(count: 2), .micOpenFailed(route: LogToken("speakers"), source: LogToken("builtIn")), .micSilent,
            .callAudioStarted(stage: .parentApps, method: .screenCapture, targets: 1),
            .callAudioStarted(stage: .processTap, method: .processTap, targets: 3),
            .callAudioFailed(stage: .helperApps, domain: LogToken("com.apple.ScreenCaptureKit.SCStreamErrorDomain"), code: -3801),
            .callAudioFailed(stage: .processTap, domain: LogToken("OSStatus"), code: -50),
            .callAudioStopped(code: -3805),
            .audioFlow(source: .call, seconds: 10, buffers: 480, voiced: 120, peakDb: -31), .audioFlow(source: .mic, seconds: 10, buffers: 0, voiced: 0, peakDb: -120),
            .callAudioSilent(source: .call, seconds: 15, kind: .digitalSilence, buffers: 750), .callAudioSilent(source: .call, seconds: 15, kind: .noBuffers, buffers: 0),
            .callAudioSound(source: .call), .fallbackEngaged(stage: .helperApps),
            .detectCheck(DetectionCheck(micApp: app, callAudio: true, result: .notMet, reason: .startTimer, timerSeconds: 1, permission: .granted)),
            .detectCheck(DetectionCheck(micApp: nil, callAudio: false, result: .notMet, reason: .inputDeviceIdle)),
            .detectCheck(DetectionCheck(micApp: hostile, callAudio: false, result: .notMet, reason: .appNotAllowed, permission: .notGranted)),
            .permission(.microphone, .granted), .permission(.screenRecording, .denied),
            .transcriberConnected(speaker: .me, model: LogToken("gpt-live-transcribe")),
            .transcriberDisconnected(speaker: .others),
            .transcriberError(speaker: .others, model: LogToken("gpt-live-transcribe"), httpStatus: 401, code: LogToken("invalid_request_error/bad_key")),
            .transcriberError(speaker: nil, model: LogToken("gpt-live-transcribe"), httpStatus: nil, code: LogToken("URLError-1011")),
            .transcriberTransport(httpStatus: 403, urlErrorCode: -1011, closeCode: -1),
            .transcriberTransport(httpStatus: nil, urlErrorCode: nil, closeCode: 1006),
            .captionSegments(me: 3, others: 12),
            .gptLayer(enabled: true, reason: .keyPresent), .gptLayer(enabled: false, reason: .noKey), .gptLayer(enabled: false, reason: .keyRejected),
            .gptLayer(enabled: false, reason: .noTransports),
            .gptStopped(reason: .error), .gptStopped(reason: .budgetCap),
            .judgeStopped(kind: .auth, httpStatus: 401), .judgeStopped(kind: .timeout, httpStatus: nil),
        ]
    }

    func testEveryEventRendersAsANameAndKeyValueTokens() {
        for event in Self.everyEvent() {
            let line = event.rendered
            XCTAssertNotNil(line.range(of: Self.linePattern, options: .regularExpression), line)
            XCTAssertFalse(line.contains("\n"))
        }
    }

    func testRenderedFields() {
        XCTAssertEqual(CoachLogEvent.coachEnabled(true).rendered, "coach.enabled on=true")
        XCTAssertEqual(CoachLogEvent.keyCheck(.rejected, source: .save, httpStatus: 401).rendered, "key.check result=rejected source=save http=401")
        XCTAssertEqual(CoachLogEvent.keyCheck(.unreachable, source: .stored, httpStatus: nil).rendered, "key.check result=unreachable source=stored")
        XCTAssertEqual(CoachLogEvent.keyRead(.unreadable, status: -25308, at: .stored).rendered, "key.read result=unreadable status=-25308 at=stored")
        XCTAssertEqual(CoachLogEvent.keyRead(.absent, status: nil, at: .call).rendered, "key.read result=absent at=call", "no key is not a failure")
        XCTAssertEqual(CoachLogEvent.keyGate(.rejected).rendered, "key.gate state=rejected")
        XCTAssertEqual(CoachLogEvent.keyStore(.save, ok: false, status: -25244).rendered, "key.store action=save result=failed status=-25244")
        XCTAssertEqual(CoachLogEvent.gptLayer(enabled: false, reason: .keyRejected).rendered, "gpt.layer enabled=false reason=keyRejected")
        XCTAssertEqual(CoachLogEvent.callAudioFailed(stage: .processTap, domain: LogToken("OSStatus"), code: -50).rendered,
                       "callAudio.failed stage=processTap domain=OSStatus code=-50")
        XCTAssertEqual(CoachLogEvent.transcriberError(speaker: .others, model: LogToken("gpt-live-transcribe"), httpStatus: 401,
                                                      code: LogToken("invalid_api_key")).rendered,
                       "transcriber.error speaker=others model=gpt-live-transcribe http=401 code=invalid_api_key")
        XCTAssertEqual(CoachLogEvent.audioFlow(source: .call, seconds: 10, buffers: 480, voiced: 120, peakDb: -31).rendered,
                       "audio.flow source=call seconds=10 buffers=480 voiced=120 peakDb=-31")
        XCTAssertEqual(CoachLogEvent.callAudioSilent(source: .call, seconds: 15, kind: .digitalSilence, buffers: 750).rendered,
                       "callAudio.silent source=call seconds=15 kind=digitalSilence buffers=750")
        XCTAssertEqual(CoachLogEvent.fallbackEngaged(stage: .processTap).rendered, "callAudio.fallbackEngaged stage=processTap")
        XCTAssertEqual(CoachLogEvent.captionSegments(me: 1, others: 0).rendered, "captions.segments me=1 others=0")
        XCTAssertEqual(CoachLogEvent.sessionStarted(reason: .audio, bundleId: LogToken("us.zoom.xos")).rendered,
                       "session.started reason=audio app=us.zoom.xos")
        XCTAssertEqual(CoachLogEvent.callDetected(bundleId: nil).rendered, "call.detected", "no app, no field")
    }

    // MARK: redaction

    func testLabelsKeepOnlyPlainCharactersAndALimitedLength() {
        XCTAssertEqual(LogToken("MacBook Pro Microphone").value, "MacBook_Pro_Microphone")
        XCTAssertEqual(LogToken("User's Headset").value, "User_s_Headset")
        XCTAssertEqual(LogToken("us.zoom.xos").value, "us.zoom.xos")
        XCTAssertEqual(LogToken("  \n ").value, "none")
        XCTAssertEqual(LogToken("").value, "none")
        XCTAssertEqual(LogToken("a,b;c=d\"e\n f").value, "a_b_c_d_e_f", "no separator, quote or newline survives")
        XCTAssertEqual(LogToken(String(repeating: "ab.", count: 100)).value.count, LogToken.maxLength)
        XCTAssertNil(LogToken(nil as String?))
    }

    /// Anything shaped like a key, a header or one long unbroken secret is replaced, wherever it sits.
    func testKeyShapedLabelsAreRedacted() {
        for raw in ["sk-test-not-real", "device sk-abc", "SK-UPPER", "Bearer abc", "Authorization: Bearer x",
                    String(repeating: "A1b2", count: 12), "prefix." + String(repeating: "x", count: 40)] {
            XCTAssertEqual(LogToken(raw).value, "redacted", raw)
        }
        XCTAssertEqual(LogToken("gpt-live-transcribe").value, "gpt-live-transcribe")
    }

    /// A sentence of transcript passed as a label keeps no spaces or punctuation, and is cut short.
    func testASentenceCannotPassForALabel() {
        let sentence = "Can you send me the budget numbers before Friday, please? I think the plan is fine."
        let token = LogToken(sentence).value
        XCTAssertFalse(token.contains(" "))
        XCTAssertFalse(token.contains(","))
        XCTAssertFalse(token.contains("?"))
        XCTAssertLessThanOrEqual(token.count, LogToken.maxLength)
    }

    func testNoRenderedEventCarriesAKeyOrHeader() {
        for event in Self.everyEvent() {
            let line = event.rendered.lowercased()
            for banned in ["sk-", "bearer", "authorization", "api_key="] {
                XCTAssertFalse(line.contains(banned), line)
            }
        }
    }

    /// The API takes events, and an event's payload types are counts, flags, enums, codes and labels: no
    /// `String`, `Data`, `Any`, array or dictionary, so free text, audio and bodies have no way in.
    func testEventPayloadsAreTypedNotText() throws {
        let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent("Sources/ListenMoreCore/CoachLog.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let start = try XCTUnwrap(source.range(of: "public enum CoachLogEvent"))
        let end = try XCTUnwrap(source.range(of: "    /// The event's name and `key=value` fields"))
        let declaration = String(source[start.upperBound..<end.lowerBound])
        let cases = declaration.components(separatedBy: "\n").filter { $0.trimmingCharacters(in: .whitespaces).hasPrefix("case ") }
        XCTAssertGreaterThanOrEqual(cases.count, 25)
        for line in cases {
            for banned in ["String", "Data", "Any", "[", ": Error", "URL?"] {
                XCTAssertFalse(line.contains(banned), "\(line) takes \(banned)")
            }
        }
        for sink in ["func record(", "func write("] {
            XCTAssertFalse(source.contains("\(sink)_ text") || source.contains("\(sink)_ message") || source.contains("\(sink)_ line: String"), sink)
        }
    }

    // MARK: facade

    func testRecordGoesToTheInstalledSinkOnly() {
        CoachLog.record(.coachEnabled(true))
        let sink = CaptureSink()
        CoachLog.install(sink)
        let when = Date(timeIntervalSince1970: 1_700_000_000.123)
        CoachLog.record(.coachEnabled(false), at: when)
        XCTAssertEqual(sink.lines, ["coach.enabled on=false"])
        XCTAssertEqual(sink.entries.first?.date, when)
        CoachLog.install(nil)
        CoachLog.record(.coachEnabled(true))
        XCTAssertEqual(sink.lines.count, 1)
    }

    /// The GPT layer's reason tells a rejected key from a missing one.
    func testEngineSaysWhyTheGptLayerIsOff() throws {
        let sink = CaptureSink()
        CoachLog.install(sink)
        defer { CoachLog.install(nil) }
        let config = try TestConfig.load()
        let engine = LocalCoachEngine(transports: .none)
        engine.start(config: config, apiKey: nil, keyAvailability: .rejected)
        engine.start(config: config, apiKey: nil, keyAvailability: .absent)
        engine.start(config: config, apiKey: nil)
        engine.stop()
        XCTAssertEqual(sink.lines, ["gpt.layer enabled=false reason=keyRejected", "gpt.layer enabled=false reason=noKey",
                                    "gpt.layer enabled=false reason=noKey"])
    }

    func testDescribeErrorsWithoutMessageText() {
        struct Leaky: Error, CustomStringConvertible { var description: String { "Bearer sk-leak" } }
        XCTAssertEqual(CoachLog.describe(GptError.http(401)).httpStatus, 401)
        XCTAssertEqual(CoachLog.describe(GptError.http(401)).code.value, "http")
        XCTAssertEqual(CoachLog.describe(URLError(.timedOut)).code.value, "URLError-1001")
        XCTAssertNil(CoachLog.describe(URLError(.timedOut)).httpStatus)
        let other = CoachLog.describe(Leaky())
        XCTAssertFalse(other.code.value.contains("sk-"))
        XCTAssertFalse(other.code.value.lowercased().contains("bearer"))
        XCTAssertEqual(CoachLog.domainAndCode(NSError(domain: "com.apple.ScreenCaptureKit.SCStreamErrorDomain", code: -3801)).code, -3801)
    }

    // MARK: lines and times

    func testTimestampFormatAndParse() throws {
        let date = Date(timeIntervalSince1970: 1_700_000_000.123)
        let line = CoachLogEntry(date: date, event: .micClosed).line
        XCTAssertEqual(line, "2023-11-14T22:13:20.123Z mic.closed")
        let parsed = try XCTUnwrap(CoachLogEntry.date(ofLine: Substring(line)))
        XCTAssertEqual(parsed.timeIntervalSince1970, date.timeIntervalSince1970, accuracy: 0.001)
        XCTAssertNil(CoachLogEntry.date(ofLine: "not a log line at all, no time here"))
    }

    // MARK: file

    func tempFile() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lm-coachlog-\(UUID().uuidString)", isDirectory: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("App-Coach.log")
    }

    func files(beside url: URL) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: url.deletingLastPathComponent().path)) ?? []).sorted()
    }

    func testFileTakesEntriesAndKeepsOnlyTheirLines() throws {
        let url = try tempFile()
        let now = Date()
        let file = CoachLogFile(url: url, now: { now })
        file.write(CoachLogEntry(date: now, event: .coachEnabled(true)))
        file.write(CoachLogEntry(date: now, event: .keyCheck(.ok, source: .stored, httpStatus: 200)))
        let lines = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { String($0.dropFirst(25)) }
        XCTAssertEqual(lines, ["coach.enabled on=true", "key.check result=ok source=stored http=200"])
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600, "readable by the user only")
    }

    /// The cap: the file never passes `maxBytes`, one older file is kept, the one before it goes.
    func testSizeCapRotatesToOneOldFile() throws {
        let url = try tempFile()
        let now = Date()
        let file = CoachLogFile(url: url, maxBytes: 1000, now: { now })
        for i in 0..<200 { file.write(CoachLogEntry(date: now, event: .micRouteRestart(count: i))) }
        XCTAssertEqual(files(beside: url), ["App-Coach.log", "App-Coach.log.1"], "two files at most")
        let current = try Data(contentsOf: url).count
        let old = try Data(contentsOf: file.rotatedURL).count
        XCTAssertLessThanOrEqual(current, 1000)
        XCTAssertLessThanOrEqual(old, 1000)
        let newest = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").last.map(String.init)
        XCTAssertEqual(newest.map { String($0.dropFirst(25)) }, "mic.routeRestart count=199", "the newest line is in the current file")
    }

    func testOneMegabyteIsTheDefaultCap() {
        XCTAssertEqual(CoachLogFile.defaultMaxBytes, 1_000_000)
        XCTAssertEqual(CoachLogFile.defaultMaxAge, 3 * 24 * 3600)
    }

    /// Entries older than the limit are removed from both files, and an old file with nothing recent goes.
    func testOldEntriesAreRemoved() throws {
        let url = try tempFile()
        let day: TimeInterval = 24 * 3600
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = ClockBox(t0)
        let file = CoachLogFile(url: url, maxBytes: 100_000, maxAge: 3 * day, now: { clock.now })
        file.write(CoachLogEntry(date: t0, event: .coachEnabled(true)))
        file.write(CoachLogEntry(date: t0.addingTimeInterval(2 * day), event: .coachEnabled(false)))
        clock.now = t0.addingTimeInterval(2 * day + 7200)
        file.write(CoachLogEntry(date: clock.now, event: .micClosed))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count, 3, "nothing is old enough yet")

        clock.now = t0.addingTimeInterval(3 * day + 7200)
        file.write(CoachLogEntry(date: clock.now, event: .micSilent))
        let kept = try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map { String($0.dropFirst(25)) }
        XCTAssertEqual(kept, ["coach.enabled on=false", "mic.closed", "mic.silent"], "the line from three days ago is gone")

        clock.now = t0.addingTimeInterval(10 * day)
        file.prune()
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path), "a file with nothing recent is deleted")
    }

    func testPruneRunsAtMostOncePerInterval() throws {
        let url = try tempFile()
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = ClockBox(t0)
        let file = CoachLogFile(url: url, maxAge: 100, now: { clock.now })
        file.write(CoachLogEntry(date: t0, event: .coachEnabled(true)))
        clock.now = t0.addingTimeInterval(200)
        file.write(CoachLogEntry(date: clock.now, event: .coachEnabled(false)))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count, 2, "less than an hour since the last prune")
        clock.now = t0.addingTimeInterval(CoachLogFile.pruneInterval + 1)
        file.write(CoachLogEntry(date: clock.now, event: .micClosed))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8).split(separator: "\n").count, 1)
    }

    func testRevealTarget() {
        let file = URL(fileURLWithPath: "/tmp/Logs/App-Coach.log")
        XCTAssertEqual(CoachLogFile.revealTarget(fileExists: true, file: file), file)
        XCTAssertEqual(CoachLogFile.revealTarget(fileExists: false, file: file).path, "/tmp/Logs")
    }
}

final class ClockBox: @unchecked Sendable {
    private let lock = NSLock()
    private var _now: Date
    init(_ d: Date) { _now = d }
    var now: Date {
        get { lock.withLock { _now } }
        set { lock.withLock { _now = newValue } }
    }
}
