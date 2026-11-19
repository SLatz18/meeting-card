import AppKit
import ApplicationServices
import CoreServices
import ListenMoreCore

// The macOS backends for "Use Zoom/Meet controls" (ListenMoreCore's CallControls). Nothing here
// prompts except `CallControlsPermissions.request...`, which only the host's Settings toggle calls.
// Nothing is logged.

/// Zoom's menu bar through the Accessibility API. Reads menu items' shortcuts
/// (`kAXMenuItemCmdChar`, `kAXMenuItemCmdModifiers`) and, for the ⇧⌘A audio toggle only, its label
/// reduced to a Bool at once. Never reads windows, window or meeting titles, participants or chat.
/// Its one action is a single Accessibility press on that same ⇧⌘A item (`pressAudioToggle`).
public final class AXZoomAccessibility: ZoomAccessibility {
    public let bundleId: String
    /// Per-call timeout so a busy Zoom never stalls a refresh.
    static let messagingTimeout: Float = 0.5

    public init(bundleId: String = ZoomControlsReader.bundleId) {
        self.bundleId = bundleId
    }

    public var isTrusted: Bool { AXIsProcessTrusted() }
    public var isRunning: Bool { pid != nil }

    private var pid: pid_t? {
        NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).first { !$0.isTerminated }?.processIdentifier
    }

    public func menuShortcuts() -> [MenuShortcut]? {
        let toggle = ZoomControlsReader.audioToggle
        var out: [MenuShortcut] = []
        let read = forEachShortcut { item, shortcut in
            var s = shortcut
            if s.matches(key: toggle.key, modifiers: toggle.modifiers) { s.offersUnmute = audioToggleOffersUnmute(item) }
            out.append(s)
            return true
        }
        return read ? out : nil
    }

    /// The ⇧⌘A item, found by its shortcut alone, pressed exactly once.
    public func pressAudioToggle() -> AudioTogglePress {
        let toggle = ZoomControlsReader.audioToggle
        var found: AXUIElement?
        _ = forEachShortcut { item, s in
            guard s.matches(key: toggle.key, modifiers: toggle.modifiers) else { return true }
            found = item
            return false
        }
        guard let item = found else { return .noItem }
        return AXUIElementPerformAction(item, kAXPressAction as CFString) == .success ? .pressed : .failed
    }

    /// Visits each menu-bar menu item that has a shortcut, until `visit` returns false. Reads only
    /// the menu bar, children and the two shortcut attributes. False if the menu bar can't be read.
    private func forEachShortcut(_ visit: (AXUIElement, MenuShortcut) -> Bool) -> Bool {
        guard let pid else { return false }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, Self.messagingTimeout)
        guard let bar = element(app, kAXMenuBarAttribute) else { return false }
        for barItem in children(bar) {
            for menu in children(barItem) {
                for item in children(menu) {
                    guard let key = string(item, kAXMenuItemCmdCharAttribute), !key.isEmpty else { continue }
                    let s = MenuShortcut(key: key, modifiers: int(item, kAXMenuItemCmdModifiersAttribute) ?? 0)
                    if !visit(item, s) { return true }
                }
            }
        }
        return true
    }

    /// The only label read anywhere: Zoom's own ⇧⌘A item ("Mute audio" / "Unmute audio"), kept as a Bool.
    private func audioToggleOffersUnmute(_ item: AXUIElement) -> Bool? {
        string(item, kAXTitleAttribute).flatMap(ZoomControlsReader.offersUnmute(label:))
    }

    private func value(_ e: AXUIElement, _ attribute: String) -> CFTypeRef? {
        var v: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, attribute as CFString, &v) == .success ? v : nil
    }

    private func element(_ e: AXUIElement, _ attribute: String) -> AXUIElement? {
        guard let v = value(e, attribute), CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    private func children(_ e: AXUIElement) -> [AXUIElement] {
        (value(e, kAXChildrenAttribute) as? [AnyObject])?.compactMap { v in
            CFGetTypeID(v) == AXUIElementGetTypeID() ? (v as! AXUIElement) : nil
        } ?? []
    }

    private func string(_ e: AXUIElement, _ attribute: String) -> String? { value(e, attribute) as? String }
    private func int(_ e: AXUIElement, _ attribute: String) -> Int? { (value(e, attribute) as? NSNumber)?.intValue }
}

/// Runs `MeetTabReader` scripts with NSAppleScript. Call from one serial queue only (the
/// `CallControlsProvider` queue): compiled scripts are cached per source and never shared across
/// threads. Only the script's integer result is read.
public final class OSAScriptRunner: AppleScriptRunner {
    private var compiled: [String: NSAppleScript] = [:]
    private var compileErrors: [String: Int] = [:]

    public init() {}

    /// Never prompts: an app that isn't running is never sent an event (that would launch it), and
    /// consent that hasn't been given yet reads as `.notAsked`.
    public func permission(bundleId: String) -> AutomationPermission {
        guard NSRunningApplication.runningApplications(withBundleIdentifier: bundleId).contains(where: { !$0.isTerminated }) else {
            return .notRunning
        }
        return CallControlsPermissions.automation(bundleId: bundleId, ask: false)
    }

    public func run(_ source: String, bundleId: String) -> ScriptOutcome {
        if let code = compileErrors[source] { return .failed(code: code) }
        let script: NSAppleScript
        if let s = compiled[source] {
            script = s
        } else {
            guard let s = NSAppleScript(source: source) else { return .failed(code: -2741) }
            var error: NSDictionary?
            guard s.compileAndReturnError(&error) else {
                let code = Self.code(error) ?? -2741
                compileErrors[source] = code
                return .failed(code: code)
            }
            compiled[source] = s
            script = s
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        if let error { return .failed(code: Self.code(error) ?? -1) }
        return .count(Int(result.int32Value))
    }

    static func code(_ error: NSDictionary?) -> Int? { (error?[NSAppleScript.errorNumber] as? NSNumber)?.intValue }
}

/// Accessibility (Zoom) and Automation (Chrome, Dia) for "Use Zoom/Meet controls". The `request`
/// functions show the system prompts and are for the Settings toggle only; everything else checks
/// without asking.
public enum CallControlsPermissions {
    public static let browsers = ["com.google.Chrome", "company.thebrowser.dia"]

    public static var accessibilityTrusted: Bool { AXIsProcessTrusted() }

    /// Checks (or, with `ask`, prompts for) Automation of a running app. Blocks while a prompt is up.
    public static func automation(bundleId: String, ask: Bool) -> AutomationPermission {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleId)
        guard let desc = target.aeDesc else { return .denied }
        let status = Int(AEDeterminePermissionToAutomateTarget(desc, AEEventClass(typeWildCard), AEEventID(typeWildCard), ask))
        switch status {
        case Int(noErr): return .granted
        case Int(errAEEventWouldRequireUserConsent): return .notAsked
        case Int(procNotFound): return .notRunning
        default: return .denied
        }
    }

    /// Shows the system's Accessibility prompt if this app isn't trusted yet.
    @discardableResult
    public static func requestAccessibility() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    /// Asks for Automation of each running browser in `bundleIds`, off the main thread (each prompt
    /// blocks until answered), then calls `done` on the main queue. A browser that isn't running
    /// can't be asked; the Settings button asks again later.
    public static func requestAutomation(bundleIds: [String] = browsers, done: @escaping @Sendable () -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            for id in bundleIds where !NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty {
                _ = automation(bundleId: id, ask: true)
            }
            DispatchQueue.main.async(execute: done)
        }
    }
}

public extension CallControlsProvider {
    /// Zoom, Meet in Chrome and Meet in Dia, refreshed on a utility queue. Off until `isEnabled`.
    /// - Parameter callWindows: the tracker the coach service uses, so Zoom's in-meeting state holds
    ///   while its meeting window exists even if its menu bar follows the home window, and the Meet
    ///   scripts also name the window holding the meeting. Nil (the default) is the menu-only Zoom
    ///   reading and the count-only Meet scripts.
    static func live(config: ListenMoreConfig, callWindows: CallWindowTracker? = nil) -> CallControlsProvider {
        let runner = OSAScriptRunner()
        let zoom = ZoomControlsReader(ax: AXZoomAccessibility())
        if let callWindows {
            let key = zoom.appKey
            zoom.callWindowPresent = { [weak callWindows] in callWindows?.callWindowPresent(appKey: key) }
        }
        let windowHints = callWindows != nil
        return CallControlsProvider(readers: [zoom, MeetTabReader.chrome(runner: runner, windowHints: windowHints),
                                              MeetTabReader.dia(runner: runner, windowHints: windowHints)],
                                    endedHoldS: config.trigger.stopAfterS,
                                    queue: DispatchQueue(label: "com.listenmore.callcontrols", qos: .utility))
    }
}
