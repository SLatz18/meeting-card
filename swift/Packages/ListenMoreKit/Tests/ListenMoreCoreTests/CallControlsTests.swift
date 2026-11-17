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

        func menuShortcuts() -> [MenuShortcut]? {
            reads += 1
            return items
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
        private(set) var runs: [(bundleId: String, source: String)] = []

        func permission(bundleId: String) -> AutomationPermission { permissions[bundleId] ?? .granted }

        func run(_ source: String, bundleId: String) -> ScriptOutcome {
            runs.append((bundleId, source))
            if let code = failures[bundleId] { return .failed(code: code) }
            if let f = failuresWhenContaining[bundleId], source.contains(f.marker) { return .failed(code: f.code) }
            return .count(meetTabs[bundleId] ?? 0)
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
}
