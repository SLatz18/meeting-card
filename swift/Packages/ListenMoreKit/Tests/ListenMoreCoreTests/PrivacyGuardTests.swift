import XCTest
import ListenMoreCore

/// Static guard over the coach sources: the package's library targets plus MeetingCard's
/// `App/Coach*.swift`. Audio stays in memory in every mode; text stays in memory unless the user
/// turns on saved transcripts, and then only `TranscriptFile.swift` writes, one file per call in the
/// chosen folder (the runtime tests below check what reaches disk with saving off and on). Nothing
/// content-like is printed or logged, the key is only touched through KeychainStore, public log
/// arguments are counters, enums and booleans, and nothing reads window titles.
final class PrivacyGuardTests: XCTestCase {
    static let packageURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let sourcesURL = packageURL.appendingPathComponent("Sources")
    static let testsURL = packageURL.appendingPathComponent("Tests")
    static let libraryTargets = ["CWebRTCVAD", "ListenMoreCore", "ListenMoreMac"]
    /// MeetingCard's app sources (`swift/App` for the package at `swift/Packages/ListenMoreKit`).
    static let hostAppURL = packageURL.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("App")

    static func exists(_ url: URL) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
    }

    func swiftFiles(in dir: URL, prefix: String = "") throws -> [(String, String)] {
        guard Self.exists(dir) else { return [] }
        let e = try XCTUnwrap(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil))
        return try e.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" && $0.lastPathComponent.hasPrefix(prefix) }
            .map { ($0.lastPathComponent, try String(contentsOf: $0, encoding: .utf8)) }
    }

    func librarySources() throws -> [(String, String)] {
        try Self.libraryTargets.flatMap { try swiftFiles(in: Self.sourcesURL.appendingPathComponent($0)) }
    }

    func appSources() throws -> [(String, String)] {
        try swiftFiles(in: Self.hostAppURL, prefix: "Coach")
    }

    func allSources() throws -> [(String, String)] { try librarySources() + appSources() }

    func testFindsSources() throws {
        XCTAssertGreaterThan(try librarySources().count, 10)
        XCTAssertTrue(Self.exists(Self.hostAppURL), "the app's coach sources must be covered")
        XCTAssertGreaterThan(try appSources().count, 0)
    }

    /// The one source allowed to touch disk: the opt-in saved transcript (text, in the user's folder).
    static let transcriptWriter = "TranscriptFile.swift"

    func testNoDiskWritesOrPersistence() throws {
        // Audio and screen content are never written, by any source.
        let neverAnywhere = ["AVAudioFile(forWriting", "AVAssetWriter", "SCRecordingOutput", "SCScreenshotManager",
                             "NSKeyedArchiver", "fopen(", "createFile(", "FileHandle(forWriting"]
        // Disk writes: only the transcript writer.
        let writerOnly = ["write(to:", "createDirectory(", "removeItem(", "moveItem(", "copyItem(", "setAttributes("]
        for (name, text) in try allSources() {
            for f in neverAnywhere { XCTAssertFalse(text.contains(f), "\(name) contains \(f)") }
            guard name != Self.transcriptWriter else { continue }
            for f in writerOnly { XCTAssertFalse(text.contains(f), "\(name) contains \(f)") }
        }
        // A host app may store coach settings (see testHostDefaultsAreSettingsOnly); the libraries store nothing.
        for (name, text) in try librarySources() { XCTAssertFalse(text.contains("UserDefaults"), name) }
    }

    /// The writer takes text only (no audio type can reach it) and writes the file in place: no
    /// atomic temp copy in another folder.
    func testTranscriptWriterTakesTextAndWritesInPlace() throws {
        let writer = try XCTUnwrap(try librarySources().first { $0.0 == Self.transcriptWriter }).1
        XCTAssertTrue(writer.contains("func write(_ text: String, to url: URL)"))
        for f in ["[Float]", "AVAudio", "pcm", ".atomic", "temporaryDirectory", "NSTemporaryDirectory"] {
            XCTAssertFalse(writer.contains(f), "\(Self.transcriptWriter) contains \(f)")
        }
        XCTAssertEqual(writer.components(separatedBy: "write(to:").count - 1, 1, "one write call")
    }

    /// Caption and transcript code never logs: transcript text and keys stay out of every log.
    func testCaptionAndTranscriptSourcesNeverLog() throws {
        let names: Set<String> = ["Captions.swift", "Transcript.swift", Self.transcriptWriter, "LiveTranscript.swift",
                                  "CoachTranscript.swift", "CoachNotice.swift"]
        let sources = try allSources().filter { names.contains($0.0) }
        XCTAssertGreaterThanOrEqual(sources.count, 4)
        for (name, text) in sources {
            for f in ["Log.", "Logger(", "os_log", "NSLog"] { XCTAssertFalse(text.contains(f), "\(name) contains \(f)") }
        }
    }

    // MARK: runtime: what reaches disk

    func tempRoot() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lm-privacy-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    func everything(under root: URL) throws -> [String] {
        let e = try XCTUnwrap(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        let base = root.resolvingSymlinksInPath().path
        return e.compactMap { ($0 as? URL)?.resolvingSymlinksInPath().path.replacingOccurrences(of: base + "/", with: "") }.sorted()
    }

    /// A synthetic call: partial and final text from both sides, a speaker tag, then the end.
    func runCall(_ live: LiveTranscript) {
        live.callStarted()
        live.receive(.partial(.others, item: "a", text: "alpha"))
        live.receive(.final(.others, text: "Alpha bravo."))
        live.receive(.final(.me, text: "Charlie delta."))
        live.rename(.others, to: "Guest")
        live.callEnded()
    }

    func testSavingOffWritesNothingToDisk() throws {
        let root = try tempRoot()
        let folder = root.appendingPathComponent("Transcripts", isDirectory: true)
        let live = LiveTranscript(settings: .init(captions: true, saving: false, folder: folder, keyUsable: true),
                                  store: FileTranscriptStore())
        runCall(live)
        XCTAssertEqual(try everything(under: root), [], "captions on, saving off: not even the folder is created")
        XCTAssertFalse(try live.deleteTranscript(), "nothing to delete")
    }

    func testSavingOnWritesOnlyTheOneTranscriptFile() throws {
        let root = try tempRoot()
        let folder = root.appendingPathComponent("Transcripts", isDirectory: true)
        let live = LiveTranscript(settings: .init(captions: true, saving: true, folder: folder, keyUsable: true),
                                  store: FileTranscriptStore())
        runCall(live)
        let files = try everything(under: root)
        XCTAssertEqual(files.count, 2, "the folder and one file: \(files)")
        XCTAssertEqual(files.first, "Transcripts")
        let name = try XCTUnwrap(files.last)
        XCTAssertTrue(name.hasPrefix("Transcripts/Call ") && name.hasSuffix(".md"), name)
        let url = root.appendingPathComponent(name)
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("] Guest:** Alpha bravo."))
        XCTAssertTrue(text.contains("] You:** Charlie delta."))
        let perms = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(perms?.intValue, 0o600, "readable by the user only")
        XCTAssertTrue(try live.deleteTranscript())
        XCTAssertEqual(try everything(under: root), ["Transcripts"], "delete removes the file")
    }

    func testNoPrintOrNSLog() throws {
        for (name, text) in try allSources() {
            XCTAssertNil(text.range(of: #"(^|[^A-Za-z.])(print|NSLog|debugPrint|dump)\("#, options: .regularExpression), name)
        }
    }

    func testCoachNeverUsesTheHostFileLog() throws {
        for (name, text) in try swiftFiles(in: Self.hostAppURL, prefix: "Coach") {
            XCTAssertNil(text.range(of: #"\blog\("#, options: .regularExpression), "\(name) writes to the file log")
        }
    }

    func testKeyOnlyFromKeychain() throws {
        for account in ["OPENAI_API_KEY", "TYPESAFE_API_KEY"] {
            for (name, text) in try allSources() where text.contains(account) {
                XCTAssertEqual(name, "KeychainStore.swift", "\(name) mentions \(account)")
            }
        }
        for (name, text) in try allSources() {
            XCTAssertFalse(text.contains("environment[\"OPENAI"), name)
            XCTAssertFalse(text.contains("UserDefaults") && text.lowercased().contains("apikey") && text.contains(".set("),
                           "\(name) may store the key in defaults")
        }
    }

    /// A key's value (OpenAI or TypeSafe) goes only into an Authorization header or the Keychain item.
    func testKeyValuesOnlyReachAuthHeadersOrTheKeychain() throws {
        var uses = 0
        for (name, text) in try librarySources() {
            for line in text.components(separatedBy: "\n") where line.contains("key.value") {
                uses += 1
                XCTAssertTrue(line.contains("\"Bearer \\(key.value)\"") || line.contains("Data(key.value.utf8)"), "\(name): \(line)")
            }
        }
        XCTAssertGreaterThanOrEqual(uses, 5, "realtime, Responses, key check, TypeSafe and the Keychain save")
    }

    func testPublicLogArgumentsAreNotContent() throws {
        let allowed = ["stage", "count", "active", "kind", "code", "isVoiceProcessingEnabled", "reason", "paused",
                       "frames", "cues", "status", "enabled", "indicator", "ducking", "route", "micSource", "voiceProcessing"]
        let re = try NSRegularExpression(pattern: #"\\\(([^)]*)\)?[^)]*, privacy: \.public\)"#)
        for (name, text) in try allSources() {
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let arg = (text as NSString).substring(with: m.range(at: 1))
                XCTAssertTrue(allowed.contains { arg.lowercased().contains($0.lowercased()) }, "\(name): public log of \(arg)")
            }
        }
    }

    /// The coach keeps nothing: no daily summary, history, recap or stats, in memory or on disk.
    func testNoSummaryOrHistory() throws {
        let re = #"(?i)\b(summary|summaries|history|recap|recaps|daily|stats|statistics|journal|archive)\b"#
        for (name, text) in try allSources() {
            // Code and comments only: user-facing copy may promise "no stats, no recaps".
            let code = text.replacingOccurrences(of: #""(?:[^"\\\n]|\\.)*""#, with: "\"\"", options: .regularExpression)
            XCTAssertNil(code.range(of: re, options: .regularExpression), "\(name) mentions a stored-history concept")
        }
    }

    /// A host's only defaults are coach settings, never call data. `coach.cardPosition` is where the
    /// user last dragged the coach card (an offset in points).
    func testHostDefaultsAreSettingsOnly() throws {
        let allowed: Set<String> = ["coach.enabled", "coach.anyApp", "coach.allowlist", "coach.onboarded", "coach.callControls",
                                    "coach.judgeProvider", "coach.cardPosition", "coach.captions", "coach.saveTranscripts",
                                    "coach.transcriptFolder", "coach.transcriptNoticeSeen"]
        let re = try NSRegularExpression(pattern: #""(coach\.[A-Za-z.]+)""#)
        for (name, text) in try swiftFiles(in: Self.hostAppURL, prefix: "Coach") {
            for m in re.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
                let key = (text as NSString).substring(with: m.range(at: 1))
                XCTAssertTrue(allowed.contains(key), "\(name) uses defaults key \(key)")
            }
            XCTAssertFalse(text.contains("overrideURL"), "\(name): the app ships the built-in generic config only")
        }
    }

    /// No eval fixtures, recordings or example transcripts in the package sources or tests: tests
    /// generate their audio (Synthetic.swift) and use content-free tokens for text.
    func testNoDataFixtures() throws {
        let okNames: Set<String> = ["README.md", ".gitignore", "LICENSE"]
        for dir in [Self.sourcesURL, Self.testsURL] {
            let e = try XCTUnwrap(FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil))
            for case let url as URL in e {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
                let ok = ["swift", "c", "h"].contains(url.pathExtension) || okNames.contains(url.lastPathComponent)
                XCTAssertTrue(ok, "unexpected data file \(url.lastPathComponent)")
            }
        }
    }

    /// The call trigger reads Core Audio running state only: nothing reads window titles (which would
    /// also need Screen Recording permission), and the coach service drives the trigger from audio.
    func testTriggerNeverUsesWindowTitles() throws {
        for (name, text) in try allSources() {
            XCTAssertFalse(text.contains("kCGWindowName"), "\(name) reads window titles")
            XCTAssertNil(text.range(of: #"\.windows\b.*\.title|\.title\b.*\.windows"#, options: .regularExpression),
                         "\(name) reads window titles")
        }
        let service = try librarySources().first { $0.0 == "CoachService.swift" }
        let text = try XCTUnwrap(service).1
        XCTAssertTrue(text.contains("AudioActivitySignal("), "CoachService must drive the trigger from Core Audio")
        XCTAssertFalse(text.contains("WindowTitleSignal"), "CoachService must not use window titles")
    }

    // MARK: "Use Zoom/Meet controls" providers

    static let providerFiles = ["CallControls.swift", "CallControlsModel.swift", "CallControlsMac.swift"]

    func providerSources() throws -> [(String, String)] {
        let found = try librarySources().filter { Self.providerFiles.contains($0.0) }
        // ListenMoreMac (and so CallControlsMac.swift) is present on every platform's checkout.
        XCTAssertEqual(Set(found.map(\.0)), Set(Self.providerFiles))
        return found
    }

    /// Code only: comments and doc comments may name what is never read.
    func code(_ text: String) -> String {
        text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    }

    /// The Zoom reader reads menu-item shortcuts and nothing else, except the label of Zoom's one
    /// ⇧⌘A audio toggle, which goes straight into a Bool. No window, title, description, value or
    /// name attribute is read anywhere in the coach.
    func testZoomReaderReadsOnlyShortcutsAndTheAudioToggle() throws {
        let mac = try XCTUnwrap(try providerSources().first { $0.0 == "CallControlsMac.swift" }).1
        let re = try NSRegularExpression(pattern: #"\bkAX[A-Za-z]+"#)
        let used = Set(re.matches(in: code(mac), range: NSRange(code(mac).startIndex..., in: code(mac)))
            .map { (code(mac) as NSString).substring(with: $0.range) })
        XCTAssertEqual(used, ["kAXMenuBarAttribute", "kAXChildrenAttribute", "kAXMenuItemCmdCharAttribute",
                              "kAXMenuItemCmdModifiersAttribute", "kAXTitleAttribute", "kAXPressAction"])
        let titleLines = code(mac).components(separatedBy: "\n").filter { $0.contains("kAXTitleAttribute") }
        XCTAssertEqual(titleLines.count, 1, "one label read")
        XCTAssertTrue(titleLines.first?.contains(".flatMap(ZoomControlsReader.offersUnmute(label:))") == true,
                      "the label becomes a Bool at once")
        let callers = code(mac).components(separatedBy: "\n").filter { $0.contains("audioToggleOffersUnmute(") && !$0.contains("func ") }
        XCTAssertEqual(callers.count, 1)
        XCTAssertTrue(callers.first?.contains("if s.matches(key: toggle.key, modifiers: toggle.modifiers)") == true,
                      "only the ⇧⌘A item's label is read")

        let banned = [#"kAX(Windows|MainWindow|FocusedWindow|Description|Value|Document|URL|Help|SelectedText|PlaceholderValue|Identifier|Label)"#,
                      #""AX(Title|Description|Value|Identifier|Windows|URL|Document|Help|SelectedText)""#]
        for (name, text) in try allSources() {
            for b in banned { XCTAssertNil(code(text).range(of: b, options: .regularExpression), "\(name) reads \(b)") }
            if name != "CallControlsMac.swift" { XCTAssertFalse(code(text).contains("kAXTitleAttribute"), "\(name) reads a title") }
        }
    }

    /// The Meet reader's AppleScript asks the browser for Meet-host tab URLs only (filtered in the
    /// browser) and returns a count; titles and other tab properties are never asked for, and the
    /// runner reads only the integer result.
    func testMeetReaderReadsOnlyMeetHostURLs() throws {
        let sources = try providerSources()
        let core = try XCTUnwrap(sources.first { $0.0 == "CallControls.swift" }).1
        let urlReads = core.components(separatedBy: "\n").filter { $0.contains("URL of") }
        XCTAssertEqual(urlReads.count, 1, "one URL read in the scripts")
        XCTAssertTrue(urlReads.first?.contains(#"whose URL starts with \"\(meetPrefix)\""#) == true)
        XCTAssertTrue(core.contains(#"public static let meetPrefix = "https://meet.google.com/""#))
        for banned in ["title of", "name of", "properties of", "active tab", "execute javascript", "every tab"] {
            XCTAssertFalse(core.lowercased().contains(banned), "the Meet script asks for \(banned)")
        }
        let mac = try XCTUnwrap(sources.first { $0.0 == "CallControlsMac.swift" }).1
        XCTAssertTrue(mac.contains("result.int32Value"))
        for banned in ["stringValue", "coerce(", "descriptor(at"] {
            XCTAssertFalse(code(mac).contains(banned), "the runner reads \(banned) from a script result")
        }
    }

    /// The Mute action is one Accessibility press on Zoom's own ⇧⌘A item, located by shortcut (no
    /// label read), reached only through ZoomControlsReader.toggleMute and the model. No synthesized
    /// input anywhere in the readers or actions, and Mute never touches the coach's own capture.
    func testMuteIsOneAccessibilityPressNoSynthesizedInput() throws {
        let sources = try providerSources()
        for (name, text) in sources {
            for banned in ["cgevent", "keyboard", "keystroke", "nsevent", "iohid", "postevent", "cgpost", "sendevent"] {
                XCTAssertFalse(text.lowercased().contains(banned), "\(name) mentions \(banned)")
            }
        }
        for (name, text) in try allSources() where name != "CallControlsMac.swift" {
            XCTAssertFalse(code(text).contains("AXUIElementPerformAction"), "\(name) performs an Accessibility action")
            XCTAssertFalse(code(text).contains("CGEvent"), "\(name) synthesizes input")
        }
        let mac = code(try XCTUnwrap(sources.first { $0.0 == "CallControlsMac.swift" }).1)
        let actions = mac.components(separatedBy: "\n").filter { $0.contains("AXUIElementPerformAction") }
        XCTAssertEqual(actions.count, 1, "one action call site")
        XCTAssertTrue(actions.first?.contains("AXUIElementPerformAction(item, kAXPressAction as CFString)") == true)
        let press = try XCTUnwrap(mac.components(separatedBy: "public func pressAudioToggle()").dropFirst().first?
            .components(separatedBy: "\n    }\n").first)
        XCTAssertTrue(press.contains("AXUIElementPerformAction"), "the press lives in pressAudioToggle")
        XCTAssertFalse(press.contains("audioToggleOffersUnmute") || press.contains("kAXTitleAttribute"), "pressing reads no label")
        XCTAssertFalse(press.contains("for "), "no loop around the press")

        let core = code(try XCTUnwrap(sources.first { $0.0 == "CallControls.swift" }).1)
        let model = code(try XCTUnwrap(sources.first { $0.0 == "CallControlsModel.swift" }).1)
        XCTAssertEqual(core.components(separatedBy: "ax.pressAudioToggle()").count - 1, 1, "pressed only from toggleMute")
        XCTAssertEqual(model.components(separatedBy: "zoom.toggleMute()").count - 1, 1, "one press per model call")
        for (name, text) in try allSources() where !["CallControls.swift", "CallControlsModel.swift"].contains(name) {
            XCTAssertFalse(code(text).contains(".pressAudioToggle()"), "\(name) presses directly")
        }
        for banned in ["setPaused", "stopManual", "stopCapture", "MicSource", "CallSource", "CoachSession"] {
            XCTAssertFalse(model.contains(banned), "Mute must never work by stopping the coach's own capture (\(banned))")
        }
    }

    /// The call's window is picked from what CGWindowList says without titles (number, owner, layer,
    /// on-screen, bounds) and from when the window appeared, or from the Meet script's window count:
    /// never the largest, first or frontmost window, and no Accessibility window reads.
    func testCallWindowSelectionRule() throws {
        let files = ["CallWindows.swift", "CallDisplay.swift", "CallDisplayLocator.swift"]
        let sources = try librarySources().filter { files.contains($0.0) }
        XCTAssertEqual(Set(sources.map(\.0)), Set(files))
        let locator = code(try XCTUnwrap(sources.first { $0.0 == "CallDisplayLocator.swift" }).1)
        let re = try NSRegularExpression(pattern: #"\bkCGWindow[A-Za-z]+"#)
        let keys = Set(re.matches(in: locator, range: NSRange(locator.startIndex..., in: locator))
            .map { (locator as NSString).substring(with: $0.range) })
        XCTAssertEqual(keys, ["kCGWindowOwnerPID", "kCGWindowNumber", "kCGWindowLayer", "kCGWindowBounds", "kCGWindowIsOnscreen"])
        for (name, text) in sources {
            for banned in ["kCGWindowName", "kCGWindowOwnerName", "frontmost", "mainWindow", "keyWindow", "isActive",
                           "kAXFocusedWindow", "kAXMainWindow", "kAXWindows", "AXUIElement"] {
                XCTAssertFalse(code(text).contains(banned), "\(name) selects by \(banned)")
            }
        }
        let selector = code(try XCTUnwrap(sources.first { $0.0 == "CallWindows.swift" }).1)
        XCTAssertFalse(selector.contains("max(by:") || selector.contains("width * "), "never the largest window")
        XCTAssertTrue(selector.contains("firstSeen"), "chosen by when the window appeared")
        let display = code(try XCTUnwrap(sources.first { $0.0 == "CallDisplay.swift" }).1)
        XCTAssertFalse(display.contains("appKey") || display.contains("WindowInfo"), "CallDisplay no longer picks an app's window")
        for (name, text) in try allSources() where name != "CallDisplayLocator.swift" {
            XCTAssertFalse(code(text).contains("CGWindowListCopyWindowInfo"), "\(name) reads the window list")
        }
        // The binding reaches the glow (and, through `glowScreen`, the coach card) only via `locateScreen`;
        // the Mac tests (`CoachServiceTests`) drive that path from a fake window list.
        let service = code(try XCTUnwrap(try allSources().first { $0.0 == "CoachService.swift" }).1)
        XCTAssertTrue(service.contains("callWindows.target(appKey: appKey)"), "locateScreen is the call window binding")
        XCTAssertTrue(service.contains("let screen = self.locateScreen(self.session.session?.appKey, self.fallbackScreen())"),
                      "the glow's placement asks locateScreen")
    }

    /// Nothing the providers see is logged, printed or kept beyond the call states.
    func testCallControlsNeverLog() throws {
        for (name, text) in try providerSources() {
            for banned in ["Log.", "Logger(", "os_log", "NSLog", "UserDefaults"] {
                XCTAssertFalse(code(text).contains(banned), "\(name) uses \(banned)")
            }
        }
    }

    /// Accessibility and Automation prompts come only from the request functions, which the host
    /// calls only from the Settings toggle and its Request access button.
    func testPermissionPromptsOnlyFromTheToggle() throws {
        for (name, text) in try allSources() {
            let c = code(text)
            if c.contains("AXTrustedCheckOptionPrompt") || c.contains("ask: true") {
                XCTAssertEqual(name, "CallControlsMac.swift", "\(name) prompts")
            }
        }
        let mac = try XCTUnwrap(try providerSources().first { $0.0 == "CallControlsMac.swift" }).1
        XCTAssertEqual(code(mac).components(separatedBy: "ask: true").count - 1, 1)
        XCTAssertEqual(code(mac).components(separatedBy: "ask: false").count - 1, 1, "readers check without asking")
        guard let controller = try appSources().first(where: { $0.0 == "CoachController.swift" })?.1 else { return }
        let calls = code(controller).components(separatedBy: "\n").filter { $0.contains("requestCallControlsAccess()") && !$0.contains("func ") }
        XCTAssertEqual(calls.map { $0.trimmingCharacters(in: .whitespaces) }, ["if on { requestCallControlsAccess() }"])
        for (name, text) in try appSources() where name != "CoachController.swift" {
            for c in code(text).components(separatedBy: "\n") where c.contains("requestCallControlsAccess()") {
                XCTAssertEqual(name, "CoachSettingsWindow.swift", "\(name) asks for call-control permissions")
            }
            XCTAssertFalse(code(text).contains("CallControlsPermissions.request"), "\(name) prompts directly")
        }
    }

    /// Library sources and tests are generic: this is a public repository.
    func testNoSecretsOrPersonalReferences() throws {
        let banned = [#"sk-[A-Za-z0-9]{20,}"#, #"(?i)\bscott\b"#, #"(?i)\bCTO\b"#, #"(?i)VP Comms"#, #"(?i)plaud"#]
        let tests = try ["ListenMoreCoreTests", "ListenMoreMacTests", "ListenMoreLiveTests"]
            .flatMap { try swiftFiles(in: Self.testsURL.appendingPathComponent($0)) }
        for (name, text) in try librarySources() + tests where name != "PrivacyGuardTests.swift" {
            for b in banned { XCTAssertNil(text.range(of: b, options: .regularExpression), "\(name) matches \(b)") }
        }
        for (name, text) in try appSources() {
            XCTAssertNil(text.range(of: banned[0], options: .regularExpression), "\(name) matches a key pattern")
        }
    }
}
