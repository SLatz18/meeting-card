import XCTest

/// The call coach is wired in as an opt-in: a local package (the coach's single source, no remote
/// dependency), permission strings present, the opt-in a UserDefaults boolean (false until set), the
/// key in MeetingCard's own Keychain item, and the coach running in-process (no helper, no interpreter).
final class CoachWiringTests: XCTestCase {
    static let swiftDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    func read(_ path: String) throws -> String {
        try String(contentsOf: Self.swiftDir.appendingPathComponent(path), encoding: .utf8)
    }

    func testKitIsALocalPackage() throws {
        let spec = try read("project.yml")
        XCTAssertTrue(spec.contains("path: Packages/ListenMoreKit"))
        XCTAssertFalse(spec.contains("url:"), "no remote package dependencies")
        XCTAssertTrue(spec.contains("product: ListenMoreMac"))
    }

    func testUsageStringsShip() throws {
        for f in ["project.yml", "App/Info.plist"] {
            let s = try read(f)
            XCTAssertTrue(s.contains("NSMicrophoneUsageDescription"), f)
            XCTAssertTrue(s.contains("NSAudioCaptureUsageDescription"), f)
            XCTAssertTrue(s.contains("NSAppleEventsUsageDescription"), f)
        }
    }

    /// "Use Zoom/Meet controls" is off until the user turns it on, feeds the service's call state,
    /// and asks for permissions only from that toggle.
    func testCallControlsAreOptInAndFeedTheService() throws {
        let src = try read("App/CoachController.swift")
        XCTAssertTrue(src.contains("static let callControls = \"coach.callControls\""))
        XCTAssertTrue(src.contains("var callControlsOn: Bool { defaults.bool(forKey: Keys.callControls) }"), "false until set")
        XCTAssertTrue(src.contains("callControls.isEnabled = callControlsOn"))
        XCTAssertTrue(src.contains("keys: keyGate, callState: callControls"))
        XCTAssertTrue(src.contains("lazy var callControlsModel = CallControlsModel(provider: callControls"),
                      "the Mute control's model runs on the same provider (and its toggle)")
        let body = try XCTUnwrap(src.components(separatedBy: "func setCallControls(_ on: Bool)").dropFirst().first?
            .components(separatedBy: "func requestCallControlsAccess").first)
        XCTAssertTrue(body.contains("if on { requestCallControlsAccess() }"), "asks in context, only when turned on")
        let settings = try read("App/CoachSettingsWindow.swift")
        XCTAssertTrue(settings.contains("coach.setCallControls(sender.state == .on)"))
        XCTAssertTrue(settings.contains("Theme.CallControls.rowFont") && settings.contains("CoachCopy.callControlsToggle"))
    }

    func testOptInIsOffByDefault() throws {
        let src = try read("App/CoachController.swift")
        XCTAssertTrue(src.contains("static let enabled = \"coach.enabled\""))
        XCTAssertTrue(src.contains("var enabled: Bool { defaults.bool(forKey: Keys.enabled) }"), "bool(forKey:) is false until set")
        XCTAssertFalse(src.contains("register(defaults"), "no default that turns it on")
        let controller = try read("App/Controller.swift")
        XCTAssertTrue(controller.contains("if args.fixture == nil {\n            do {\n                coach = try CoachController()"),
                      "fixture runs never create the coach")
        XCTAssertTrue(controller.contains("log(ListenMoreConfig.loadFailureMessage(error))"),
                      "a config failure logs its type only")
    }

    func testKeyLivesInMeetingCardsKeychainItem() throws {
        let src = try read("App/CoachController.swift")
        XCTAssertTrue(src.contains("static let keychainService = AppIdentity.current.keychainService"), "<bundle id>.openai")
        XCTAssertTrue(src.contains("keychain: KeychainStore = KeychainStore(service: CoachController.keychainService)"))
        XCTAssertTrue(src.contains("keys: keyGate"), "the service reads the key from that item only, through the gate")
        XCTAssertTrue(try read("App/CoachKeyActions.swift").contains("func readKey() throws -> APIKey? { rejected ? nil : try store.readKey() }"),
                      "a rejected key is withheld, so only GPT cues stop")
    }

    /// The cue judge is a setting (gpt, the config's value, unless the user picks TypeSafe), read by
    /// the engine at each call start; the TypeSafe key is its own account under MeetingCard's service
    /// and is never sent anywhere to check it.
    func testCueJudgeIsASettingWithItsOwnKeychainAccount() throws {
        let src = try read("App/CoachController.swift")
        XCTAssertTrue(src.contains("static let judgeProvider = \"coach.judgeProvider\""))
        XCTAssertTrue(src.contains("Self.storedJudgeProvider(defaults) ?? config.judge.provider"), "the config value unless set")
        XCTAssertTrue(src.contains("typeSafeKeychain = keychain.sibling(account: KeychainStore.typeSafeAccount)"),
                      "the TypeSafe key follows the OpenAI key's service, however that is derived")
        for file in ["App/CoachController.swift", "App/CoachKeyActions.swift", "App/CoachSettingsWindow.swift", "App/UISnapshots.swift"] {
            let text = try read(file)
            XCTAssertFalse(text.contains("TYPESAFE_API_KEY"), "\(file) names the TypeSafe account")
            XCTAssertFalse(text.contains(".typesafe\"") || text.contains("scoped(\"typesafe"), "\(file) builds a TypeSafe service string")
        }
        XCTAssertTrue(src.contains("LocalCoachEngine(transports: .urlSession(), judgeKeys: typeSafeKeychain,"))
        XCTAssertTrue(src.contains("judgeProvider: { Self.storedJudgeProvider(defaults) })"))
        XCTAssertTrue(src.contains("keys: keyGate, callState: callControls, engine: engine"))
        let kitDefaults = try read("Packages/ListenMoreKit/Sources/ListenMoreCore/DefaultConfig.swift")
        XCTAssertTrue(kitDefaults.contains("\"provider\": \"gpt\""), "GPT stays the default judge")
        let keys = try read("App/CoachKeyActions.swift")
        let save = try XCTUnwrap(keys.components(separatedBy: "func saveTypeSafeKey").dropFirst().first?
            .components(separatedBy: "\n    }\n").first)
        XCTAssertTrue(save.contains("try? typeSafeKeychain.save(key)"))
        XCTAssertFalse(save.contains("KeyValidator") || save.contains("Task"), "nothing is sent to check the TypeSafe key")
    }

    /// Settings says why judging stopped from the failure's kind and status code only; the window
    /// never reads a key or shows key text.
    func testJudgeStopNoteCarriesNoKeyText() throws {
        let window = try read("App/CoachSettingsWindow.swift")
        XCTAssertTrue(window.contains("judgeStoppedNote.stringValue = stopped.map(CoachCopy.judgeStopped) ?? \"\""))
        for keyAccess in ["readKey", "typeSafeKeychain", ".value"] {
            XCTAssertFalse(window.contains(keyAccess), "Settings touches key material: \(keyAccess)")
        }
        let copy = try read("App/CoachCopy.swift")
        let body = try XCTUnwrap(copy.components(separatedBy: "static func judgeStopped(_ failure: JudgeFailure) -> String {").dropFirst().first?
            .components(separatedBy: "\n    }\n").first)
        XCTAssertTrue(body.contains("switch failure.kind {"))
        XCTAssertTrue(body.contains("if case .http(let status) = failure"))
        XCTAssertFalse(body.contains("description") || body.contains(".value"), "only the kind and the status code reach the text")
        XCTAssertTrue(try read("App/CoachController.swift").contains("var judgeStopped: JudgeFailure? { previewJudgeStop ?? service?.judgeStopped }"))
    }

    /// Local-only: turning on never waits for or requires a key; a stored key is checked afterwards.
    func testEnablingNeedsNoKey() throws {
        let src = try read("App/CoachController.swift")
        let body = try XCTUnwrap(src.components(separatedBy: "func setEnabled(_ on: Bool").dropFirst().first?
            .components(separatedBy: "func checkStoredKey").first)
        XCTAssertTrue(body.contains("defaults.set(on, forKey: Keys.enabled)"))
        XCTAssertTrue(body.contains("if let service { service.setEnabled(true) } else { makeService() }"))
        XCTAssertFalse(body.contains("readKey"), "enabling doesn't read the key")
        XCTAssertFalse(body.contains("KeyValidator"), "enabling doesn't wait for OpenAI")
        let keys = try read("App/CoachKeyActions.swift")
        XCTAssertFalse(keys.contains("setEnabled(false)"), "removing the key keeps local-only coaching on")
    }

    /// The coach status menu is always in the menu bar (a way in while off) and follows CoachMenu.
    func testStatusMenuIsAlwaysThere() throws {
        let src = try read("App/CoachController.swift")
        XCTAssertTrue(src.contains("showsStatusItem: Bool = true"))
        XCTAssertTrue(src.contains("CoachMenu.items(enabled: enabled, indicator: indicator, gptAvailable: gptAvailable)"))
        for action in ["enableClicked", "skipClicked", "pauseClicked", "resumeClicked", "startClicked", "turnOffClicked"] {
            XCTAssertTrue(src.contains("#selector(\(action)(_:))"), action)
        }
        XCTAssertFalse(try read("App/Controller.swift").contains("showsStatusItem"), "the app keeps the default")
    }

    func testCoachRunsInProcess() throws {
        let kit = Self.swiftDir.appendingPathComponent("Packages/ListenMoreKit/Sources")
        let e = try XCTUnwrap(FileManager.default.enumerator(at: kit, includingPropertiesForKeys: nil))
        let spawn = #"\bProcess\(\)|posix_spawn|NSTask|executableURL|launchPath|\bexecv"#
        var count = 0
        for case let url as URL in e where ["swift", "c", "h"].contains(url.pathExtension) {
            let text = try String(contentsOf: url, encoding: .utf8)
            XCTAssertNil(text.range(of: spawn, options: .regularExpression), "\(url.lastPathComponent) starts a process")
            count += 1
        }
        XCTAssertGreaterThan(count, 30)
        let spec = try read("project.yml")
        XCTAssertFalse(spec.lowercased().contains("python"), "nothing Python ships in the app")
        XCTAssertFalse(spec.contains("dstSubfolderSpec"), "no helper executables copied into the bundle")
    }
}
