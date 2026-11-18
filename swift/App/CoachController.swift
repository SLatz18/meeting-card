import AppKit
import ListenMoreCore
import ListenMoreMac
import MeetingCardCore

/// The call coach inside MeetingCard. Off by default: until the user turns it on (Settings or the
/// coach status menu) there is no service, no Core Audio polling, no capture and no network. It
/// turns on without a key (local cues only); GPT cues need a key OpenAI hasn't rejected. Stores seven
/// settings in UserDefaults (never call data; one is where the coach card was dragged), plus the
/// captions and transcript settings (`CoachTranscript`); the API keys live only in the Keychain. The cue judge
/// (`coach.judgeProvider`, gpt unless set) applies from the next call.
/// "Use Zoom/Meet controls" (off by default) lets Zoom's meeting controls and an open Meet tab stop
/// the coach within seconds of a call ending and hold it while Zoom is muted; its Accessibility and
/// Automation prompts appear only when the user turns it on (or asks again from Settings).
/// While the coach is on for a call, the reminder card morphs into the coach card near the camera
/// (minimizable to a pill), which also mutes Zoom through that setting. The coach menu's own Mute is
/// separate: it only stops the coach listening to the user's mic.
@MainActor
final class CoachController: NSObject {
    enum Keys {
        static let enabled = "coach.enabled"
        static let anyApp = "coach.anyApp"
        static let allowlist = "coach.allowlist"
        static let onboarded = "coach.onboarded"
        static let callControls = "coach.callControls"
        static let judgeProvider = "coach.judgeProvider"
        static let cardPosition = "coach.cardPosition"
    }

    /// MeetingCard's choices on top of the coach's generic config: not_listening and self_pivot nudges are off by default.
    static let configOverrides: [String: Any] = ["cues": ["disabled": [CueType.notListening.rawValue, CueType.selfPivot.rawValue]]]

    /// MeetingCard's Keychain item for the OpenAI key, `<bundle id>.openai` (the Kit's default service is not ours).
    static let keychainService = AppIdentity.current.keychainService

    let defaults: UserDefaults
    let config: ListenMoreConfig
    let keychain: KeychainStore
    /// The TypeSafe key: whatever service the OpenAI key uses, in its own account.
    let typeSafeKeychain: KeychainStore
    /// What the service reads the key through: nil while the stored key is known to be rejected.
    let keyGate: CoachKeyGate
    /// App-level call state for the service; reads nothing while the setting is off.
    let callControls: CallControlsProvider
    /// The coach card's Mute in Zoom control (Zoom only: one press on Zoom's own Mute/Unmute item;
    /// Meet: unavailable, mute in Meet), hosted by the card and pill. Not the coach's own Mute.
    private(set) lazy var callControlsModel = CallControlsModel(provider: callControls, sessionAppKey: { [weak self] in
        MainActor.assumeIsolated { self?.service?.session.session?.appKey }
    })

    /// What the card shows for Mute in Zoom: Mute in Zoom / Unmute in Zoom while it can act, hidden
    /// otherwise (CoachMuteCopy).
    var muteControl: MuteControlPresentation {
        let m = callControlsModel
        return CoachMuteCopy.presentation(reason: m.muteUnavailableReason.map(Self.muteDisabledReason), isMuted: m.isMuted)
    }

    static func muteDisabledReason(_ r: MuteUnavailableReason) -> MuteDisabledReason {
        switch r {
        case .toggleOff: .toggleOff
        case .permissionDenied: .permissionDenied
        case .noZoomCall: .noZoomCall
        case .meet: .meet
        }
    }
    /// Live captions and saved transcripts (off by default).
    let transcript: CoachTranscript
    /// Cards on screen, newest last (the chip goes on each).
    var visibleCards: () -> [Card] = { [] }
    /// The coach status menu: always there, so the coach can be enabled from it while off.
    private let showsStatusItem: Bool
    private(set) var service: CoachService?
    private var statusItem: NSStatusItem?
    private var refreshTimer: Timer?
    private(set) var settingsWindow: CoachSettingsWindow?
    /// Last key problem shown in Settings.
    var keyProblem: KeyCheck?
    /// The coach card, made the first time it shows.
    private(set) var coachCard: CoachCardPresenter?
    private var nudges = CoachNudgeHold()
    private var nudgeTimer: Timer?
    /// Shows the headphones-in-call-mode tip on the card at most once per call.
    private var callModeTracker = CallModeHintTracker()
    /// Shows the mic-cues-off notice (Bluetooth headphones, no built-in mic) at most once per call.
    private var noMicTracker = OncePerCallNotice()
    /// The coach card is the pill (for the rest of this showing).
    private(set) var minimized = false

    init(defaults: UserDefaults = .standard, keychain: KeychainStore = KeychainStore(service: CoachController.keychainService),
         showsStatusItem: Bool = true, transcriptStore: TranscriptStore = FileTranscriptStore()) throws {
        self.defaults = defaults
        self.keychain = keychain
        typeSafeKeychain = keychain.sibling(account: KeychainStore.typeSafeAccount)
        keyGate = CoachKeyGate(keychain)
        self.showsStatusItem = showsStatusItem
        transcript = CoachTranscript(defaults: defaults, store: transcriptStore)
        config = try ListenMoreConfig.load(overrides: Self.configOverrides)
        callControls = .live(config: config)
        super.init()
        callControls.isEnabled = callControlsOn
        callControlsModel.onChange = { [weak self] in self?.refresh() }
        keyStored = keychain.hasKey
        typeSafeKeyStored = typeSafeKeychain.hasKey
        if enabled {
            makeService()
            checkStoredKey()
        }
        refresh()
    }

    var enabled: Bool { defaults.bool(forKey: Keys.enabled) }
    var anyApp: Bool { defaults.bool(forKey: Keys.anyApp) }
    var onboarded: Bool { defaults.bool(forKey: Keys.onboarded) }
    var callControlsOn: Bool { defaults.bool(forKey: Keys.callControls) }
    var hasKey: Bool { keychain.hasKey }
    /// GPT cues can run: a key is stored and OpenAI hasn't rejected it.
    var gptAvailable: Bool { keyStored && !keyGate.rejected }
    /// Captions and transcripts read the GPT cues' transcription: the coach is on with a usable key.
    var transcriptKeyUsable: Bool { enabled && gptAvailable }
    /// Whether a key is in the Keychain, kept current by key actions (refresh runs every second).
    var keyStored = false
    var typeSafeKeyStored = false

    /// The cue judge the next call uses: the user's pick, else the config's (gpt).
    var judgeProvider: JudgeProviderKind { Self.storedJudgeProvider(defaults) ?? config.judge.provider }

    nonisolated static func storedJudgeProvider(_ defaults: UserDefaults) -> JudgeProviderKind? {
        defaults.string(forKey: Keys.judgeProvider).flatMap(JudgeProviderKind.init(rawValue:))
    }

    /// Why judging stopped on the latest call after repeated provider failures (nil while it runs).
    var judgeStopped: JudgeFailure? { previewJudgeStop ?? service?.judgeStopped }
    /// CI screenshots only: a stop reason to show without a call.
    var previewJudgeStop: JudgeFailure?

    func setJudgeProvider(_ kind: JudgeProviderKind) {
        defaults.set(kind.rawValue, forKey: Keys.judgeProvider)
        refresh()
    }

    /// The user's allowlist, or nil for the shipped call apps.
    var allowlist: [String]? { defaults.stringArray(forKey: Keys.allowlist) }
    var effectiveAllowlist: [String] { allowlist ?? config.captureTargets.map(\.bundleId) }

    var indicator: CoachIndicator { enabled ? service?.indicator ?? .hidden : .hidden }
    /// The coach's own Mute is on (the user's mic is off for the coach; the call is still heard).
    var micMuted: Bool { enabled ? service?.micMuted ?? false : false }
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

    /// "Use Zoom/Meet controls". Turning it on asks for the permissions it uses, in context; denied
    /// or later revoked, each app silently goes back to Core Audio.
    func setCallControls(_ on: Bool) {
        defaults.set(on, forKey: Keys.callControls)
        callControls.isEnabled = on
        if on { requestCallControlsAccess() }
        refresh()
    }

    /// Accessibility for Zoom, Automation for whichever of Chrome and Dia is running. Only from the
    /// Settings toggle and its Request access button.
    func requestCallControlsAccess() {
        CallControlsPermissions.requestAccessibility()
        CallControlsPermissions.requestAutomation { [weak self] in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    /// What "Use Zoom/Meet controls" still needs, for the Settings explainer (checks only, never asks).
    struct CallControlsNeeds: Equatable {
        var accessibility = false
        var automation: [String] = []
        var diaUnsupported = false
    }

    /// Browsers seen granted this run (macOS can only tell while the browser is running).
    private var automationGranted: Set<String> = []

    func callControlsNeeds() -> CallControlsNeeds {
        guard callControlsOn else { return CallControlsNeeds() }
        var n = CallControlsNeeds()
        n.accessibility = !CallControlsPermissions.accessibilityTrusted
        for (id, name) in [("com.google.Chrome", "Chrome"), ("company.thebrowser.dia", "Dia")]
        where NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil {
            switch CallControlsPermissions.automation(bundleId: id, ask: false) {
            case .granted: automationGranted.insert(id)
            case .denied, .notAsked: automationGranted.remove(id)
            case .notRunning: break
            }
            if !automationGranted.contains(id) { n.automation.append(name) }
        }
        n.diaUnsupported = callControls.issues["company.thebrowser.dia"] == .unsupported
        return n
    }

    // MARK: service

    private func makeService() {
        let defaults = defaults
        let engine = LocalCoachEngine(transports: .urlSession(), judgeKeys: typeSafeKeychain,
                                      judgeProvider: { Self.storedJudgeProvider(defaults) })
        let s = CoachService(config: config, glowStyle: Self.glowStyle(), enabled: true, anyApp: anyApp,
                             allowlist: allowlist, keys: keyGate, callState: callControls, engine: engine)
        #if MEETINGCARD_TEST_ID
        CoachDebugReadout.shared.attach(mic: s.mic as? MicCapture, coach: self)
        #endif
        s.fallbackScreen = { [weak self] in self?.cardScreen() }
        s.hostWindowNumber = { [weak self] in self?.hostWindowNumber() }
        s.onChange = { [weak self] in self?.refresh() }
        s.onCue = { [weak self] cue in self?.showNudge(cue) }
        s.onCallStart = { [weak self] in self?.transcript.callStarted() }
        s.onCallEnd = { [weak self] in self?.transcript.callEnded() }
        s.onCaption = { [weak self] in self?.transcript.receive($0) }
        s.onMeter = { [weak self] in self?.transcript.record($0) }
        service = s
        let t = Timer(timeInterval: 1, repeats: true) { [weak self] _ in MainActor.assumeIsolated { self?.refresh() } }
        RunLoop.main.add(t, forMode: .common)
        refreshTimer = t
        refresh()
    }

    /// The coach card's display while it shows, else the newest reminder card's.
    private func cardScreen() -> NSRect? {
        if let c = coachCard, c.isShown, let f = c.panel.screen?.frame { return f }
        return visibleCards().last?.panel.screen?.frame ?? NSScreen.main?.frame
    }

    /// The glow goes behind the coach card while it shows, else behind the newest reminder card.
    private func hostWindowNumber() -> Int? {
        if let c = coachCard, c.isShown { return c.panel.windowNumber }
        return visibleCards().last?.panel.windowNumber
    }

    /// The Kit's coach style from MeetingCard's tokens: rose and amber per appearance at standard
    /// contrast, the card's corner radius, a one-control-height band and the Increase Contrast peak
    /// (Theme.Glow). The Kit draws only what it's given.
    static func coachStyle() -> CoachStyle {
        func kit(_ c: RGBA) -> CoachStyle.RGBA { CoachStyle.RGBA(red: c.r, green: c.g, blue: c.b, alpha: c.a) }
        func colors(dark: Bool) -> [CueColor: CoachStyle.RGBA] {
            [.red: kit(Theme.Glow.rose(dark: dark)), .amber: kit(Theme.Glow.amber(dark: dark))]
        }
        let g = Theme.Glow.self
        let profile = GlowProfile(
            width: g.width, peakOpacity: g.peakOpacity, increasedContrastPeakOpacity: g.increasedContrastPeakOpacity,
            cornerRadius: g.cornerRadius,
            stops: g.stops.map { GlowProfile.Stop($0.at, $0.factor) },
            motion: .init(rise: g.rise, hold: g.hold, fade: g.fade, appearFactor: 0, easeRise: true, easeFade: true),
            reduceMotion: .init(rise: 0, hold: 0, fade: g.reduceMotionFade, appearFactor: g.reduceMotionAppear,
                                easeRise: false, easeFade: false))
        return CoachStyle(colors: colors(dark: false), darkColors: colors(dark: true), profile: profile,
                          cooldownDisplay: .hidden)
    }

    /// The glow as drawn: rose and amber are dynamic semantic colors (systemRed / systemOrange,
    /// muted), so they follow dark mode and Increase Contrast; shape and timing from `coachStyle()`.
    static func glowStyle() -> GlowStyle {
        let g = Theme.Glow.self
        return GlowStyle(rose: CardStyle.dynamic(g.roseSource) { g.rose(base: $0, dark: $1) },
                         amber: CardStyle.dynamic(g.amberSource) { g.amber(base: $0, dark: $1) },
                         profile: coachStyle().profile)
    }

    // MARK: controls

    func joinHint(endsAt: Date?) {
        guard enabled, let endsAt else { return }
        service?.joinHint(endsAt: endsAt)
    }

    @objc func chipClicked(_ sender: Any?) { service?.chipControl() }
    /// Start Coach: while the coach is off it switches it on (switching it off is in Settings);
    /// while it waits for a call it starts listening now.
    @objc func startClicked(_ sender: Any?) {
        if enabled { service?.start() } else { enableClicked(sender) }
    }
    @objc func pauseClicked(_ sender: Any?) { service?.pause() }
    @objc func resumeClicked(_ sender: Any?) { service?.resume() }
    @objc func muteMicClicked(_ sender: Any?) { setMicMuted(true) }
    @objc func unmuteMicClicked(_ sender: Any?) { setMicMuted(false) }
    @objc func stopClicked(_ sender: Any?) { stopForThisCall() }
    @objc func enableClicked(_ sender: Any?) {
        setEnabled(true) { _ in }
        if !onboarded { showSettings() }
    }
    @objc func settingsClicked(_ sender: Any?) { showSettings() }
    @objc func feedbackClicked(_ sender: Any?) { FeedbackAction.send(defaults: defaults) }

    /// Stop: the coach is off for the rest of this call (replaces Skip this call).
    func stopForThisCall() {
        service?.stopForThisCall()
        CoachCardPresenter.announce(CoachCardCopy.A11y.skipped)
        refresh()
    }

    /// One press of Zoom's own Mute/Unmute item (on the provider's queue); the card follows the read-back.
    func toggleMute() {
        callControlsModel.toggleMute()
    }

    /// The coach's own Mute, from the coach menu: it stops listening to the user's mic only (never the
    /// call app's mute, no Accessibility). Lasts until Unmute or the session ends.
    func setMicMuted(_ muted: Bool) {
        guard let service, service.micMuted != muted else { return }
        service.setMicMuted(muted)
        guard service.micMuted == muted else { return }
        CoachCardPresenter.announce(muted ? CoachCopy.micMutedAnnouncement : CoachCopy.micUnmutedAnnouncement)
        refresh()
    }

    /// The pill's Mute: the coach's own, flipped.
    func toggleMicMuted() {
        setMicMuted(!micMuted)
    }

    func pauseOrResume() {
        if indicator == .paused { service?.resume() } else { service?.pause() }
    }

    func toggleMinimized() {
        minimized.toggle()
        refresh()
    }

    /// A cue that arrives while the coach isn't listening is neither shown nor announced.
    private func showNudge(_ cue: Cue) {
        let status = enabled ? CoachCardState.Status(indicator) : nil
        guard let n = CoachNudge(cue), nudges.show(n, now: ProcessInfo.processInfo.systemUptime, status: status) else { return }
        CoachCardPresenter.announce(n.announcement)
        scheduleNudgeStep()
        refresh()
    }

    /// Redraws when a cue's words give way to its lingering glyph, and again when the glyph clears.
    private func scheduleNudgeStep() {
        stopNudgeTimer()
        guard let wait = nudges.nextChange(now: ProcessInfo.processInfo.systemUptime) else { return }
        let t = Timer(timeInterval: wait, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.refresh()
                self?.scheduleNudgeStep()
            }
        }
        RunLoop.main.add(t, forMode: .common)
        nudgeTimer = t
    }

    private func stopNudgeTimer() {
        nudgeTimer?.invalidate()
        nudgeTimer = nil
    }

    func showSettings() {
        let w = settingsWindow ?? CoachSettingsWindow(coach: self)
        settingsWindow = w
        w.present()
    }

    // MARK: indicator

    /// The coach card while the coach is on for a call (the chip on the cards otherwise), and the
    /// coach status menu (always there, so it's a way in while off).
    func refresh() {
        let card = coachCardState()
        let chip = card == nil ? self.chip : nil
        for c in visibleCards() { c.setCoach(chip) }
        transcript.sync(keyUsable: transcriptKeyUsable)
        if let reason = service?.gptStopped { transcript.gptStopped(reason) }
        updateCoachCard(card)
        updateStatusItem()
        settingsWindow?.update()
    }

    /// What the coach card shows now, or nil while the coach isn't on for a call.
    func coachCardState() -> CoachCardState? {
        let listening = enabled && indicator == .listening
        callModeTracker.update(call: service?.session.session?.startedAt,
                               callMode: listening && ((service?.mic as? MicCapture)?.headphonesInCallMode() ?? false))
        noMicTracker.update(call: service?.session.session?.startedAt,
                            callMode: listening && ((service?.mic as? MicCapture)?.noMicStatus ?? false))
        let status = enabled ? CoachCardState.Status(indicator) : nil
        if nudges.follow(status) { stopNudgeTimer() }
        guard let status else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        nudges.expire(now: now)
        var state = CoachCardState(status: status, mute: muteControl, micMuted: callControlsModel.isMuted, coachMicMuted: micMuted,
                                   nudge: nudges.active(now: now), lingering: nudges.lingering(now: now),
                                   mode: minimized ? .pill : .card,
                                   increasedContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast,
                                   savingBadge: transcript.live.recorder.isSaving ? CoachCopy.savingNow : nil)
        state.callModeTip = callModeTracker.visible
        state.noMicNotice = noMicTracker.visible
        return state
    }

    func dismissCallModeTip() {
        if noMicTracker.visible { noMicTracker.dismiss() } else { callModeTracker.dismiss() }
        refresh()
    }

    private func updateCoachCard(_ s: CoachCardState?) {
        guard let s else {
            nudges.clear()
            stopNudgeTimer()
            guard let c = coachCard, c.isShown else { return }
            let card = c.hide()
            minimized = false
            if let card, visibleCards().contains(where: { $0 === card }) { card.panel.orderFrontRegardless() }
            return
        }
        let c = coachCard ?? makeCoachCard()
        coachCard = c
        if c.isShown { c.update(s) } else { c.show(s, from: visibleCards().last) }
    }

    private func makeCoachCard() -> CoachCardPresenter {
        let p = CoachCardPresenter(defaults: defaults, positionKey: Keys.cardPosition, captions: CaptionFeedSlot(model: transcript.feed))
        p.actions = CoachCardActions(stop: { [weak self] in self?.stopForThisCall() },
                                     mute: { [weak self] in self?.toggleMute() },
                                     muteMic: { [weak self] in self?.toggleMicMuted() },
                                     pause: { [weak self] in self?.pauseOrResume() },
                                     resize: { [weak self] in self?.toggleMinimized() },
                                     dismissCallModeTip: { [weak self] in self?.dismissCallModeTip() })
        p.callScreen = { [weak self] in self?.service?.glowScreen }
        return p
    }

    var menuItems: [CoachMenuItem] { CoachMenu.items(enabled: enabled, indicator: indicator, gptAvailable: gptAvailable, micMuted: micMuted) }
    private var shownMenu: (items: [CoachMenuItem], rejected: Bool, transcript: [Bool])?

    private func updateStatusItem() {
        guard showsStatusItem else { return }
        let items = menuItems
        let saved = [transcript.live.recorder.isSaving, transcript.canDelete]
        if let shown = shownMenu, shown.items == items, shown.rejected == keyGate.rejected, shown.transcript == saved { return }
        shownMenu = (items, keyGate.rejected, saved)
        let item = statusItem ?? NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem = item
        let label = Self.statusLabel(enabled: enabled, indicator: indicator)
        if let button = item.button {
            let image = Theme.symbol(Theme.Coach.symbol, Theme.Coach.statusSymbolFont, label: label)
            image?.isTemplate = true
            button.image = image
            button.appearsDisabled = !enabled || indicator == .paused || indicator == .muted || indicator == .micOff
            button.toolTip = label
            button.setAccessibilityLabel(label)
        }
        item.menu = menu(for: items)
    }

    /// A native menu for these entries, each with its SF Symbol at the body size, then the saved
    /// transcript's entries (saving now, delete) when there is one, then Send Feedback.
    func menu(for items: [CoachMenuItem]) -> NSMenu {
        let menu = NSMenu()
        menu.autoenablesItems = false
        #if MEETINGCARD_TEST_ID
        menu.delegate = CoachDebugReadout.shared
        #endif
        for entry in items {
            menu.addItem(menuItem(entry))
            #if MEETINGCARD_TEST_ID
            if entry == .settings { menu.addItem(CoachDebugReadout.shared.menuItem()) }
            if entry == .settings { menu.addItem(CoachCueDisplayLab.shared.menuItem()) }
            if case .status = entry { menu.addItem(CoachDebugReadout.shared.statusMenuItem()) }
            #endif
        }
        addTranscriptItems(to: menu)
        menu.addItem(feedbackMenuItem())
        return menu
    }

    /// The saved transcript's entries: Saving transcript while one is written, Delete Transcript…
    /// while there is one to delete; nothing otherwise.
    private func addTranscriptItems(to menu: NSMenu) {
        let saving = transcript.live.recorder.isSaving
        guard saving || transcript.canDelete else { return }
        let sym = Theme.Captions.menuSymbols
        let size = Theme.FontSpec(Theme.Coach.menuSymbolSize)
        menu.addItem(.separator())
        if saving {
            let m = NSMenuItem(title: CoachCopy.menuSaving, action: nil, keyEquivalent: "")
            m.image = Theme.symbol(sym.saving, size, label: CoachCopy.menuSaving)
            m.isEnabled = false
            menu.addItem(m)
        }
        if transcript.canDelete {
            let m = NSMenuItem(title: CoachCopy.menuDeleteTranscript, action: #selector(deleteTranscriptClicked(_:)), keyEquivalent: "")
            m.image = Theme.symbol(sym.delete, size, label: CoachCopy.menuDeleteTranscript)
            m.target = self
            menu.addItem(m)
        }
    }

    private func feedbackMenuItem() -> NSMenuItem {
        let title = FeedbackCopy.menuItem
        let m = NSMenuItem(title: title, action: #selector(feedbackClicked(_:)), keyEquivalent: "")
        m.image = Theme.symbol(Theme.Coach.menuSymbols.feedback, Theme.FontSpec(Theme.Coach.menuSymbolSize), label: title)
        m.target = self
        return m
    }

    @objc func deleteTranscriptClicked(_ sender: Any?) {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = CoachCopy.deleteConfirmTitle
        alert.informativeText = CoachCopy.deleteConfirmBody
        alert.addButton(withTitle: CoachCopy.delete).hasDestructiveAction = true
        alert.addButton(withTitle: CoachCopy.cancel)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        transcript.deleteTranscript()
        refresh()
    }

    static func statusLabel(enabled: Bool, indicator: CoachIndicator) -> String {
        guard enabled else { return CoachCopy.menuOff }
        switch indicator {
        case .hidden: return CoachCopy.menuWaiting
        case .on: return CoachCopy.coachOn
        case .listening: return CoachCopy.coachListening
        case .paused: return CoachCopy.coachPaused
        case .muted: return CoachCopy.coachMuted
        case .micOff: return CoachCopy.coachMicOff
        }
    }

    private func menuItem(_ entry: CoachMenuItem) -> NSMenuItem {
        let sym = Theme.Coach.menuSymbols
        func image(_ name: String, _ title: String) -> NSImage? {
            Theme.symbol(name, Theme.FontSpec(Theme.Coach.menuSymbolSize), label: title)
        }
        func action(_ title: String, _ symbol: String, _ selector: Selector, key: String = "", tooltip: String? = nil) -> NSMenuItem {
            let m = NSMenuItem(title: title, action: selector, keyEquivalent: key)
            m.image = image(symbol, title)
            m.target = self
            m.toolTip = tooltip
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
            case .muted: m = note(CoachCopy.coachMuted, Theme.CallControls.mutedSymbol)
            case .micOff: m = note(CoachCopy.coachMicOff, Theme.Coach.micOffSymbol)
            }
            return m
        case .gptOff:
            return keyGate.rejected ? note(CoachCopy.menuGptOffRejected, sym.gptOffRejected)
                                    : note(CoachCopy.menuGptOffNoKey, sym.gptOffNoKey)
        case .startCoach: return action(CoachCopy.menuStart, sym.start, #selector(startClicked(_:)))
        case .stopCoach: return action(CoachCopy.menuStop, sym.stop, #selector(stopClicked(_:)), tooltip: CoachCardCopy.Tooltip.stop)
        case .pause: return action(CoachCopy.pause, sym.pause, #selector(pauseClicked(_:)))
        case .resume: return action(CoachCopy.resume, sym.resume, #selector(resumeClicked(_:)))
        case .muteMic: return action(CoachCopy.menuMute, sym.mute, #selector(muteMicClicked(_:)), tooltip: CoachCopy.menuMuteHelp)
        case .unmuteMic: return action(CoachCopy.menuUnmute, sym.unmute, #selector(unmuteMicClicked(_:)), tooltip: CoachCopy.menuUnmuteHelp)
        case .separator: return .separator()
        case .settings: return action(CoachCopy.settings, sym.settings, #selector(settingsClicked(_:)), key: ",")
        }
    }

    var statusItemVisible: Bool { statusItem != nil }
}
