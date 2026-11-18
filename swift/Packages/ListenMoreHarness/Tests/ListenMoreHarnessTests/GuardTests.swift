import XCTest
import ListenMoreCore
@testable import ListenMoreHarness

/// Repository and content guards: no audio in the repository, synthetic-only script text, the key
/// kept out of arguments, logs and output, disk writes confined, and the live workflow's gating.
final class GuardTests: XCTestCase {
    static let packageURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let repoURL = packageURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    func files(under root: URL, skipping: Set<String> = [".git", ".build", ".swiftpm", "build"]) -> [URL] {
        var out: [URL] = []
        guard let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey]) else { return [] }
        for case let url as URL in e {
            if skipping.contains(url.lastPathComponent) {
                e.skipDescendants()
                continue
            }
            if (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == false { out.append(url) }
        }
        return out
    }

    func testRepositoryHasNoAudio() throws {
        XCTAssertTrue(FileManager.default.fileExists(atPath: Self.repoURL.appendingPathComponent("docs/MAC_DEMO_CHECKS.md").path),
                      "repo root not found")
        let all = files(under: Self.repoURL)
        XCTAssertGreaterThan(all.count, 100)
        let audio = all.filter { DiskAudit.audioExtensions.contains($0.pathExtension.lowercased()) || DiskAudit.hasAudioSignature($0) }
        XCTAssertEqual(audio.map(\.path), [], "audio files in the repository")
        let plaud = all.filter { $0.path.lowercased().contains("plaud") }
        XCTAssertEqual(plaud.map(\.path), [], "no Plaud fixtures")
    }

    func testAudioSignatures() {
        XCTAssertTrue(DiskAudit.isAudioHeader(Data("RIFF\u{0}\u{0}\u{0}\u{0}WAVE".utf8)))
        XCTAssertTrue(DiskAudit.isAudioHeader(Data("OggS....".utf8)))
        XCTAssertTrue(DiskAudit.isAudioHeader(Data("\u{0}\u{0}\u{0}\u{18}ftypM4A ".utf8)))
        XCTAssertFalse(DiskAudit.isAudioHeader(Data("# Call transcript".utf8)))
    }

    /// Script and TTS text: generic work talk. A capitalized word mid-sentence (a name, a company, a
    /// product) fails, as does any of a list of product and company names.
    func testScriptTextIsSyntheticOnly() {
        let pronouns: Set<String> = ["I", "I'm", "I'll", "I've", "I'd"]
        let denied: Set<String> = ["zoom", "google", "microsoft", "apple", "facetime", "slack", "webex", "cisco", "chrome", "openai",
                                   "plaud", "amazon", "facebook", "linkedin", "github", "dia", "macbook", "airpods", "iphone"]
        for s in Scenarios.all {
            for line in s.lines {
                var sentenceStart = true
                for raw in line.text.split(separator: " ") {
                    let word = raw.trimmingCharacters(in: .punctuationCharacters)
                    if let f = word.first, f.isUppercase, !sentenceStart, !pronouns.contains(word) {
                        XCTFail("\(s.name)/\(line.id): capitalized word mid-sentence: \(word)")
                    }
                    sentenceStart = raw.last.map { ".?!".contains($0) } ?? false
                }
                for t in ScriptText.tokens(line.text) where denied.contains(t) { XCTFail("\(s.name)/\(line.id): \(t)") }
            }
            for c in s.controls { if let tag = c.tag { XCTAssertEqual(tag, "Guest", "speaker tags stay generic") } }
        }
        XCTAssertEqual(Set(OpenAITTS.voices.values), ["alloy", "coral", "onyx"], "stock TTS voices only")
    }

    /// Every cut-in the oracle expects starts in an unpunctuated stretch of Them's line: a TTS take
    /// pauses at a comma for 0.2-0.5 s, which can run past the 0.3 s a cut-in's opening overlap allows, so a cut-in
    /// there may or may not count. Checked from 0.3 s before You start to the end of Them's line at a
    /// fast 3.4 words/s.
    func testExpectedCutInsStartInUnpunctuatedThemSpeech() throws {
        let config = try ListenMoreConfig.builtIn()
        var bad: [String] = []
        var checked: [String] = []
        for s in Scenarios.all {
            let t = try Timeline.realize(s, shapes: SyntheticVoice.shapes(s))
            let expected = CueOracle.expected(t, config: config, facts: .init(keyless: s.keyless, gptStopT: nil, mode: .offline)).cues
            for e in expected where e.type == .interrupt {
                guard let ids = e.cutIn, let you = t.line(ids.you), let them = t.line(ids.them) else {
                    bad.append("\(s.name): an expected interrupt without its lines")
                    continue
                }
                checked.append("\(s.name)/\(ids.you)")
                let tail = them.line.words.suffix(Int(((them.end - you.start + 0.3) * 3.4).rounded(.up)))
                if tail.dropLast().contains(where: { $0.last.map { ",;:.?!".contains($0) } ?? false }) {
                    bad.append("\(s.name)/\(ids.you) over \(ids.them): …\(tail.joined(separator: " "))")
                }
            }
        }
        XCTAssertEqual(bad, [])
        XCTAssertEqual(checked.sorted(), ["cost-cap/y2", "interruption/y3", "mute-unmute/y5", "no-key/y3", "pause/y1", "pause/y3"])
    }

    /// The cue policy shows one cue at a time and holds every cue for `global_cooldown_s` after the
    /// last, except a local interrupt after a judged cue, which only waits while the verdict is on
    /// screen (`on_screen_s`). The judge may say not_listening on any You line after a Them turn (live,
    /// judge on), so no expected cue may start within that hold of a verdict on an earlier You line: it
    /// could be held by design, and the scenario would test the judge instead of its rule. From 2.6 to
    /// a fast 3.4 words/s.
    func testExpectedCuesAreClearOfEarlierJudgeVerdictsCooldown() throws {
        let config = try ListenMoreConfig.builtIn()
        var bad: [String] = []
        for wordsPerS in [2.6, 3.0, 3.4] {
            for s in Scenarios.all {
                let shapes = Dictionary(uniqueKeysWithValues: s.lines.map { line -> (String, ClipShape) in
                    let voiced = line.seconds ?? Double(line.words.count) / wordsPerS
                    return (line.id, ClipShape(lead: 0, voiced: voiced, total: voiced))
                })
                let t = try Timeline.realize(s, shapes: shapes)
                let (expected, tolerated) = CueOracle.expected(t, config: config,
                                                               facts: .init(keyless: s.keyless, gptStopT: nil, mode: .live, judgeOn: true))
                for e in expected where !e.optional {
                    guard let line = e.line.flatMap({ t.line($0) }) else {
                        bad.append("\(s.name): an expected \(e.type.rawValue) without its You line")
                        continue
                    }
                    for v in tolerated where v.type == .notListening {
                        guard let earlier = v.line.flatMap({ t.line($0) }), earlier.start < line.start else { continue }
                        let clear = v.window.upperBound + (e.type == .interrupt ? config.cues.onScreenS : config.cues.globalCooldownS)
                        if e.window.lowerBound < clear {
                            bad.append(String(format: "%@ at %.1f words/s: %@ on %@ from %.1f s, a verdict on %@ until %.1f s holds cues to %.1f s",
                                              s.name, wordsPerS, e.type.rawValue, line.line.id, e.window.lowerBound, earlier.line.id,
                                              v.window.upperBound, clear))
                        }
                    }
                }
            }
        }
        XCTAssertEqual(bad, [])
    }

    /// The policy's `on_screen_s` is how long the coach card holds a nudge (`CardStyle.Coach.nudgeHold`).
    func testOnScreenHoldMatchesTheCardsNudgeHold() throws {
        let theme = try String(contentsOf: Self.repoURL.appendingPathComponent("swift/Core/Theme.swift"), encoding: .utf8)
        let decl = try XCTUnwrap(theme.split(separator: "\n").first { $0.contains("static let nudgeHold: TimeInterval =") })
        let value = try XCTUnwrap(Double(decl.split(separator: "=").last?.trimmingCharacters(in: .whitespaces) ?? ""))
        XCTAssertEqual(try ListenMoreConfig.builtIn().cues.onScreenS, value)
    }

    func testKeyIsRefusedInArguments() {
        let env = [Harness.keyVariable: "sk-test-0123456789abcdef"]
        XCTAssertThrowsError(try Harness.checkArguments(["--live", "sk-proj-abcdefghijklmnop"], environment: [:]))
        XCTAssertThrowsError(try Harness.checkArguments(["--key=sk-test-0123456789abcdef"], environment: env))
        XCTAssertThrowsError(try Harness.checkArguments(["OPENAI_API_KEY=x"], environment: [:]))
        XCTAssertNoThrow(try Harness.checkArguments(["--live", "--scenario", "mute-unmute", "--out", "/tmp/x"], environment: env))
    }

    func testOutputWriterScrubsSecrets() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lm-harness-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let w = try OutputWriter(directory: dir, secrets: ["sk-canary-0123456789"])
        let url = try w.write("x.md", "before sk-canary-0123456789 after")
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "before [REDACTED] after")
        XCTAssertEqual(w.leaks, ["x.md"])
    }

    /// Harness sources: disk writes only in RunDirectory.swift (the run dir) and Report.swift (the
    /// output folder); printing only in the CLI; the key variable read in one place; no audio writers.
    func testHarnessSourcesConfineWritesAndKeys() throws {
        let src = Self.packageURL.appendingPathComponent("Sources")
        let swift = files(under: src).filter { $0.pathExtension == "swift" }
        XCTAssertGreaterThan(swift.count, 10)
        let writers: Set<String> = ["RunDirectory.swift", "Report.swift"]
        for url in swift {
            let name = url.lastPathComponent
            let text = try String(contentsOf: url, encoding: .utf8)
            for f in ["AVAudioFile", "AVAssetWriter", "FileHandle(forWriting", "createFile(", "fopen("] {
                XCTAssertFalse(text.contains(f), "\(name) contains \(f)")
            }
            if !writers.contains(name) {
                for f in ["write(to:", "createDirectory(", "removeItem(", "moveItem(", "copyItem("] {
                    XCTAssertFalse(text.contains(f), "\(name) contains \(f)")
                }
            }
            if name != "main.swift" {
                XCTAssertFalse(text.contains("print("), "\(name) prints")
                XCTAssertFalse(text.contains("NSLog"), "\(name) logs")
            }
            if !["Harness.swift", "main.swift"].contains(name) {
                XCTAssertFalse(text.contains("OPENAI_API_KEY"), "\(name) reads the key variable")
            }
        }
    }

    /// The live job: manual dispatch only, owner only, the restricted environment; nothing in the
    /// repository runs on pull_request_target; the offline CI job never sees a secret.
    func testWorkflowGating() throws {
        let wf = Self.repoURL.appendingPathComponent(".github/workflows")
        let live = try String(contentsOf: wf.appendingPathComponent("harness-live.yml"), encoding: .utf8)
        let triggers = Self.topLevelBlock("on", in: live).filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("#") }
        let keys = triggers.filter { $0.hasPrefix("  ") && !$0.hasPrefix("   ") }.map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(keys, ["workflow_dispatch:"], "the live workflow triggers on manual dispatch only")
        let ownerOnly = "if: github.actor == github.repository_owner && github.triggering_actor == github.repository_owner"
        XCTAssertTrue(live.contains(ownerOnly))
        let openAILive = try String(contentsOf: wf.appendingPathComponent("live-openai.yml"), encoding: .utf8)
        XCTAssertTrue(openAILive.contains(ownerOnly), "the other paid workflow is owner-only on re-runs too")
        XCTAssertTrue(live.contains("environment: openai-live"))
        XCTAssertTrue(live.contains("--live"))
        XCTAssertTrue(live.contains("--no-judge"), "0 judge calls unless the judge input is set")
        // Every workflow runs pinned code: containers by digest, every action by full commit SHA.
        let workflows = try FileManager.default.contentsOfDirectory(atPath: wf.path).filter { $0.hasSuffix(".yml") || $0.hasSuffix(".yaml") }
        XCTAssertTrue(Set(workflows).isSuperset(of: ["ci.yml", "harness-live.yml", "live-openai.yml"]))
        for f in workflows {
            let text = try String(contentsOf: wf.appendingPathComponent(f), encoding: .utf8)
            let uses = text.components(separatedBy: "\n").filter { $0.contains("uses:") }
            XCTAssertGreaterThanOrEqual(uses.count, 1, f)
            for u in uses { XCTAssertNotNil(u.range(of: #"uses: [\w./-]+@[0-9a-f]{40}( |$)"#, options: .regularExpression), "\(f): \(u)") }
            for c in text.components(separatedBy: "\n").filter({ $0.contains("container:") }) {
                XCTAssertNotNil(c.range(of: #"container: [\w./:-]+@sha256:[0-9a-f]{64}"#, options: .regularExpression), "\(f): \(c)")
            }
        }
        for f in try FileManager.default.contentsOfDirectory(atPath: wf.path) where f.hasSuffix(".yml") {
            let text = try String(contentsOf: wf.appendingPathComponent(f), encoding: .utf8)
            XCTAssertFalse(text.contains("pull_request_target"), "\(f) uses pull_request_target")
            if f != "harness-live.yml" { XCTAssertFalse(text.contains("lm-harness --live") || text.contains("--live\""), "\(f) runs live mode") }
            if !["harness-live.yml", "live-openai.yml"].contains(f) {
                XCTAssertFalse(text.contains("OPENAI_API_KEY"), "\(f) touches the key")
            }
        }
        let ci = try String(contentsOf: wf.appendingPathComponent("ci.yml"), encoding: .utf8)
        XCTAssertTrue(ci.contains("\n  linux-harness:"))
        XCTAssertFalse(ci.contains("secrets."), "CI on pushes and pull requests uses no secrets")
    }

    /// The lines of a top-level YAML key's block (`key:` up to the next top-level key).
    static func topLevelBlock(_ key: String, in yaml: String) -> [String] {
        var out: [String] = []
        var inside = false
        for line in yaml.components(separatedBy: "\n") {
            let topLevel = !line.isEmpty && !line.hasPrefix(" ") && !line.hasPrefix("#")
            if topLevel { inside = line.hasPrefix(key + ":") }
            else if inside { out.append(line) }
        }
        return out
    }
}

/// Live mode's wiring without the network: fake TTS and judge endpoints, the scripted realtime socket,
/// and a canary key. The key goes only into Authorization headers; never into logs or output files.
@MainActor
final class LiveWiringTests: XCTestCase {
    nonisolated static let canary = "sk-harness-canary-0123456789abcdef"

    final class FakeOpenAI: HTTPTransport, @unchecked Sendable {
        let lock = NSLock()
        var ttsCalls = 0
        var judgeCalls = 0
        var authorized = 0

        func post(url: URL, headers: [String: String], body: Data, timeout: TimeInterval) async throws -> (status: Int, body: Data) {
            lock.withLock { if headers["Authorization"] == "Bearer \(LiveWiringTests.canary)" { authorized += 1 } }
            if url.path.hasSuffix("/audio/speech") {
                let req = try JSONSerialization.jsonObject(with: body) as? [String: Any]
                XCTAssertEqual(req?["response_format"] as? String, "pcm")
                let words = (req?["input"] as? String ?? "").split(separator: " ").count
                let speech = SyntheticVoice.speech(seconds: Double(words) / 2.6, seed: words, f0: 150, sampleRate: 24000)
                let samples = [Float](repeating: 0, count: 2400) + speech + [Float](repeating: 0, count: 2400)
                lock.withLock { ttsCalls += 1 }
                return (200, AudioMath.pcm16Data(samples[...]))
            }
            lock.withLock { judgeCalls += 1 }
            return try await StubJudgeHTTP().post(url: url, headers: headers, body: body, timeout: timeout)
        }
    }

    func testLiveWiringKeepsTheKeyOutOfEverything() async throws {
        let scenario = Scenario(name: "live-wiring", summary: "short exchange", lines: [
            Line("a1", .themA, "The draft is ready for a first look.", .at(0.3)),
            Line("y1", .you, "Thanks, I will read it after lunch.", .after("a1", gap: 1.0)),
        ], tail: 1.5)
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("lm-harness-test-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: out) }
        let http = FakeOpenAI()
        let clock = HarnessClock(.wall)
        let backend = LiveBackend(http: http, webSocket: ScriptedRealtime(clock: clock, sampleRate: 24000))
        var logged: [String] = []
        let summary = try await Harness.run(HarnessOptions(mode: .live, scenarios: [scenario], outputDirectory: out,
                                                           environment: [Harness.keyVariable: Self.canary], liveBackend: backend)) {
            logged.append($0)
        }
        XCTAssertEqual(http.ttsCalls, 2)
        XCTAssertGreaterThanOrEqual(http.authorized, 2, "the key reaches the API as a bearer token")
        XCTAssertTrue(summary.leaks.isEmpty)
        for line in logged { XCTAssertFalse(line.contains(Self.canary)) }
        let names = try FileManager.default.contentsOfDirectory(atPath: out.path).sorted()
        XCTAssertEqual(names, ["cost-log.jsonl", "results.json", "results.md"])
        for n in names {
            let text = try String(contentsOf: out.appendingPathComponent(n), encoding: .utf8)
            XCTAssertFalse(text.contains(Self.canary), n)
            XCTAssertFalse(text.contains("canary"), n)
        }
        let costKinds = Set(summary.costEntries.map(\.kind))
        XCTAssertEqual(costKinds, ["tts", "transcription", "judge"], "live mode writes a token/cost log")
        let r = try XCTUnwrap(summary.results.first)
        XCTAssertEqual(r.check("no-audio-on-disk")?.passed, true, r.check("no-audio-on-disk")?.detail ?? "")
        XCTAssertEqual(r.check("keep-nothing")?.passed, true)
    }

    func testLiveModeNeedsTheKeyFromTheEnvironment() async {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("lm-harness-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: out) }
        do {
            _ = try await Harness.run(HarnessOptions(mode: .live, scenarios: [Scenarios.interruption], outputDirectory: out, environment: [:]))
            XCTFail("live mode ran without a key")
        } catch {
            XCTAssertEqual(error as? HarnessError, .missingKey)
        }
    }
}
