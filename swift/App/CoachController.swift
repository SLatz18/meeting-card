import AppKit
import ListenMoreCore
import ListenMoreMac
import MeetingCardCore

/// The call coach inside MeetingCard. Off by default: until the user turns it on in Settings there
/// is no service, no Core Audio polling, no capture and no network. Stores four settings in
/// UserDefaults (never call data); the API key lives only in the Keychain.
@MainActor
final class CoachController: NSObject {
    enum Keys {
        static let enabled = "coach.enabled"
        static let anyApp = "coach.anyApp"
        static let allowlist = "coach.allowlist"
        static let onboarded = "coach.onboarded"
    }

    let defaults: UserDefaults
    let config: ListenMoreConfig
    let keychain: KeychainStore
    /// Cards on screen, newest last (the chip goes on each; the status item shows only without one).
    var visibleCards: () -> [Card] = { [] }
    private(set) var service: CoachService?
    private var statusItem: NSStatusItem?
    private var refreshTimer: Timer?
    private var settingsWindow: CoachSettingsWindow?
    /// Last key problem shown in Settings.
    var keyProblem: KeyCheck?

    init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore()) throws {
        self.defaults = defaults
        self.keychain = keychain
        config = try ListenMoreConfig.builtIn()
        super.init()
        if enabled { makeService() }
    }

    var enabled: Bool { defaults.bool(forKey: Keys.enabled) }
    var anyApp: Bool { defaults.bool(forKey: Keys.anyApp) }
    var onboarded: Bool { defaults.bool(forKey: Keys.onboarded) }
    var hasKey: Bool { keychain.hasKey }

    /// The user's allowlist, or nil for the shipped call apps.
    var allowlist: [String]? { defaults.stringArray(forKey: Keys.allowlist) }
    var effectiveAllowlist: [String] { allowlist ?? config.captureTargets.map(\.bundleId) }

    var indicator: CoachIndicator { enabled ? service?.indicator ?? .hidden : .hidden }
    var chip: CoachChip? { CoachChip(indicator) }

    // MARK: settings

    /// Turning on needs a key that OpenAI accepts, or OpenAI being unreachable right now (the coach
    /// then retries on the next call). Empty or rejected keys keep it off.
    func setEnabled(_ on: Bool, completion: @escaping (KeyCheck?) -> Void) {
        guard on else {
            defaults.set(false, forKey: Keys.enabled)
            service?.setEnabled(false)
            keyProblem = nil
            refresh()
            completion(nil)
            return
        }
        guard let key = try? keychain.readKey() else {
            keyProblem = .empty
            completion(.empty)
            return
        }
        Task { @MainActor in
            let check = await KeyValidator.check(key.value)
            switch check {
            case .ok, .unreachable:
                self.defaults.set(true, forKey: Keys.enabled)
                if let service = self.service { service.setEnabled(true) } else { self.makeService() }
                self.keyProblem = check == .ok ? nil : .unreachable
            case .empty, .rejected:
                self.keyProblem = check
            }
            self.refresh()
            completion(check == .ok ? nil : check)
        }
    }

    func setAnyApp(_ on: Bool) {
        defaults.set(on, forKey: Keys.anyApp)
        service?.setAnyApp(on)
    }

    func setAllowlist(_ ids: [String]?) {
        if let ids { defaults.set(ids, forKey: Keys.allowlist) } else { defaults.removeObject(forKey: Keys.allowlist) }
        service?.setAllowlist(ids)
    }

    func markOnboarded() { defaults.set(true, forKey: Keys.onboarded) }

    // MARK: service

    private func makeService() {
        let s = CoachService(config: config, glowStyle: Self.glowStyle(), enabled: true, anyApp: anyApp, allowlist: allowlist)
        s.fallbackScreen = { [weak self] in self?.cardScreen() }
        s.cardWindowNumber = { [weak self] in self?.visibleCards().last?.panel.windowNumber }
        s.onChange = { [weak self] in self?.refresh() }
        service = s
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
        refresh()
    }

    private func cardScreen() -> NSRect? {
        visibleCards().last?.panel.screen?.frame ?? NSScreen.main?.frame
    }

    /// Rose and amber per appearance, from system red and the card's flag amber (Theme).
    static func glowStyle() -> GlowStyle {
        let rose = NSColor(name: "coachGlowRose") { appearance in
            let dark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            var red = Theme.Glow.systemRed(dark: dark)
            appearance.performAsCurrentDrawingAppearance {
                if let c = NSColor.systemRed.usingColorSpace(.sRGB) {
                    red = RGBA(Double(c.redComponent), Double(c.greenComponent), Double(c.blueComponent))
                }
            }
            return Theme.ns(Theme.Glow.rose(dark: dark, systemRed: red))
        }
        let amber = NSColor(name: "coachGlowAmber") { appearance in
            Theme.ns(Theme.Glow.amber(dark: appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua))
        }
        let g = Theme.Glow.self
        let profile = GlowProfile(
            width: g.width, peakOpacity: g.peakOpacity, cornerRadius: g.displayCornerRadius,
            stops: g.stops.map { GlowProfile.Stop($0.at, $0.factor) },
            motion: .init(rise: g.rise, hold: g.hold, fade: g.fade, appearFactor: 0, easeRise: true, easeFade: true),
            reduceMotion: .init(rise: 0, hold: 0, fade: g.reduceMotionFade, appearFactor: g.reduceMotionAppear,
                                easeRise: false, easeFade: false))
        return GlowStyle(rose: rose, amber: amber, profile: profile)
    }

    // MARK: controls

    func joinHint(endsAt: Date?) {
        guard enabled, let endsAt else { return }
        service?.joinHint(endsAt: endsAt)
    }

    @objc func chipClicked(_ sender: Any?) { service?.chipControl() }
    @objc func startClicked(_ sender: Any?) { service?.start() }
    @objc func pauseClicked(_ sender: Any?) { service?.pause() }
    @objc func resumeClicked(_ sender: Any?) { service?.resume() }
    @objc func settingsClicked(_ sender: Any?) { showSettings() }

    func showSettings() {
        let w = settingsWindow ?? CoachSettingsWindow(coach: self)
        settingsWindow = w
        w.present()
    }

    // MARK: indicator

    /// Chip on every visible card; the status item only while a session runs with no card showing.
    func refresh() {
        let chip = self.chip
        let cards = visibleCards()
        for c in cards { c.setCoach(chip) }
        let session = indicator == .listening || indicator == .paused
        updateStatusItem(show: session && cards.isEmpty)
        settingsWindow?.update()
    }

    private func updateStatusItem(show: Bool) {
        guard show else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        let paused = indicator == .paused
        let label = paused ? CoachCopy.coachPaused : CoachCopy.coachOn
        if let button = item.button {
            let image = NSImage(systemSymbolName: Theme.Coach.symbol, accessibilityDescription: label)?
                .withSymbolConfiguration(.init(pointSize: CGFloat(Theme.Coach.glyphSize), weight: .regular))
            image?.isTemplate = true
            button.image = image
            button.appearsDisabled = paused
            button.toolTip = label
            button.setAccessibilityLabel(label)
        }
        let menu = NSMenu()
        let header = NSMenuItem(title: label, action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        let toggle = NSMenuItem(title: paused ? CoachCopy.resume : CoachCopy.pause,
                                action: paused ? #selector(resumeClicked(_:)) : #selector(pauseClicked(_:)), keyEquivalent: "")
        toggle.target = self
        menu.addItem(toggle)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: CoachCopy.settings, action: #selector(settingsClicked(_:)), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        item.menu = menu
    }

    var statusItemVisible: Bool { statusItem != nil }
}
