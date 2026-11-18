import Foundation
import XCTest
@testable import ListenMoreCore

/// "Use Zoom/Meet controls" with fake Accessibility and AppleScript backends: Zoom and Meet report
/// started and ended (the coach stops about 3 s after the call ends, not 30 s), Zoom's mute holds
/// capture until unmute, and a denied, revoked or unsupported backend falls back to Core Audio.
final class CallControlsTests: XCTestCase {
    // MARK: fakes

    final class FakeZoomAX: ZoomAccessibility {
        var isTrusted = true
        var isRunning = true
        var items: [MenuShortcut]? = []
        var reads = 0
        var presses = 0
        var pressFails = false

        func menuShortcuts() -> [MenuShortcut]? {
            reads += 1
            return items
        }

        /// Like Zoom: pressing ⇧⌘A flips what the item offers (Mute audio <-> Unmute audio).
        func pressAudioToggle() -> AudioTogglePress {
            presses += 1
            guard var list = items, let i = list.firstIndex(where: { $0.matches(key: "A", modifiers: MenuShortcut.shift) }) else {
                return .noItem
            }
            if pressFails { return .failed }
            list[i].offersUnmute = !(list[i].offersUnmute ?? false)
            items = list
            return .pressed
        }

        /// The Meeting menu while in a meeting: ⇧⌘A (offering Mute or Unmute), ⇧⌘V, plus everyday items.
        func inMeeting(muted: Bool? = false) {
            items = [MenuShortcut(key: "A", modifiers: MenuShortcut.shift, offersUnmute: muted),
                     MenuShortcut(key: "V", modifiers: MenuShortcut.shift), MenuShortcut(key: "C", modifiers: 0)]
        }

        /// The home window's menus: no in-meeting shortcuts (⌘A Select All, ⌥⇧⌘V Paste and Match Style).
        func home() {
            items = [MenuShortcut(key: "A", modifiers: 0), MenuShortcut(key: "V", modifiers: 3), MenuShortcut(key: "Q", modifiers: 0)]
        }
    }

    final class FakeScripts: AppleScriptRunner {
        var permissions: [String: AutomationPermission] = [:]
        /// Meet meeting tabs per bundle ID (what the browser-side script would count).
        var meetTabs: [String: Int] = [:]
        /// Error numbers per bundle ID, for every script, or for scripts containing a marker.
        var failures: [String: Int] = [:]
        var failuresWhenContaining: [String: (marker: String, code: Int)] = [:]
        /// The script's whole integer (count, window rank and visible windows; `MeetScript.decode`).
        var raw: [String: Int] = [:]
        private(set) var runs: [(bundleId: String, source: String)] = []

        func permission(bundleId: String) -> AutomationPermission { permissions[bundleId] ?? .granted }

        func run(_ source: String, bundleId: String) -> ScriptOutcome {
            runs.append((bundleId, source))
            if let code = failures[bundleId] { return .failed(code: code) }
            if let f = failuresWhenContaining[bundleId], source.contains(f.marker) { return .failed(code: f.code) }
            return .count(raw[bundleId] ?? meetTabs[bundleId] ?? 0)
        }
    }

    final class FakeAudioState: AudioStateProvider {
        var processes: [AudioProcessState] = []
        func snapshot() -> AudioStateSnapshot { AudioStateSnapshot(defaultInputRunning: true, processes: processes) }
        func live(_ bundles: String...) {
            processes = bundles.enumerated().map { AudioProcessState(pid: Int32(100 + $0.offset), bundleId: $0.element,
                                                                     isRunningInput: true, isRunningOutput: true) }
        }
    }

    static let chrome = "com.google.Chrome"
    static let dia = "company.thebrowser.dia"
    static let zoom = "us.zoom.xos"

    var config: ListenMoreConfig!
    var ax: FakeZoomAX!
    var scripts: FakeScripts!
    var audio: FakeAudioState!
    var provider: CallControlsProvider!
    var monitor: CoachMonitor!
    var clock = 0.0

    override func setUpWithError() throws {
        config = try TestConfig.load()
        ax = FakeZoomAX()
        scripts = FakeScripts()
        audio = FakeAudioState()
        provider = CallControlsProvider(readers: [ZoomControlsReader(ax: ax), MeetTabReader.chrome(runner: scripts),
                                                  MeetTabReader.dia(runner: scripts)],
                                        endedHoldS: config.trigger.stopAfterS, clock: { [unowned self] in self.clock })
        provider.isEnabled = true
        let settings = TriggerSettings(config: config, anyApp: false, ownPid: 4242, ownBundleId: "com.example.hostapp")
        monitor = CoachMonitor(provider: audio, trigger: CoachTrigger(settings: settings, enabled: true), callState: provider)
    }

    /// Polls every 0.5 s from `from` to `to` (inclusive), the provider reading on the same clock.
    @discardableResult
    func run(_ from: Double, _ to: Double) -> [(Double, TriggerAction)] {
        var out: [(Double, TriggerAction)] = []
        var t = from
        while t <= to + 1e-9 {
            clock = t
            out += monitor.poll(now: t).map { (t, $0) }
            t += 0.5
        }
        return out
    }

    func starts(_ a: [(Double, TriggerAction)]) -> [Double] {
        a.compactMap { if case .start = $0.1 { return $0.0 } else { return nil } }
    }

    func stops(_ a: [(Double, TriggerAction)]) -> [(Double, CoachStopReason)] {
        a.compactMap { if case .stop(let r) = $0.1 { return ($0.0, r) } else { return nil } }
    }

    func pauses(_ a: [(Double, TriggerAction)]) -> [(Double, Bool)] {
        a.compactMap { if case .pause(let p) = $0.1 { return ($0.0, p) } else { return nil } }
    }

    // MARK: Zoom

    func testZoomMeetingStartsAndLeavingStopsInAboutThreeSeconds() throws {
        ax.inMeeting()
        audio.live(Self.zoom)
        XCTAssertEqual(starts(run(0, 5)), [3], "Core Audio still starts the session")
        XCTAssertEqual(provider.callStates()[Self.zoom], .started)
        ax.home()                                           // Leave: the in-meeting shortcuts go away
        let stop = try XCTUnwrap(stops(run(10, 40)).first)
        XCTAssertEqual(stop.1, .callEnded)
        XCTAssertEqual(stop.0, 13, accuracy: 1e-9, "about 3 s after leaving, while Zoom still holds its devices")
    }

    func testZoomQuittingCountsAsEnded() throws {
        ax.inMeeting()
        audio.live(Self.zoom)
        run(0, 5)
        ax.isRunning = false
        XCTAssertEqual(try XCTUnwrap(stops(run(5.5, 20)).first).0, 8.5, accuracy: 1e-9)
    }

    func testZoomHomeWindowShortcutsAreNotAMeeting() {
        ax.home()
        XCTAssertEqual(ZoomControlsReader(ax: ax).read(), .noCall)
        ax.items = [MenuShortcut(key: "v", modifiers: MenuShortcut.shift)]
        XCTAssertEqual(ZoomControlsReader(ax: ax).read(), .inCall(muted: nil), "⇧⌘V alone (audio not joined) is a meeting")
    }

    func testZoomMutePausesCaptureAndUnmuteResumes() {
        ax.inMeeting(muted: false)
        audio.live(Self.zoom)
        run(0, 5)
        XCTAssertTrue(monitor.trigger.isCapturing)
        ax.inMeeting(muted: true)
        XCTAssertEqual(pauses(run(5.5, 5.5)).map(\.1), [true], "mute holds capture on the next poll")
        XCTAssertFalse(monitor.trigger.isCapturing)
        XCTAssertEqual(monitor.trigger.indicator, .muted)
        XCTAssertTrue(stops(run(6, 60)).isEmpty, "muted never ends the session")
        ax.inMeeting(muted: false)
        XCTAssertEqual(pauses(run(60.5, 60.5)).map(\.1), [false])
        XCTAssertTrue(monitor.trigger.isCapturing)
        XCTAssertEqual(monitor.trigger.indicator, .listening)
    }

    func testUserPauseOutlastsUnmute() {
        ax.inMeeting(muted: true)
        audio.live(Self.zoom)
        XCTAssertEqual(starts(run(0, 5)), [3])
        XCTAssertTrue(monitor.trigger.session?.muted == true, "a session can start muted")
        XCTAssertFalse(monitor.trigger.isCapturing)
        XCTAssertEqual(monitor.trigger.setPaused(true), [.pause(true)])
        XCTAssertEqual(monitor.trigger.indicator, .paused, "the user's pause shows over the mute")
        ax.inMeeting(muted: false)
        XCTAssertTrue(pauses(run(5.5, 10)).isEmpty, "unmute doesn't undo the user's pause")
        XCTAssertFalse(monitor.trigger.isCapturing)
        ax.inMeeting(muted: true)
        run(10.5, 10.5)
        XCTAssertEqual(monitor.trigger.setPaused(false), [.pause(true)], "Resume while muted stays held")
        XCTAssertEqual(monitor.trigger.indicator, .muted)
    }

    func testZoomLabelOnlyTellsMuteState() {
        XCTAssertEqual(ZoomControlsReader.offersUnmute(label: "Unmute audio"), true)
        XCTAssertEqual(ZoomControlsReader.offersUnmute(label: "Unmute Telephone"), true)
        XCTAssertEqual(ZoomControlsReader.offersUnmute(label: "Mute Audio"), false)
        XCTAssertNil(ZoomControlsReader.offersUnmute(label: "Audio stummschalten"), "other languages: unknown, never muted")
    }

    // MARK: Meet

    func testMeetTabInChromeStartsAndClosingItStopsInAboutThreeSeconds() throws {
        scripts.meetTabs[Self.chrome] = 1
        audio.live("com.google.Chrome.helper")
        XCTAssertEqual(starts(run(0, 5)), [3])
        XCTAssertEqual(provider.callStates()["com.google.chrome"], .started, "Meet's mute isn't readable, so never muted")
        scripts.meetTabs[Self.chrome] = 0
        let stop = try XCTUnwrap(stops(run(10, 40)).first)
        XCTAssertEqual(stop.1, .callEnded)
        XCTAssertEqual(stop.0, 13, accuracy: 1e-9)
    }

    func testMeetInDiaWalksSpaces() throws {
        scripts.meetTabs[Self.dia] = 2
        audio.live(Self.dia)
        run(0, 5)
        XCTAssertEqual(provider.callStates()[Self.dia], .started)
        XCTAssertTrue(scripts.runs.contains { $0.bundleId == Self.dia && $0.source.contains("profiles of w") })
        scripts.meetTabs[Self.dia] = 0
        XCTAssertEqual(try XCTUnwrap(stops(run(10, 40)).first).0, 13, accuracy: 1e-9)
    }

    func testDiaWithoutSpacesUsesWindowTabs() {
        scripts.failuresWhenContaining[Self.dia] = ("profiles of w", -2741)
        scripts.meetTabs[Self.dia] = 1
        let reader = MeetTabReader.dia(runner: scripts)
        XCTAssertEqual(reader.read(), .inCall(muted: nil))
        XCTAssertEqual(reader.read(), .inCall(muted: nil))
        XCTAssertEqual(scripts.runs.filter { $0.source.contains("profiles of w") }.count, 1, "the working script is remembered")
    }

    func testDiaUnsupportedFallsBackToCoreAudio() throws {
        scripts.failures[Self.dia] = -1708                  // no tab URLs through scripting
        scripts.meetTabs[Self.chrome] = 1
        audio.live(Self.dia)
        XCTAssertEqual(starts(run(0, 5)), [3], "Core Audio starts Dia as before")
        XCTAssertNil(provider.callStates()[Self.dia])
        XCTAssertEqual(provider.issues[Self.dia], .unsupported)
        XCTAssertEqual(provider.callStates()["com.google.chrome"], .started, "Chrome is unaffected")
        audio.live()
        let stop = try XCTUnwrap(stops(run(10, 60)).first)
        XCTAssertEqual(stop.1, .audioEnded)
        XCTAssertEqual(stop.0, 40, accuracy: 1e-9, "Core Audio's 30 s stop")
    }

    func testBrowserNotRunningIsNoCallAndNeverScripted() {
        scripts.permissions[Self.chrome] = .notRunning
        XCTAssertEqual(MeetTabReader.chrome(runner: scripts).read(), .noCall)
        XCTAssertTrue(scripts.runs.isEmpty, "no Apple Event to an app that isn't running (it would launch)")
        scripts.permissions[Self.chrome] = .granted
        scripts.failures[Self.chrome] = MeetScript.notRunning
        XCTAssertEqual(MeetTabReader.chrome(runner: scripts).read(), .noCall, "quit mid-read")
    }

    func testMeetURLMatcher() {
        for u in ["https://meet.google.com/abc-defg-hij", "https://meet.google.com/abc-defg-hij?authuser=1",
                  "https://meet.google.com/abc-defg-hij#x", "https://meet.google.com/abc-defg-hij/", "HTTPS://MEET.GOOGLE.COM/ABC-DEFG-HIJ"] {
            XCTAssertTrue(MeetScript.isMeetingURL(u), u)
        }
        for u in ["https://meet.google.com/", "https://meet.google.com/landing", "https://meet.google.com/abc-defg-hijk",
                  "https://meet.google.com/abc-defg-hi", "https://meet.google.com/abcdefghijkl", "https://meet.google.com/ab1-defg-hij",
                  "https://example.com/abc-defg-hij", "http://meet.google.com/abc-defg-hij", "https://meet.google.com.example.com/abc-defg-hij"] {
            XCTAssertFalse(MeetScript.isMeetingURL(u), u)
        }
    }

    // MARK: permissions and fallback

    func testPermissionDeniedFallsBackToCoreAudio() throws {
        ax.isTrusted = false
        ax.inMeeting()
        scripts.permissions[Self.chrome] = .denied
        scripts.permissions[Self.dia] = .notAsked
        audio.live(Self.zoom)
        run(0, 5)
        XCTAssertTrue(provider.callStates().isEmpty)
        XCTAssertEqual(provider.issues, [Self.zoom: .accessibilityDenied, "com.google.chrome": .automationDenied, Self.dia: .automationNotAsked])
        XCTAssertEqual(ax.reads, 0, "no Accessibility reads without trust")
        XCTAssertTrue(scripts.runs.isEmpty, "no Apple Events without consent; nothing prompts")
        ax.home()
        audio.live()
        let stop = try XCTUnwrap(stops(run(10, 60)).first)
        XCTAssertEqual(stop.1, .audioEnded)
        XCTAssertEqual(stop.0, 40, accuracy: 1e-9)
    }

    func testRevokedMidCallFallsBackSilently() throws {
        ax.inMeeting()
        audio.live(Self.zoom)
        run(0, 5)
        ax.isTrusted = false
        ax.home()
        XCTAssertTrue(stops(run(5.5, 30)).isEmpty, "a revoked permission doesn't read as ended")
        XCTAssertNil(provider.callStates()[Self.zoom])
        audio.live()
        XCTAssertEqual(try XCTUnwrap(stops(run(30.5, 70)).first).0, 60.5, accuracy: 1e-9)
    }

    func testAutomationRevokedDuringAReadIsDenied() {
        scripts.failures[Self.chrome] = MeetScript.notPermitted
        XCTAssertEqual(MeetTabReader.chrome(runner: scripts).read(), .unavailable(.automationDenied))
    }

    func testOffReadsNothingAndReportsNothing() {
        provider.isEnabled = false
        ax.inMeeting()
        scripts.meetTabs[Self.chrome] = 1
        audio.live(Self.zoom)
        run(0, 10)
        XCTAssertEqual(ax.reads, 0)
        XCTAssertTrue(scripts.runs.isEmpty)
        XCTAssertTrue(provider.callStates().isEmpty)
    }

    func testEndedIsHeldThenDropped() {
        var t = CallStateTracker(endedHoldS: 30)
        t.observe("a", .noCall, now: 0)
        XCTAssertNil(t.states["a"], "never seen in a call: nothing to end")
        t.observe("a", .inCall(muted: nil), now: 1)
        t.observe("a", .noCall, now: 2)
        XCTAssertEqual(t.states["a"], .ended)
        t.observe("a", .noCall, now: 31.5)
        XCTAssertEqual(t.states["a"], .ended)
        t.observe("a", .noCall, now: 32)
        XCTAssertNil(t.states["a"], "after the hold Core Audio decides")
        t.observe("a", .inCall(muted: true), now: 33)
        XCTAssertEqual(t.states["a"], .muted)
        t.observe("a", .unavailable(.readFailed), now: 34)
        t.observe("a", .noCall, now: 35)
        XCTAssertNil(t.states["a"], "a failed read never turns into ended")
    }

    func testBackgroundQueueNeverBlocksTheCaller() {
        let q = DispatchQueue(label: "test.callcontrols")
        ax.inMeeting()
        let p = CallControlsProvider(readers: [ZoomControlsReader(ax: ax)], endedHoldS: 30, queue: q, clock: { 0 })
        p.isEnabled = true
        XCTAssertTrue(p.callStates().isEmpty, "the first call returns at once, before any reading")
        q.sync {}
        XCTAssertEqual(p.callStates()[Self.zoom], .started)
    }

    // MARK: what the scripts read

    func testScriptsReadOnlyMeetHostTabURLs() {
        for reader in [MeetTabReader.chrome(runner: scripts), MeetTabReader.dia(runner: scripts)] {
            for source in reader.scripts {
                let lines = source.components(separatedBy: "\n")
                let urlReads = lines.filter { $0.contains("URL of") }
                XCTAssertFalse(urlReads.isEmpty)
                for line in urlReads {
                    XCTAssertTrue(line.contains("whose URL starts with \"https://meet.google.com/\")"), line)
                }
                for banned in ["title", "name of", "properties", "active tab", "execute", "javascript", "source", "text of"] {
                    XCTAssertFalse(source.lowercased().contains(banned), "\(reader.bundleId) script reads \(banned)")
                }
                XCTAssertTrue(source.contains("is not running then return 0"), "never launches the browser")
                XCTAssertTrue(source.contains("return n"), "returns a count only")
            }
        }
    }

    // MARK: Mute action (CallControlsModel)

    func makeModel(session: String? = nil) -> (CallControlsModel, () -> Int) {
        var changes = 0
        let model = CallControlsModel(provider: provider, sessionAppKey: { session }, deliver: { $0() })
        model.onChange = { changes += 1 }
        return (model, { changes })
    }

    func testOnePressPerCallAndTheStateIsReadBack() {
        ax.inMeeting(muted: false)
        _ = provider.callStates()
        let (model, changes) = makeModel(session: Self.zoom)
        XCTAssertTrue(model.canMute)
        XCTAssertNil(model.muteUnavailableReason)
        XCTAssertFalse(model.isMuted)
        XCTAssertEqual(model.toggleMute(), .requested)
        XCTAssertEqual(ax.presses, 1, "exactly one press")
        XCTAssertTrue(model.isMuted, "Zoom's own reading, refreshed after the press")
        XCTAssertEqual(model.lastResult, .pressed)
        XCTAssertEqual(changes(), 1)
        XCTAssertEqual(model.toggleMute(), .requested)
        XCTAssertEqual(ax.presses, 2, "one more press for one more call")
        XCTAssertFalse(model.isMuted)
    }

    func testFailedPressIsReported() {
        ax.inMeeting(muted: false)
        ax.pressFails = true
        _ = provider.callStates()
        let (model, _) = makeModel()
        model.toggleMute()
        XCTAssertEqual(ax.presses, 1)
        XCTAssertEqual(model.lastResult, .failed)
        XCTAssertFalse(model.isMuted)
    }

    func testToggleOffIsANoOp() {
        ax.inMeeting()
        provider.isEnabled = false
        let (model, changes) = makeModel(session: Self.zoom)
        XCTAssertFalse(model.canMute)
        XCTAssertEqual(model.muteUnavailableReason, .toggleOff)
        XCTAssertEqual(model.toggleMute(), .unavailable(.toggleOff))
        XCTAssertEqual(ax.presses, 0)
        XCTAssertEqual(ax.reads, 0, "off reads nothing")
        XCTAssertEqual(changes(), 0)
    }

    func testPermissionDeniedIsANoOp() {
        ax.inMeeting()
        ax.isTrusted = false
        _ = provider.callStates()
        let (model, _) = makeModel(session: Self.zoom)
        XCTAssertEqual(model.muteUnavailableReason, .permissionDenied)
        XCTAssertEqual(model.toggleMute(), .unavailable(.permissionDenied))
        XCTAssertEqual(ax.presses, 0)
        XCTAssertEqual(ZoomControlsReader(ax: ax).toggleMute(), .unavailable(.permissionDenied), "the reader checks again")
        XCTAssertEqual(ax.presses, 0)
    }

    func testNoZoomCallIsANoOp() {
        ax.home()
        _ = provider.callStates()
        let (model, _) = makeModel()
        XCTAssertEqual(model.muteUnavailableReason, .noZoomCall)
        XCTAssertEqual(model.toggleMute(), .unavailable(.noZoomCall))
        ax.isRunning = false
        XCTAssertEqual(ZoomControlsReader(ax: ax).toggleMute(), .unavailable(.noZoomCall))
        XCTAssertEqual(ax.presses, 0)
    }

    func testMeetCannotMuteAndCaptureIsUntouched() {
        scripts.meetTabs[Self.chrome] = 1
        audio.live("com.google.Chrome.helper")
        run(0, 5)
        XCTAssertTrue(monitor.trigger.isCapturing)
        let (model, _) = makeModel(session: monitor.trigger.session?.appKey)
        XCTAssertFalse(model.canMute)
        XCTAssertEqual(model.muteUnavailableReason, .meet, "the UI shows Mute from Meet")
        XCTAssertEqual(model.toggleMute(), .unavailable(.meet))
        XCTAssertEqual(ax.presses, 0)
        XCTAssertTrue(monitor.trigger.isCapturing, "never mutes by stopping the coach's own capture")
        XCTAssertFalse(model.isMuted)
        let (noSession, _) = makeModel()
        XCTAssertEqual(noSession.muteUnavailableReason, .meet, "a Meet tab alone also means Mute from Meet")
    }

    func testPressRunsOnTheProviderQueue() {
        let q = DispatchQueue(label: "test.callcontrols.press")
        ax.inMeeting(muted: false)
        let p = CallControlsProvider(readers: [ZoomControlsReader(ax: ax)], endedHoldS: 30, queue: q, clock: { 0 })
        p.isEnabled = true
        _ = p.callStates()
        q.sync {}
        let model = CallControlsModel(provider: p, deliver: { $0() })
        XCTAssertEqual(model.toggleMute(), .requested)
        q.sync {}
        XCTAssertEqual(ax.presses, 1)
        XCTAssertTrue(model.isMuted)
    }

    // MARK: the call's window

    func testZoomHomeWindowInFrontNeverReadsAsEnded() throws {
        var present: Bool? = true
        let reader = try XCTUnwrap(provider.readers.first as? ZoomControlsReader)
        reader.callWindowPresent = { present }
        ax.inMeeting(muted: true)
        audio.live(Self.zoom)
        run(0, 5)
        XCTAssertEqual(provider.callStates()[Self.zoom], .muted)
        ax.home()                                  // the menu bar follows the home window in front
        XCTAssertTrue(stops(run(5.5, 30)).isEmpty, "the meeting window is still there: not ended")
        XCTAssertEqual(provider.callStates()[Self.zoom], .muted, "the last mute reading holds")
        present = nil                              // the meeting window closed (Leave)
        XCTAssertEqual(try XCTUnwrap(stops(run(30.5, 40)).first).0, 33.5, accuracy: 1e-9)
    }

    /// With the home window in front the coach keeps listening on the held reading, but Zoom has no
    /// ⇧⌘A item to press: Mute in Zoom must not look usable (#26: it shows only when it can act).
    func testMuteInZoomIsNotActionableOnAHeldReading() throws {
        let reader = try XCTUnwrap(provider.readers.first as? ZoomControlsReader)
        reader.callWindowPresent = { true }
        ax.inMeeting(muted: true)
        _ = provider.callStates()
        let (model, _) = makeModel(session: Self.zoom)
        XCTAssertNil(model.muteUnavailableReason, "in the meeting window: Mute can act")
        XCTAssertFalse(reader.isHeld)
        ax.home()
        _ = provider.callStates()
        XCTAssertEqual(provider.currentStates[Self.zoom], .muted, "the coach still reads the call as on, muted")
        XCTAssertTrue(reader.isHeld)
        XCTAssertTrue(model.isMuted, "the held mute reading still shows")
        XCTAssertEqual(model.muteUnavailableReason, .noZoomCall)
        XCTAssertFalse(model.canMute)
        XCTAssertEqual(model.toggleMute(), .unavailable(.noZoomCall))
        XCTAssertEqual(ax.presses, 0, "no press is attempted without the ⇧⌘A item")
        ax.inMeeting(muted: true)                  // the meeting window is back in front
        _ = provider.callStates()
        XCTAssertFalse(reader.isHeld)
        XCTAssertNil(model.muteUnavailableReason)
    }

    func testHeldReadingEndsWhenTheWindowOrAccessIsGone() throws {
        let reader = try XCTUnwrap(provider.readers.first as? ZoomControlsReader)
        var present: Bool? = true
        reader.callWindowPresent = { present }
        ax.inMeeting()
        _ = reader.read()
        ax.home()
        XCTAssertEqual(reader.read(), .inCall(muted: false))
        XCTAssertTrue(reader.isHeld)
        present = nil
        XCTAssertEqual(reader.read(), .noCall)
        XCTAssertFalse(reader.isHeld)
        present = true
        XCTAssertEqual(reader.read(), .inCall(muted: nil), "the muted reading went with the window")
        ax.isRunning = false
        XCTAssertEqual(reader.read(), .noCall)
        XCTAssertFalse(reader.isHeld)
    }

    /// Turning "Use Zoom/Meet controls" off and on starts from nothing: the held mute reading and
    /// the held mark don't survive it.
    func testHeldMuteReadingIsClearedWhenTheProviderResets() throws {
        let reader = try XCTUnwrap(provider.readers.first as? ZoomControlsReader)
        reader.callWindowPresent = { true }
        ax.inMeeting(muted: true)
        _ = provider.callStates()
        ax.home()
        _ = provider.callStates()
        XCTAssertEqual(provider.currentStates[Self.zoom], .muted)
        XCTAssertTrue(reader.isHeld)
        provider.isEnabled = false
        XCTAssertFalse(reader.isHeld)
        provider.isEnabled = true
        _ = provider.callStates()
        XCTAssertEqual(provider.currentStates[Self.zoom], .started, "no stale muted reading after the switch")
    }

    func testZoomWithoutAWindowSignalKeepsTheMenuRule() {
        ax.inMeeting()
        XCTAssertEqual(ZoomControlsReader(ax: ax).read(), .inCall(muted: false))
        ax.home()
        let reader = ZoomControlsReader(ax: ax)
        reader.callWindowPresent = { nil }
        XCTAssertEqual(reader.read(), .noCall, "nothing bound: the menu shortcuts decide as before")
    }

    func testMeetReportsWhichWindowHoldsTheCall() {
        scripts.raw[Self.chrome] = 1 + 1000 * 2 + 1_000_000 * 3
        _ = provider.callStates()
        XCTAssertEqual(provider.callStates()["com.google.chrome"], .started)
        XCTAssertEqual(provider.windowHints["com.google.chrome"], CallWindowHint(rank: 2, visibleWindows: 3))
        scripts.raw[Self.chrome] = 2 + 1_000_000 * 3              // meeting tabs in two windows
        _ = provider.callStates()
        XCTAssertNil(provider.windowHints["com.google.chrome"], "no single window: no hint")
        XCTAssertEqual(provider.callStates()["com.google.chrome"], .started)
        provider.isEnabled = false
        XCTAssertTrue(provider.windowHints.isEmpty)
    }

    func testMeetScriptReadsOnlyMinimizedFromAWindow() throws {
        let re = try NSRegularExpression(pattern: #"\b(\w+) of (w|p)\b"#)
        for reader in [MeetTabReader.chrome(runner: scripts), MeetTabReader.dia(runner: scripts)] {
            for source in reader.scripts {
                let reads = Set(re.matches(in: source, range: NSRange(source.startIndex..., in: source))
                    .map { (source as NSString).substring(with: $0.range(at: 1)) })
                XCTAssertTrue(reads.isSubset(of: ["minimized", "tabs", "profiles"]), "\(reader.bundleId) reads \(reads)")
                XCTAssertFalse(source.contains("bounds"), "no window frames")
                XCTAssertFalse(source.contains("index of"), "the rank is counted, never read")
            }
        }
    }

    /// A bound window only stops a false "ended" (the home window in front): it never keeps the
    /// coach running. When the mic and call audio go quiet, Core Audio's stop still ends the
    /// session while the window lingers (a "meeting ended" or post-call window).
    func testBoundWindowNeverKeepsTheCoachRunning() throws {
        let reader = try XCTUnwrap(provider.readers.first as? ZoomControlsReader)
        reader.callWindowPresent = { true }                 // a post-call window stays bound
        ax.inMeeting()
        audio.live(Self.zoom)
        run(0, 5)
        ax.home()                                           // the in-meeting shortcuts are gone
        audio.live()                                        // mic and call audio quiet
        let stop = try XCTUnwrap(stops(run(5.5, 60)).first)
        XCTAssertEqual(stop.1, .audioEnded)
        XCTAssertEqual(stop.0, 35.5, accuracy: 1e-9, "Core Audio's 30 s stop, with the window still there")
        XCTAssertFalse(monitor.trigger.isActive)
        XCTAssertTrue(starts(run(60.5, 120)).isEmpty, "and it doesn't start again on the window alone")
    }

    func testBoundWindowWithMutedReadingStillStopsOnQuietAudio() throws {
        let reader = try XCTUnwrap(provider.readers.first as? ZoomControlsReader)
        reader.callWindowPresent = { true }
        ax.inMeeting(muted: true)
        audio.live(Self.zoom)
        run(0, 5)
        ax.home()
        audio.live()
        XCTAssertEqual(provider.callStates()[Self.zoom], .muted, "the held reading")
        XCTAssertEqual(try XCTUnwrap(stops(run(5.5, 60)).first).0, 35.5, accuracy: 1e-9, "muted never holds a session")
    }
}
