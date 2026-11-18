import XCTest
@testable import ListenMoreCore

final class ConfigTests: XCTestCase {
    func tempFile(_ json: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("listen-more-test-\(UUID().uuidString).json")
        try Data(json.utf8).write(to: url)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func testBuiltInIsValidAndGeneric() throws {
        let c = try ListenMoreConfig.builtIn()
        XCTAssertEqual(c, try TestConfig.load())
        XCTAssertEqual(c.trigger.pollS, 0.5)
        XCTAssertEqual(c.trigger.startAfterS, 3)
        XCTAssertEqual(c.trigger.stopAfterS, 30)
        XCTAssertEqual(c.trigger.endedStopAfterS, 3)
        XCTAssertEqual(c.trigger.excludeBundleIds, ["com.listenmore.mac"])
        XCTAssertNil(DefaultConfig.json.range(of: #"sk-[A-Za-z0-9_-]{10,}"#, options: .regularExpression))
    }

    func testOverridesDictionaryDeepMerges() throws {
        let c = try ListenMoreConfig.load(overrides: ["trigger": ["start_after_s": 0], "local": ["monologue_soft_s": 40]])
        XCTAssertEqual(c.trigger.startAfterS, 0)
        XCTAssertEqual(c.trigger.stopAfterS, 30)
        XCTAssertEqual(c.local.monologueSoftS, 40)
        XCTAssertEqual(c.local.monologueStrongS, 90)
        let raw = try ListenMoreConfig.merged(overrides: ["host_section": ["k": 1]])
        XCTAssertEqual((raw["host_section"] as? [String: Int])?["k"], 1)
        XCTAssertNotNil(raw["capture_targets"])
    }

    func testDisabledCuesAreAHostChoice() throws {
        XCTAssertNil(try TestConfig.load().cues.disabled, "the generic config switches nothing off")
        let c = try ListenMoreConfig.load(overrides: ["cues": ["disabled": ["not_listening"]]])
        XCTAssertEqual(c.cues.disabledTypes, [.notListening])
        XCTAssertEqual(c.cues.cooldownS, 20, "the rest of the section is kept")
        XCTAssertThrowsError(try ListenMoreConfig.load(overrides: ["cues": ["disabled": ["shouting"]]])) { error in
            XCTAssertEqual(error as? ConfigError, .invalid("unknown cue type in disabled"))
        }
    }

    func testRejectsBadTriggerTiming() throws {
        XCTAssertThrowsError(try ListenMoreConfig.load(overrides: ["trigger": ["poll_s": 0]])) { error in
            XCTAssertEqual(error as? ConfigError, .invalid("bad trigger timing"))
        }
        XCTAssertThrowsError(try ListenMoreConfig.load(overrides: ["trigger": ["stop_after_s": -1]]))
        XCTAssertThrowsError(try ListenMoreConfig.load(overrides: ["trigger": ["ended_stop_after_s": 0]]))
        XCTAssertThrowsError(try ListenMoreConfig.load(overrides: ["trigger": ["ended_stop_after_s": 31]]),
                             "the ended stop is never slower than the Core Audio stop")
    }

    /// No judge question for self_pivot: nothing asks a judge about it.
    func testNoJudgeQuestionForSelfPivot() throws {
        let q = try TestConfig.load().judge.typesafe.questions
        XCTAssertNil(q.question(for: .selfPivot))
        XCTAssertFalse(q.asked.contains { $0.type == .selfPivot })
        XCTAssertEqual(q.asked.map(\.type), CueType.judged)
    }

    func testLoadsDefaults() throws {
        let c = try TestConfig.load()
        XCTAssertEqual(c.audio.sampleRate, 24000)
        XCTAssertEqual(c.audio.frameMs, 20)
        XCTAssertEqual(c.cues.cooldownS, 20)
        XCTAssertEqual(c.cues.fadeS, 3)
        XCTAssertEqual(c.cues.gptMinConfidence, 0.7)
        XCTAssertEqual(c.cues.colors["interrupt"], .red)
        XCTAssertEqual(c.cues.colors["talk_share"], .amber)
        XCTAssertEqual(c.cues.colors["self_pivot"], .amber)
        XCTAssertEqual(c.cues.priority, ["talk_over", "interrupt", "missed_question", "aggressive", "monologue", "not_listening", "self_pivot", "talk_share"])
        XCTAssertEqual(Set(c.cues.colors.keys), Set(CueType.allCases.map(\.rawValue)), "a colour for every cue type")
        XCTAssertEqual(c.meetTitleRegex, #"\bMeet\b"#)
        XCTAssertEqual(c.captureTargets.map(\.bundleId), ["us.zoom.xos", "com.google.Chrome", "company.thebrowser.dia",
                                                         "com.microsoft.teams2", "com.microsoft.teams", "Cisco-Systems.Spark",
                                                         "com.cisco.webexmeetingsapp", "com.apple.FaceTime",
                                                         "com.tinyspeck.slackmacgap"])
        XCTAssertEqual(c.audio.vadRate, 16000)
        XCTAssertEqual(c.audio.vadAggressiveness, 3)
        XCTAssertEqual(c.vad.hangoverMs, 200)
        XCTAssertEqual(c.local.cutInMinOverlapMs, 600)
        XCTAssertEqual(c.local.monologueSoftS, 60)
        XCTAssertEqual(c.cues.globalCooldownS, 20)
        XCTAssertEqual(c.cues.onScreenS, 4.5)
        XCTAssertEqual(c.gpt.notListeningMinConfidence, 0.85)
        XCTAssertEqual(c.gpt.judgeModel, "gpt-6-luna")
        XCTAssertEqual(c.gpt.transcribeModel, "gpt-live-transcribe")
        XCTAssertFalse(c.gpt.store)
        XCTAssertEqual(c.gpt.budgetUsdPerCall, 1.0)
        XCTAssertEqual(c.captureTargets.first?.meetingTitlePatterns, ["Zoom Meeting", "Zoom Webinar"])
    }

    func testOverrideDeepMerges() throws {
        let over = try tempFile(#"{"cues": {"cooldown_s": 5, "colors": {"monologue": "red"}}, "meet_title_regex": "\\bHuddle\\b"}"#)
        let c = try TestConfig.load(overrideURL: over)
        XCTAssertEqual(c.cues.cooldownS, 5)
        XCTAssertEqual(c.cues.fadeS, 3)
        XCTAssertEqual(c.cues.colors["monologue"], .red)
        XCTAssertEqual(c.cues.colors["interrupt"], .red)
        XCTAssertEqual(c.meetTitleRegex, #"\bHuddle\b"#)
    }

    func testOverrideReplacesCaptureTargets() throws {
        let over = try tempFile(#"""
        {"capture_targets": [
          {"name": "Zoom", "kind": "zoom", "process_name": "zoom.us", "bundle_id": "us.zoom.xos",
           "meeting_title_patterns": ["Zoom Meeting"]},
          {"name": "Arc", "kind": "browser", "process_name": "Arc", "bundle_id": "company.thebrowser.Browser"}
        ]}
        """#)
        let c = try TestConfig.load(overrideURL: over)
        XCTAssertEqual(c.captureTargets.map(\.name), ["Zoom", "Arc"])
        XCTAssertNil(c.captureTargets[1].meetingTitlePatterns)
    }

    func testNewTargetsAndAudioBundleIds() throws {
        let c = try TestConfig.load()
        let byName = Dictionary(uniqueKeysWithValues: c.captureTargets.map { ($0.name, $0) })
        for name in ["Microsoft Teams", "Webex", "FaceTime", "Slack"] {
            XCTAssertEqual(byName[name]?.kind, .native, name)
            XCTAssertFalse(byName[name]?.meetingTitlePatterns?.isEmpty ?? true, name)
            XCTAssertTrue(byName[name]?.bundleIdStatus?.contains("UNVERIFIED") ?? false, name)
        }
        XCTAssertEqual(byName["FaceTime"]?.ownedBundleIds, ["com.apple.FaceTime", "com.apple.avconferenced"])
        XCTAssertEqual(byName["Zoom"]?.ownedBundleIds, ["us.zoom.xos"])
    }

    func testTargetWithoutTitlePatternsIsAllowed() throws {
        let over = try tempFile(#"""
        {"capture_targets": [
          {"name": "Zoom", "kind": "zoom", "process_name": "zoom.us", "bundle_id": "us.zoom.xos"},
          {"name": "Arc", "kind": "browser", "process_name": "Arc", "bundle_id": "company.thebrowser.Browser"}
        ]}
        """#)
        let c = try TestConfig.load(overrideURL: over)
        XCTAssertNil(c.captureTargets[0].meetingTitlePatterns)
    }

    func testRejectsStoreTrueAndBadVadFrame() throws {
        XCTAssertThrowsError(try TestConfig.load(overrideURL: try tempFile(#"{"gpt": {"store": true}}"#))) { error in
            XCTAssertEqual(error as? ConfigError, .invalid("gpt.store must be false"))
        }
        XCTAssertThrowsError(try TestConfig.load(overrideURL: try tempFile(#"{"audio": {"frame_ms": 25}}"#)))
        XCTAssertThrowsError(try TestConfig.load(overrideURL: try tempFile(#"{"audio": {"vad_aggressiveness": 4}}"#)))
    }

    func testRejectsUnknownColor() throws {
        let over = try tempFile(#"{"cues": {"colors": {"interrupt": "blue"}}}"#)
        XCTAssertThrowsError(try TestConfig.load(overrideURL: over))
    }

    func testRejectsMissingBrowserTarget() throws {
        let over = try tempFile(#"{"capture_targets": [{"name": "Zoom", "kind": "zoom", "process_name": "zoom.us", "bundle_id": "us.zoom.xos", "meeting_title_patterns": ["Zoom Meeting"]}]}"#)
        XCTAssertThrowsError(try TestConfig.load(overrideURL: over)) { error in
            XCTAssertEqual(error as? ConfigError, .invalid("no browser capture target"))
        }
    }

    func testRejectsBadRegex() throws {
        let over = try tempFile(#"{"meet_title_regex": "("}"#)
        XCTAssertThrowsError(try TestConfig.load(overrideURL: over))
    }

    func testLoadFailureMessagePrintsTypeOnly() {
        let path = "/Users/someone/Library/Application Support/listen-more/default.json"
        let snippet = "{\"openai_api_key\":\"sk-live-should-not-print\"}"
        let invalid = ListenMoreConfig.loadFailureMessage(ConfigError.invalid("\(path) \(snippet)"))
        XCTAssertEqual(invalid, "ListenMoreKit: could not load the coach config (invalid)")
        XCTAssertFalse(invalid.contains(path))
        XCTAssertFalse(invalid.contains("sk-live"))

        let cocoa = NSError(domain: NSCocoaErrorDomain, code: 260, userInfo: [
            NSFilePathErrorKey: path,
            NSLocalizedDescriptionKey: "The file \(path) doesn’t exist. \(snippet)",
        ])
        let cocoaLine = ListenMoreConfig.loadFailureMessage(cocoa)
        XCTAssertEqual(cocoaLine, "ListenMoreKit: could not load the coach config (NSError)")
        XCTAssertFalse(cocoaLine.contains(path))
        XCTAssertFalse(cocoaLine.contains(snippet))
        XCTAssertFalse(cocoaLine.contains("260"))
    }

    func testConfigErrorHasOnlyTheInvalidCase() {
        XCTAssertEqual(ConfigError.invalid("anything").publicName, "invalid")
    }
}
