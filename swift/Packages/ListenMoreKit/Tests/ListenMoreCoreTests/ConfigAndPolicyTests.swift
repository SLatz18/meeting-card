import XCTest
@testable import ListenMoreCore

final class ConfigTests: XCTestCase {
    func tempFile(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("listen-more-test-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testLoadsDefaults() throws {
        let c = try TestConfig.load()
        XCTAssertEqual(c.audio.sampleRate, 24000)
        XCTAssertEqual(c.audio.frameMs, 20)
        XCTAssertEqual(c.frameSamples, 480)
        XCTAssertEqual(c.cues.cooldownS, 20)
        XCTAssertEqual(c.cues.fadeS, 3)
        XCTAssertEqual(c.cues.gptMinConfidence, 0.7)
        XCTAssertEqual(c.cues.colors["interrupt"], .red)
        XCTAssertEqual(c.cues.colors["talk_share"], .amber)
        XCTAssertEqual(c.local.interruptConfirmMs, 300)
        XCTAssertEqual(c.local.talkOverMs, 1000)
        XCTAssertEqual(c.local.monologueS, 75)
        XCTAssertEqual(c.local.talkShareMax, 0.55)
        XCTAssertEqual(c.gpt.budgetUsdPerCall, 1.0)
        XCTAssertEqual(c.trigger.startAfterS, 3)
        XCTAssertEqual(c.trigger.stopAfterS, 30)
        XCTAssertTrue(c.trigger.excludeBundleIds.contains("com.slatz.meetingcard.swift"))
        XCTAssertTrue(c.trigger.excludeBundleIds.contains("com.listenmore.mac"))
    }

    /// The shipped config is generic defaults only: known sections, no per-user data blocks.
    func testBuiltInConfigIsGenericDefaultsOnly() throws {
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(DefaultConfig.json.utf8)) as? [String: Any])
        XCTAssertEqual(Set(root.keys), ["audio", "vad", "local", "cues", "gpt", "trigger", "capture_targets"])
        let cues = try XCTUnwrap(root["cues"] as? [String: Any])
        XCTAssertEqual(Set(cues.keys), ["cooldown_s", "fade_s", "gpt_min_confidence", "colors"])
    }

    func testDefaultAllowlist() throws {
        let ids = try TestConfig.load().captureTargets.map(\.bundleId)
        for id in ["us.zoom.xos", "com.google.Chrome", "company.thebrowser.dia", "com.microsoft.teams2",
                   "Cisco-Systems.Spark", "com.apple.FaceTime", "com.tinyspeck.slackmacgap"] {
            XCTAssertTrue(ids.contains(id), id)
        }
        let dia = try TestConfig.load().captureTargets.first { $0.name == "Dia" }
        XCTAssertTrue(dia?.bundleIdStatus?.contains("UNVERIFIED") ?? false)
        XCTAssertEqual(try TestConfig.load().captureTargets.first { $0.kind == .zoom }?.processName, "zoom.us")
    }

    func testOverrideDeepMerges() throws {
        let over = try tempFile(#"{"cues": {"cooldown_s": 5, "colors": {"monologue": "red"}}, "trigger": {"stop_after_s": 120}}"#)
        let c = try ListenMoreConfig.load(overrideURL: over)
        XCTAssertEqual(c.cues.cooldownS, 5)
        XCTAssertEqual(c.cues.fadeS, 3)
        XCTAssertEqual(c.cues.colors["monologue"], .red)
        XCTAssertEqual(c.cues.colors["interrupt"], .red)
        XCTAssertEqual(c.trigger.stopAfterS, 120)
        XCTAssertEqual(c.trigger.startAfterS, 3)
    }

    func testOverrideReplacesCaptureTargets() throws {
        let over = try tempFile(#"""
        {"capture_targets": [
          {"name": "Zoom", "kind": "zoom", "process_name": "zoom.us", "bundle_id": "us.zoom.xos"},
          {"name": "Arc", "kind": "browser", "process_name": "Arc", "bundle_id": "company.thebrowser.Browser"}
        ]}
        """#)
        XCTAssertEqual(try ListenMoreConfig.load(overrideURL: over).captureTargets.map(\.name), ["Zoom", "Arc"])
    }

    func testRejectsUnknownColor() throws {
        XCTAssertThrowsError(try ListenMoreConfig.load(overrideURL: try tempFile(#"{"cues": {"colors": {"interrupt": "blue"}}}"#)))
    }

    func testRejectsMissingBrowserTarget() throws {
        let over = try tempFile(#"{"capture_targets": [{"name": "Zoom", "kind": "zoom", "process_name": "zoom.us", "bundle_id": "us.zoom.xos"}]}"#)
        XCTAssertThrowsError(try ListenMoreConfig.load(overrideURL: over)) { error in
            XCTAssertEqual(error as? ConfigError, .invalid("no browser capture target"))
        }
    }

    func testConfigHasNoSecrets() {
        XCTAssertNil(DefaultConfig.json.range(of: #"sk-[A-Za-z0-9_-]{10,}"#, options: .regularExpression))
    }

    func testAPIKeyIsRedacted() {
        let secret = "sk-test-0123456789abcdef"
        let key = APIKey(secret)!
        XCTAssertFalse(String(describing: key).contains(secret))
        XCTAssertFalse(String(reflecting: key).contains(secret))
        XCTAssertFalse("\(key)".contains(secret))
        var dumped = ""
        dump(key, to: &dumped)
        XCTAssertFalse(dumped.contains(secret))
        XCTAssertEqual(key.value, secret)
        XCTAssertNil(APIKey("  \n"))
    }
}

/// Port of tests/test_cues_gpt.py::test_cooldown_per_type_and_colors, plus Swift-only cases.
final class CuePolicyTests: XCTestCase {
    var config: ListenMoreConfig!

    override func setUpWithError() throws {
        config = try TestConfig.load()
    }

    func testCooldownPerTypeAndColors() {
        let p = CuePolicy(config: config.cues)
        XCTAssertEqual(p.offer(.interrupt, t: 1, onset: 0.8, source: .local)?.color, .red)
        XCTAssertNil(p.offer(.interrupt, t: 10, onset: 9.8, source: .local))
        XCTAssertNotNil(p.offer(.talkOver, t: 10, onset: 9, source: .local))
        XCTAssertNotNil(p.offer(.interrupt, t: 21.5, onset: 21, source: .local))
        XCTAssertEqual(p.offer(.missedQuestion, t: 5, onset: 1, source: .gpt, confidence: 0.9)?.color, .amber)
        XCTAssertNil(p.offer(.aggressive, t: 5, onset: 1, source: .gpt, confidence: 0.5))
        XCTAssertEqual(p.offer(.monologue, t: 5, onset: 5, source: .local)?.fadeS, 3)
        XCTAssertEqual(p.suppressed, 1)
    }

    func testCooldownBoundaryIsTwentySeconds() {
        let p = CuePolicy(config: config.cues)
        XCTAssertNotNil(p.offer(.aggressive, t: 0, onset: 0, source: .local))
        XCTAssertNil(p.offer(.aggressive, t: 19.999, onset: 19.9, source: .local))
        XCTAssertNotNil(p.offer(.aggressive, t: 20, onset: 19.9, source: .local))
    }

    func testGptNeedsConfidence() {
        let p = CuePolicy(config: config.cues)
        XCTAssertNil(p.offer(.aggressive, t: 0, onset: 0, source: .gpt))
        XCTAssertNotNil(p.offer(.aggressive, t: 0, onset: 0, source: .gpt, confidence: 0.7))
    }

    func testGptInterruptingSharesLocalCooldown() {
        let p = CuePolicy(config: config.cues)
        XCTAssertEqual(CueType(gptLabel: "interrupting"), .interrupt)
        XCTAssertNil(CueType(gptLabel: "none"))
        XCTAssertNotNil(p.offer(.interrupt, t: 1, onset: 0.7, source: .local))
        XCTAssertNil(p.offer(CueType(gptLabel: "interrupting")!, t: 4, onset: 1, source: .gpt, confidence: 0.95))
    }

    func testColors() {
        let p = CuePolicy(config: config.cues)
        let red: [CueType] = [.interrupt, .talkOver, .aggressive]
        for (i, type) in CueType.allCases.enumerated() {
            XCTAssertEqual(p.offer(type, t: Double(i), onset: Double(i), source: .local)?.color, red.contains(type) ? .red : .amber, type.rawValue)
        }
    }

    func testLatency() {
        XCTAssertEqual(CuePolicy(config: config.cues).offer(.interrupt, t: 3.301, onset: 3.0, source: .local)?.latencyMs, 301)
    }

    func testPausedSuppressesWithoutConsumingCooldown() {
        let p = CuePolicy(config: config.cues)
        p.paused = true
        XCTAssertNil(p.offer(.interrupt, t: 0, onset: 0, source: .local))
        p.paused = false
        XCTAssertNotNil(p.offer(.interrupt, t: 1, onset: 1, source: .local))
    }

    func testReset() {
        let p = CuePolicy(config: config.cues)
        XCTAssertNotNil(p.offer(.interrupt, t: 0, onset: 0, source: .local))
        p.reset()
        XCTAssertNotNil(p.offer(.interrupt, t: 1, onset: 1, source: .local))
    }
}
