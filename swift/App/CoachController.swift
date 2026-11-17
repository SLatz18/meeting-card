import AppKit
import ListenMoreCore
import ListenMoreMac
import MeetingCardCore

/// The call coach inside MeetingCard. Off by default: until the user turns it on (Settings or the
/// coach status menu) there is no service, no Core Audio polling, no capture and no network. It
/// turns on without a key (local cues only); GPT cues need a key OpenAI hasn't rejected. Stores four
/// settings in UserDefaults (never call data); the API key lives only in the Keychain.
@MainActor
final class CoachController: NSObject {
    enum Keys {
        static let enabled = "coach.enabled"
        static let anyApp = "coach.anyApp"
        static let allowlist = "coach.allowlist"
        static let onboarded = "coach.onboarded"
    }

    /// MeetingCard's Keychain item for the OpenAI key (the Kit's default service is not ours).
    static let keychainService = "com.slatz.meetingcard.swift.openai"

    let defaults: UserDefaults
    let config: ListenMoreConfig
    let keychain: KeychainStore
    /// What the service reads the key through: nil while the stored key is known to be rejected.
    let keyGate: CoachKeyGate
    /// Cards on screen, newest last (the chip goes on each).
    var visibleCards: () -> [Card] = { [] }
    /// The coach status menu: always there, so the coach can be enabled from it while off.
    private let showsStatusItem: Bool
    private(set) var service: CoachService?
    private var statusItem: NSStatusItem?
    private var refreshTimer: Timer?
    private var settingsWindow: CoachSettingsWindow?
    /// Last key problem shown in Settings.
    var keyProblem: KeyCheck?

    init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore(service: CoachController.keychainService),
         showsStatusItem: Bool = true) throws {
        self.defaults = defaults
        self.keychain = keychain
        keyGate = CoachKeyGate(keychain)
        self.showsStatusItem = showsStatusItem
        config = try ListenMoreConfig.builtIn()
        super.init()
        keyStored = keychain.hasKey
        if enabled {
            makeService()
            checkStoredKey()
        }
        refresh()
    }

    var enabled: Bool { defaults.bool(forKey: Keys.enabled) }
    var anyApp: Bool { defaults.bool(forKey: Keys.anyApp) }
    var onboarded: Bool { defaults.bool(forKey: Keys.onboarded) }
    var hasKey: Bool { keychain.hasKey }
    /// GPT cues can run: a key is stored and OpenAI hasn't rejected it.
    var gptAvailable: Bool { keyStored && !keyGate.rejected }
    /// Whether a key is in the Keychain, kept current by key actions (refresh runs every second).
    var keyStored = false

    /// The user's allowlist, or nil for the shipped call apps.
    var allowlist: [String]? { defaults.stringArray(forKey: Keys.allowlist) }
    var effectiveAllowlist: [String] { allowlist ?? config.captureTargets.map(\.bundleId) }

    var indicator: CoachIndicator { enabled ? service?.indicator ?? .hidden : .hidden }
    var chip: CoachChip? { CoachChip(indicator) }

    // MARK: settings

    /// Turning on never needs a key: without one (or with one OpenAI rejects, which is flagged) the
    /// coach runs local cues only. A stored key is checked in the background.
    func setEnabled(_ on: Bool, completion: @escaping (KeyCheck?) -> Void) {
        defaults.set(on, forKey: Keys.enabled)
        guard on else {
            service?.setEnabled(false)
            keyProblem = nil
            refresh()
            completion(nil)
            return
        }
        if let service { service.setEnabled(true) } else { makeService() }
        keyProblem = nil
        refresh()
        checkStoredKey(completion: completion)
    }

    /// Flags a stored key OpenAI rejects (GPT cues stay off until it is replaced); local cues are unaffected.
    func checkStoredKey(completion: @escaping (KeyCheck?) -> Void = { _ in }) {
        keyStored = hasKey
        guard let key = try? keychain.readKey() else {
            keyGate.rejected = false
            completion(nil)
            return
        }
        Task { @MainActor in
            let check = await KeyValidator.check(key.value)
            self.keyGate.rejected = check == .rejected
            self.keyProblem = check == .ok ? nil : check
            self.refresh()
            completion(self.keyProblem)
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
        let s = CoachService(config: config, glowStyle: Self.glowStyle(), enabled: true, anyApp: anyApp,
                             allowlist: allowlist, keys: keyGate)
        s.fallbackScreen = { [weak self] in self?.cardScreen() }
        s.hostWindowNumber = { [weak self] in self?.visibleCards().last?.panel.windowNumber }
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

    /// The Kit's coach style from MeetingCard's tokens: rose and amber per appearance, the card's
    /// corner radius and a one-control-height band (Theme.Glow). The Kit draws only what it's given.
    static func coachStyle() -> CoachStyle {
        func kit(_ c: RGBA) -> CoachStyle.RGBA { CoachStyle.RGBA(red: c.r, green: c.g, blue: c.b, alpha: c.a) }
        func colors(dark: Bool) -> [CueColor: CoachStyle.RGBA] {
            [.red: kit(Theme.Glow.rose(dark: dark)), .amber: kit(Theme.Glow.amber(dark: dark))]
        }
        let g = Theme.Glow.self
        let profile = GlowProfile(
            width: g.width, peakOpacity: g.peakOpacity, cornerRadius: g.cornerRadius,
            stops: g.stops.map { GlowProfile.Stop($0.at, $0.factor) },
            motion: .init(rise: g.rise, hold: g.hold, fade: g.fade, appearFactor: 0, easeRise: true, easeFade: true),
            reduceMotion: .init(rise: 0, hold: 0, fade: g.reduceMotionFade, appearFactor: g.reduceMotionAppear,
                                easeRise: false, easeFade: false))
        return CoachStyle(colors: colors(dark: false), darkColors: colors(dark: true), profile: profile,
                          cooldownDisplay: .hidden)
    }

    static func glowStyle() -> GlowStyle { GlowStyle(coachStyle()) }

    // MARK: controls

    func joinHint(endsAt: Date?) {
        guard enabled, let endsAt else { return }
        service?.joinHint(endsAt: endsAt)
    }

    @objc func chipClicked(_ sender: Any?) { service?.chipControl() }
    @objc func startClicked(_ sender: Any?) { service?.start() }
    @objc func pauseClicked(_ sender: Any?) { service?.pause() }
    @objc func resumeClicked(_ sender: Any?) { service?.resume() }
    @objc func skipClicked(_ sender: Any?) { service?.skipThisCall() }
    @objc func enableClicked(_ sender: Any?) {
        setEnabled(true) { _ in }
        if !onboarded { showSettings() }
    }
    @objc func turnOffClicked(_ sender: Any?) { setEnabled(false) { _ in } }
    @objc func settingsClicked(_ sender: Any?) { showSettings() }

    func showSettings() {
        let w = settingsWindow ?? CoachSettingsWindow(coach: self)
        settingsWindow = w
        w.present()
    }

    // MARK: indicator

    /// Chip on every visible card, and the coach status menu (always there, so it's a way in while off).
    func refresh() {
        let chip = self.chip
        for c in visibleCards() { c.setCoach(chip) }
        updateStatusItem()
        settingsWindow?.update()
    }

    var menuItems: [CoachMenuItem] { CoachMenu.items(enabled: enabled, indicator: indicator, gptAvailable: gptAvailable) }
    private var shownMenu: (items: [CoachMenuItem], rejected: Bool)?

    private func updateStatusItem() {
        guard showsStatusItem else { return }
        let items = menuItems
        if let shown = shownMenu, shown.items == items, shown.rejected == keyGate.rejected { return }
        shownMenu = (items, keyGate.rejected)
        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        let label = Self.statusLabel(enabled: enabled, indicator: indicator)
        if let button = item.button {
            let image = Theme.symbol(Theme.Coach.symbol, Theme.Coach.statusSymbolFont, label: label)
            image?.isTemplate = true
            button.image = image
            button.appearsDisabled = !enabled || indicator == .paused
            button.toolTip = label
            button.setAccessibilityLabel(label)
        }
        item.menu = menu(for: items)
    }

    /// A native menu for these entries, each with its SF Symbol at the body size.
    func menu(for items: [CoachMenuItem]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        for entry in items { menu.addItem(menuItem(entry)) }
        return menu
    }

    static func statusLabel(enabled: Bool, indicator: CoachIndicator) -> String {
        guard enabled else { return CoachCopy.menuOff }
        switch indicator {
        case .hidden: return CoachCopy.menuWaiting
        case .on: return CoachCopy.coachOn
        case .listening: return CoachCopy.coachListening
        case .paused: return CoachCopy.coachPaused
        }
    }

    private func menuItem(_ entry: CoachMenuItem) -> NSMenuItem {
        let sym = Theme.Coach.menuSymbols
        func image(_ name: String, _ title: String) -> NSImage? {
            Theme.symbol(name, Theme.FontSpec(Theme.Coach.menuSymbolSize), label: title)
        }
        func action(_ title: String, _ symbol: String, _ selector: Selector, key: String = "") -> NSMenuItem {
            let m = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            m.image = image(symbol, title)
            m.target = self
            return m
        }
        func note(_ title: String, _ symbol: String) -> NSMenuItem {
            let m = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            m.image = image(symbol, title)
            m.isEnabled = false
            return m
        }
        switch entry {
        case .status(let st):
            let m: NSMenuItem
            switch st {
            case .off: m = note(CoachCopy.menuOff, Theme.Coach.symbol)
            case .waiting: m = note(CoachCopy.menuWaiting, Theme.Coach.symbol)
            case .on: m = note(CoachCopy.coachOn, Theme.Coach.symbol)
            case .listening: m = note(CoachCopy.coachListening, Theme.Coach.symbol)
            case .paused: m = note(CoachCopy.coachPaused, Theme.Coach.symbol)
            }
            return m
        case .gptOff:
            return keyGate.rejected ? note(CoachCopy.menuGptOffRejected, sym.gptOffRejected)
                                    : note(CoachCopy.menuGptOffNoKey, sym.gptOffNoKey)
        case .enable: return action(CoachCopy.menuEnable, sym.enable, #selector(enableClicked(_:)))
        case .startNow: return action(CoachCopy.startNow, sym.start, #selector(startClicked(_:)))
        case .skipThisCall: return action(CoachCopy.skipThisCall, sym.skip, #selector(skipClicked(_:)))
        case .pause: return action(CoachCopy.pause, sym.pause, #selector(pauseClicked(_:)))
        case .resume: return action(CoachCopy.resume, sym.resume, #selector(resumeClicked(_:)))
        case .turnOff: return action(CoachCopy.menuTurnOff, sym.turnOff, #selector(turnOffClicked(_:)))
        case .separator: return .separator()
        case .settings: return action(CoachCopy.settings, sym.settings, #selector(settingsClicked(_:)), key: ",")
        }
    }

    var statusItemVisible: Bool { statusItem != nil }
}
