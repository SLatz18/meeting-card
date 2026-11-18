import Foundation

// App-level call controls as a `CallStateProvider`: Zoom's in-meeting menu shortcuts (Accessibility)
// and an open Google Meet meeting tab in Chrome or Dia (AppleScript). Readers see structure only:
// menu shortcuts of Zoom's menu items, the label of Zoom's one audio toggle reduced to a Bool,
// and a count of Meet meeting tabs computed inside the browser's script. No window or meeting
// title, participant name, chat, page text or other URL is read, kept or logged. Any reader that
// can't answer (permission missing or revoked, scripting unsupported, a failed read) reports
// nothing for its app, so Core Audio decides as before. The one action is `ZoomControlsReader.toggleMute()`:
// a single Accessibility press on Zoom's own Mute/Unmute menu item (no synthesized input of any kind).

/// One reading of a call app's controls.
public enum CallObservation: Equatable, Sendable {
    /// No reading; the app falls back to Core Audio.
    case unavailable(CallControlsIssue)
    /// The app is not running, or runs without a call.
    case noCall
    /// In a call. `muted` is nil when the app doesn't expose its mute state.
    case inCall(muted: Bool?)
}

public enum CallControlsIssue: String, Equatable, Sendable {
    case accessibilityDenied
    case automationDenied
    /// Automation hasn't been asked for yet. Only the Settings toggle asks, so this reads nothing.
    case automationNotAsked
    /// The app's scripting can't list tab URLs (no dictionary, or no `whose` filter on tabs).
    case unsupported
    case readFailed
}

public protocol CallControlsReader: AnyObject {
    /// Lowercased bundle ID, as `TriggerSettings.appKey` makes them.
    var appKey: String { get }
    func read() -> CallObservation
    /// Forget anything kept between readings (the provider was switched off and on).
    func reset()
}

extension CallControlsReader {
    public func reset() {}
}

/// Turns readings over time into call states: `started` / `muted` while in a call, `ended` for
/// `endedHoldS` after a call the reader saw goes away, nothing otherwise. A reader that becomes
/// unavailable mid-call drops its app's state, so Core Audio takes over.
public struct CallStateTracker: Sendable {
    public let endedHoldS: Double
    public private(set) var states: [String: CallState] = [:]
    private var inCall: Set<String> = []
    private var endedAt: [String: Double] = [:]

    public init(endedHoldS: Double) {
        self.endedHoldS = endedHoldS
    }

    public mutating func observe(_ key: String, _ o: CallObservation, now: Double) {
        switch o {
        case .unavailable:
            inCall.remove(key)
            endedAt[key] = nil
            states[key] = nil
        case .inCall(let muted):
            inCall.insert(key)
            endedAt[key] = nil
            states[key] = muted == true ? .muted : .started
        case .noCall:
            if inCall.remove(key) != nil { endedAt[key] = now }
            if let at = endedAt[key], now - at < endedHoldS - 1e-9 {
                states[key] = .ended
            } else {
                endedAt[key] = nil
                states[key] = nil
            }
        }
    }

    public mutating func reset() {
        self = CallStateTracker(endedHoldS: endedHoldS)
    }
}

/// The "Use Zoom/Meet controls" provider. Off (the default) reads nothing and reports nothing.
/// With `queue`, `callStates()` returns the last reading at once and refreshes on that queue (one
/// refresh at a time), so slow Accessibility or Apple Event replies never block the caller;
/// without it, `callStates()` refreshes inline (tests).
public final class CallControlsProvider: CallStateProvider, @unchecked Sendable {
    public let readers: [CallControlsReader]
    private let queue: DispatchQueue?
    private let clock: () -> Double
    private let lock = NSLock()
    private var tracker: CallStateTracker
    private var enabled = false
    private var generation = 0
    private var inFlight = false
    private var lastIssues: [String: CallControlsIssue] = [:]
    private var lastHints: [String: CallWindowHint] = [:]

    /// - Parameter endedHoldS: how long an ended call is reported (the trigger stops after
    ///   `endedStopAfterS`; hosts pass `trigger.stop_after_s`, after which Core Audio decides anyway).
    public init(readers: [CallControlsReader], endedHoldS: Double, queue: DispatchQueue? = nil,
                clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.readers = readers
        self.queue = queue
        self.clock = clock
        tracker = CallStateTracker(endedHoldS: endedHoldS)
    }

    public var isEnabled: Bool {
        get { lock.withLock { enabled } }
        set {
            lock.withLock {
                guard enabled != newValue else { return }
                enabled = newValue
                generation += 1
                tracker.reset()
                lastIssues = [:]
                lastHints = [:]
                readers.forEach { $0.reset() }
            }
        }
    }

    /// Why each app with a problem is falling back to Core Audio, from the last reading.
    public var issues: [String: CallControlsIssue] { lock.withLock { enabled ? lastIssues : [:] } }

    public func callStates() -> [String: CallState] {
        guard let queue else {
            refresh()
            return lock.withLock { enabled ? tracker.states : [:] }
        }
        let (states, start) = lock.withLock { () -> ([String: CallState], Bool) in
            let start = enabled && !inFlight
            if start { inFlight = true }
            return (enabled ? tracker.states : [:], start)
        }
        if start {
            queue.async { [weak self] in
                self?.refresh()
                self?.lock.withLock { self?.inFlight = false }
            }
        }
        return states
    }

    /// Which window holds the call, per browser, from the last reading (`CallWindowSelector`).
    public var windowHints: [String: CallWindowHint] { lock.withLock { enabled ? lastHints : [:] } }

    /// The last reading, without starting a refresh.
    public var currentStates: [String: CallState] { lock.withLock { enabled ? tracker.states : [:] } }

    /// Runs `work` where readings run (the refresh queue, else inline), so an action and the
    /// reading after it never overlap another read.
    public func perform(_ work: @escaping () -> Void) {
        if let queue { queue.async(execute: work) } else { work() }
    }

    /// Reads every app once (no-op while off). Readings taken across an off/on switch are dropped.
    public func refresh() {
        let gen = lock.withLock { enabled ? generation : nil }
        guard let gen else { return }
        let readings = readers.map { ($0.appKey, $0.read(), ($0 as? CallWindowHinting)?.windowHint) }
        let now = clock()
        lock.withLock {
            guard enabled, gen == generation else { return }
            for (key, o, hint) in readings {
                lastHints[key] = hint
                tracker.observe(key, o, now: now)
                if case .unavailable(let issue) = o { lastIssues[key] = issue } else { lastIssues[key] = nil }
            }
        }
    }
}

/// A value behind a lock, for the little state a reader keeps between readings.
final class LockedBox<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withValue<R>(_ body: (inout Value) -> R) -> R { lock.withLock { body(&value) } }
}

// MARK: Zoom

/// A menu item in a call app's menu bar as the Accessibility reader sees it: its menu shortcut
/// (`kAXMenuItemCmdChar` / `kAXMenuItemCmdModifiers`) and, for the audio toggle only, whether it
/// offers Unmute.
public struct MenuShortcut: Equatable, Sendable {
    /// `kAXMenuItemCmdModifiers` bit for Shift (Command is implied unless the no-Command bit is set).
    public static let shift = 1

    public var key: String
    public var modifiers: Int
    public var offersUnmute: Bool?

    public init(key: String, modifiers: Int, offersUnmute: Bool? = nil) {
        self.key = key
        self.modifiers = modifiers
        self.offersUnmute = offersUnmute
    }

    public func matches(key k: String, modifiers m: Int) -> Bool {
        key.uppercased() == k && modifiers == m
    }
}

/// What the Zoom reader needs from the Accessibility API (ListenMoreMac's `AXZoomAccessibility`).
public protocol ZoomAccessibility: AnyObject {
    /// This process is trusted for Accessibility (never prompts).
    var isTrusted: Bool { get }
    var isRunning: Bool { get }
    /// Shortcuts of the items in Zoom's menu bar menus; nil if the read failed.
    func menuShortcuts() -> [MenuShortcut]?
    /// One Accessibility press on the ⇧⌘A item (Zoom's Mute/Unmute audio), found by its shortcut
    /// alone (no label read).
    func pressAudioToggle() -> AudioTogglePress
}

public enum AudioTogglePress: Equatable, Sendable {
    case pressed
    /// No ⇧⌘A item: Zoom isn't in a meeting (or the menu bar couldn't be read).
    case noItem
    case failed
}

/// Zoom (`us.zoom.xos`): in a meeting while its menu bar has the in-meeting shortcuts (Zoom's
/// Meeting menu: ⇧⌘A mute/unmute audio, ⇧⌘V start/stop video); ended when they go away (Leave, or
/// the meeting window closed); muted while the ⇧⌘A item offers Unmute.
public final class ZoomControlsReader: CallControlsReader {
    public static let bundleId = "us.zoom.xos"
    public static let audioToggle = (key: "A", modifiers: MenuShortcut.shift)
    public static let meetingShortcuts = [audioToggle, (key: "V", modifiers: MenuShortcut.shift)]

    public let appKey = ZoomControlsReader.bundleId
    private let ax: ZoomAccessibility
    /// Whether the call's window (`CallWindowSelector`) still exists; nil when none is bound.
    /// Zoom's menu bar can follow its key window, so with the home window in front the in-meeting
    /// shortcuts may be missing while the meeting goes on: that alone never reads as ended.
    public var callWindowPresent: (() -> Bool?)?

    /// What survives between readings. `epoch` changes on `reset()`, so a read that was already in
    /// flight when the provider switched off and on can't write its result back.
    private struct Memory {
        var epoch = 0
        /// The last mute reading, kept while the shortcuts are hidden by the home window in front.
        var lastMuted: Bool?
        /// The last reading was held (no shortcuts, the meeting window still there), not read.
        var held = false
    }
    private let memory = LockedBox(Memory())

    public init(ax: ZoomAccessibility) {
        self.ax = ax
    }

    public var isTrusted: Bool { ax.isTrusted }

    /// The last reading was a held one: the call goes on, but Zoom's menu has no ⇧⌘A item to press,
    /// so Mute in Zoom can't act (`CallControlsModel.muteUnavailableReason`).
    public var isHeld: Bool { memory.withValue { $0.held } }

    public func reset() {
        memory.withValue {
            $0.epoch += 1
            $0.lastMuted = nil
            $0.held = false
        }
    }

    public func read() -> CallObservation {
        let epoch = memory.withValue { $0.epoch }
        func remember(muted: Bool?, held: Bool) {
            memory.withValue {
                guard $0.epoch == epoch else { return }
                $0.lastMuted = muted
                $0.held = held
            }
        }
        guard ax.isTrusted else {
            remember(muted: memory.withValue { $0.lastMuted }, held: false)
            return .unavailable(.accessibilityDenied)
        }
        guard ax.isRunning else {
            remember(muted: nil, held: false)
            return .noCall
        }
        guard let items = ax.menuShortcuts() else {
            remember(muted: memory.withValue { $0.lastMuted }, held: false)
            return .unavailable(.readFailed)
        }
        let inMeeting = items.contains { i in Self.meetingShortcuts.contains { i.matches(key: $0.key, modifiers: $0.modifiers) } }
        guard inMeeting else {
            if callWindowPresent?() == true {
                let muted = memory.withValue { $0.lastMuted }
                remember(muted: muted, held: true)
                return .inCall(muted: muted)
            }
            remember(muted: nil, held: false)
            return .noCall
        }
        let audio = items.first { $0.matches(key: Self.audioToggle.key, modifiers: Self.audioToggle.modifiers) }
        remember(muted: audio?.offersUnmute, held: false)
        return .inCall(muted: audio?.offersUnmute)
    }

    /// Mute or unmute in Zoom: exactly one press on Zoom's own ⇧⌘A item, only while trusted and in a
    /// meeting. Callers check the "Use Zoom/Meet controls" setting (`CallControlsModel`).
    public func toggleMute() -> MuteActionResult {
        guard ax.isTrusted else { return .unavailable(.permissionDenied) }
        guard ax.isRunning else { return .unavailable(.noZoomCall) }
        switch ax.pressAudioToggle() {
        case .pressed: return .pressed
        case .noItem: return .unavailable(.noZoomCall)
        case .failed: return .failed
        }
    }

    /// The ⇧⌘A item's label is "Mute audio" while live and "Unmute audio" while muted (or "... telephone").
    /// Only that item's label is passed here, and only this Bool is kept. Other languages: nil (unknown).
    public static func offersUnmute(label: String) -> Bool? {
        let l = label.trimmingCharacters(in: .whitespaces).lowercased()
        if l.hasPrefix("unmute") { return true }
        if l.hasPrefix("mute") { return false }
        return nil
    }
}

// MARK: Meet in a browser

public enum AutomationPermission: Equatable, Sendable {
    case granted
    case denied
    /// Not asked yet: sending an event would prompt.
    case notAsked
    case notRunning
}

public enum ScriptOutcome: Equatable, Sendable {
    /// The script's integer result.
    case count(Int)
    /// An AppleScript compile or run error number.
    case failed(code: Int)
}

/// Runs a reader's AppleScript against one app (ListenMoreMac's `OSAScriptRunner`). Never prompts.
public protocol AppleScriptRunner: AnyObject {
    func permission(bundleId: String) -> AutomationPermission
    func run(_ source: String, bundleId: String) -> ScriptOutcome
}

/// A Google Meet meeting tab in a browser (Chrome, Dia): in a call while at least one tab's URL is a
/// meet.google.com meeting. The browser filters its tabs to the Meet host itself and the script
/// returns only a count (`MeetScript`). Meet's mute state isn't readable without page content, so
/// it is never reported. A browser whose scripting can't answer falls back to Core Audio.
/// A reader that can also say which of its app's windows holds the call.
public protocol CallWindowHinting: AnyObject {
    /// From the last `read()`; nil when no single visible window holds the call.
    var windowHint: CallWindowHint? { get }
}

public final class MeetTabReader: CallControlsReader, CallWindowHinting {
    public let bundleId: String
    public let appKey: String
    public let scripts: [String]
    private let runner: AppleScriptRunner
    private var working: Int?
    public private(set) var windowHint: CallWindowHint?

    /// - Parameter scripts: tried in order until one compiles and runs (e.g. Dia with and without spaces).
    public init(bundleId: String, scripts: [String], runner: AppleScriptRunner) {
        self.bundleId = bundleId
        appKey = bundleId.lowercased()
        self.scripts = scripts
        self.runner = runner
    }

    public static func chrome(runner: AppleScriptRunner) -> MeetTabReader {
        let id = "com.google.Chrome"
        return MeetTabReader(bundleId: id, scripts: [MeetScript.source(bundleId: id, spaces: false)], runner: runner)
    }

    /// Dia lists a window's tabs for its active space only, so the first script walks every space.
    public static func dia(runner: AppleScriptRunner) -> MeetTabReader {
        let id = "company.thebrowser.dia"
        return MeetTabReader(bundleId: id, scripts: [MeetScript.source(bundleId: id, spaces: true),
                                                     MeetScript.source(bundleId: id, spaces: false)], runner: runner)
    }

    public func read() -> CallObservation {
        windowHint = nil
        switch runner.permission(bundleId: bundleId) {
        case .notRunning: return .noCall
        case .denied: return .unavailable(.automationDenied)
        case .notAsked: return .unavailable(.automationNotAsked)
        case .granted: break
        }
        var lastCode = 0
        for i in (working.map { [$0] } ?? Array(scripts.indices)) {
            switch runner.run(scripts[i], bundleId: bundleId) {
            case .count(let v):
                working = i
                let r = MeetScript.decode(v)
                if r.meetingTabs > 0, r.holdingRank > 0 {
                    windowHint = CallWindowHint(rank: r.holdingRank, visibleWindows: r.visibleWindows)
                }
                return r.meetingTabs > 0 ? .inCall(muted: nil) : .noCall
            case .failed(let code):
                lastCode = code
                if code == MeetScript.notRunning { return .noCall }
                if code == MeetScript.notPermitted { return .unavailable(.automationDenied) }
                guard MeetScript.unsupportedCodes.contains(code), working == nil else { return .unavailable(.readFailed) }
            }
        }
        return .unavailable(MeetScript.unsupportedCodes.contains(lastCode) ? .unsupported : .readFailed)
    }
}

/// The AppleScript a `MeetTabReader` runs. Inside the browser, `whose URL starts with` narrows the
/// tabs to the Meet host, so no other tab's URL is sent; the Meet URLs are checked for a meeting
/// path in the script and only their count comes back. Titles and other tab properties are never
/// asked for.
public enum MeetScript {
    public static let meetPrefix = "https://meet.google.com/"
    /// procNotFound: the app quit between the running check and the event.
    public static let notRunning = -600
    /// errAEEventNotPermitted: Automation denied (or revoked).
    public static let notPermitted = -1743
    /// No terminology (compile errors), an event or `whose` filter the app doesn't handle, or an
    /// object it can't produce.
    public static let unsupportedCodes: Set<Int> = [-2741, -2740, -2753, -1708, -1728, -1700, -10000]

    /// Meeting codes are three letters, four, three: `https://meet.google.com/abc-defg-hij`, optionally
    /// followed by `?`, `#` or `/`. Mirrors the script's `isMeeting` handler (checked on macOS).
    public static func isMeetingURL(_ url: String) -> Bool {
        let u = Array(url.lowercased())
        let prefix = Array(meetPrefix)
        guard u.count >= prefix.count + 12, Array(u[0..<prefix.count]) == prefix else { return false }
        if u.count > prefix.count + 12, !"?#/".contains(u[prefix.count + 12]) { return false }
        for (i, c) in u[prefix.count..<(prefix.count + 12)].enumerated() {
            if i == 3 || i == 8 {
                guard c == "-" else { return false }
            } else {
                guard ("a"..."z").contains(c) else { return false }
            }
        }
        return true
    }

    /// The only URL read in any script: Meet-host tabs, filtered by the browser.
    public static let meetTabURLs = "URL of (tabs of <container> whose URL starts with \"\(meetPrefix)\")"

    /// The `isMeeting(u)` handler; the browser block calls it on Meet-host URLs only.
    public static let handler = """
    on isMeeting(u)
    \tset u to u as text
    \tif u does not start with "\(meetPrefix)" then return false
    \tif (count of u) < 36 then return false
    \tif (count of u) > 36 then
    \t\tif character 37 of u is not in {"?", "#", "/"} then return false
    \tend if
    \trepeat with i from 25 to 36
    \t\tset c to character i of u
    \t\tif i is 28 or i is 33 then
    \t\t\tif c is not "-" then return false
    \t\telse if c is not in "abcdefghijklmnopqrstuvwxyz" then
    \t\t\treturn false
    \t\tend if
    \tend repeat
    \treturn true
    end isMeeting

    on countMeetings(urls)
    \tset n to 0
    \trepeat with u in urls
    \t\tif my isMeeting(contents of u) then set n to n + 1
    \tend repeat
    \treturn n
    end countMeetings
    """

    /// The script's one integer: meeting tabs (capped at 999) + 1000 x the 1-based rank, among the
    /// browser's visible (not minimized) windows in z-order, of the one window holding them (0 when
    /// none, several, or it is minimized) + 1,000,000 x the number of visible windows.
    public static func decode(_ v: Int) -> (meetingTabs: Int, holdingRank: Int, visibleWindows: Int) {
        (v % 1000, (v / 1000) % 1000, v / 1_000_000)
    }

    /// - Parameter spaces: Dia: walk each window's spaces (`profiles`), whose tabs a window doesn't list.
    public static func source(bundleId: String, spaces: Bool) -> String {
        func meetTabs(_ container: String) -> String { meetTabURLs.replacingOccurrences(of: "<container>", with: container) }
        let perWindow = spaces
            ? """
            \t\t\trepeat with p in profiles of w
            \t\t\t\tset k to k + (my countMeetings(\(meetTabs("p"))))
            \t\t\tend repeat
            """
            : "\t\t\tset k to k + (my countMeetings(\(meetTabs("w"))))"
        return """
        \(handler)

        if application id "\(bundleId)" is not running then return 0
        with timeout of 2 seconds
        \ttell application id "\(bundleId)"
        \t\tset n to 0
        \t\tset nVisible to 0
        \t\tset nHolding to 0
        \t\tset holdingRank to 0
        \t\trepeat with w in windows
        \t\t\tset isMin to false
        \t\t\ttry
        \t\t\t\tset isMin to (minimized of w) as boolean
        \t\t\tend try
        \t\t\tif not isMin then set nVisible to nVisible + 1
        \t\t\tset k to 0
        \(perWindow)
        \t\t\tif k > 0 then
        \t\t\t\tset n to n + k
        \t\t\t\tset nHolding to nHolding + 1
        \t\t\t\tif isMin then
        \t\t\t\t\tset holdingRank to 0
        \t\t\t\telse
        \t\t\t\t\tset holdingRank to nVisible
        \t\t\t\tend if
        \t\t\tend if
        \t\tend repeat
        \t\tif nHolding is not 1 then set holdingRank to 0
        \t\tif n > 999 then set n to 999
        \t\treturn n + 1000 * holdingRank + 1000000 * nVisible
        \tend tell
        end timeout
        """
    }
}
