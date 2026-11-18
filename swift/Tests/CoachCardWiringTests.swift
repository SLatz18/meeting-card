import XCTest
@testable import MeetingCardCore

/// How the App wires the coach card (hostless tests can't load AppKit panels, so these read the
/// sources): one panel that screen shares always leave out, Stop and Mute doing what they say,
/// placement without window reads, the captions slot, and the snapshot gate.
final class CoachCardWiringTests: XCTestCase {
    static let swiftDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    func read(_ path: String) throws -> String {
        try String(contentsOf: Self.swiftDir.appendingPathComponent(path), encoding: .utf8)
    }

    func code(_ text: String) -> String {
        text.components(separatedBy: "\n").filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }.joined(separator: "\n")
    }

    static let cardFiles = ["App/CoachCardView.swift", "App/CoachCardPanel.swift", "App/CoachCaptions.swift"]

    /// Card, pill, morph and nudges all draw in the one coach panel, whose sharingType can only be `.none`.
    func testEveryCoachStateDrawsInThePanelScreenSharesLeaveOut() throws {
        let panel = try read("App/CoachCardPanel.swift")
        XCTAssertTrue(panel.contains("override var sharingType: NSWindow.SharingType {\n        get { super.sharingType }\n        set { super.sharingType = .none }"))
        XCTAssertTrue(panel.contains("p.sharingType = .none"))
        XCTAssertTrue(panel.contains("let panel = CoachCardPanel.make()"), "the presenter has one panel")
        let windows = try NSRegularExpression(pattern: #"\b(NSPanel|NSWindow|CardPanelWindow)\("#)
        for f in Self.cardFiles + ["App/CoachController.swift"] {
            let c = code(try read(f))
            XCTAssertNil(windows.firstMatch(in: c, range: NSRange(c.startIndex..., in: c)), "\(f) makes another window")
            XCTAssertFalse(c.contains(".readOnly"), "\(f) lets a share see the coach card")
        }
        XCTAssertEqual(code(panel).components(separatedBy: "CoachCardPanel(contentRect:").count - 1, 1)
        // The morph shows the reminder card's image inside the coach panel, and hides the card itself.
        XCTAssertTrue(panel.contains("outgoing.image = NSImage(cgImage: image, size: start.size)"))
        XCTAssertTrue(panel.contains("card.panel.orderOut(nil)"))
        XCTAssertEqual(Set(CoachSurface.allCases.map(\.sharing)), [.excluded])
    }

    /// Stop ends the coach for this call, says so to VoiceOver, and replaces Skip this call everywhere.
    func testStopReplacesSkipThisCall() throws {
        let controller = try read("App/CoachController.swift")
        let body = try XCTUnwrap(controller.components(separatedBy: "func stopForThisCall() {").dropFirst().first?
            .components(separatedBy: "\n    }").first)
        XCTAssertTrue(body.contains("service?.stopForThisCall()"))
        XCTAssertTrue(body.contains("CoachCardPresenter.announce(CoachCardCopy.A11y.skipped)"))
        XCTAssertTrue(controller.contains("case .stopCoach: return action(CoachCopy.menuStop, sym.stop, #selector(stopClicked(_:)), tooltip: CoachCardCopy.Tooltip.stop)"))
        XCTAssertTrue(controller.contains("stop: { [weak self] in self?.stopForThisCall() }"))
        for f in ["App/CoachCopy.swift", "App/CoachController.swift"] + Self.cardFiles {
            let c = try read(f)
            XCTAssertFalse(c.contains("Skip This Call") || c.contains("skipThisCall") || c.contains("skipClicked"), "\(f) keeps Skip this call")
        }
    }

    /// Mute in Zoom is CallControlsModel's one press of Zoom's own control; it never pauses or stops the
    /// coach's capture, and shows only while it can act. The pill's own Mute is the coach's (mic only).
    func testMuteUsesTheCallAppsOwnControl() throws {
        let controller = try read("App/CoachController.swift")
        let body = try XCTUnwrap(controller.components(separatedBy: "func toggleMute() {").dropFirst().first?
            .components(separatedBy: "\n    }").first)
        XCTAssertEqual(body.trimmingCharacters(in: .whitespacesAndNewlines), "callControlsModel.toggleMute()")
        XCTAssertTrue(controller.contains("mute: { [weak self] in self?.toggleMute() }"))
        XCTAssertTrue(controller.contains("CallControlsModel(provider: callControls, sessionAppKey:"), "the same opt-in setting")
        XCTAssertTrue(controller.contains("callControlsModel.onChange = { [weak self] in self?.refresh() }"), "follows the read-back")
        XCTAssertTrue(controller.contains("CoachCardState(status: status, mute: muteControl, micMuted: callControlsModel.isMuted"))
        let view = try read("App/CoachCardView.swift")
        XCTAssertTrue(view.contains("b.toolTip = c.tooltip") && view.contains("b.setAccessibilityHelp(c.accessibilityHelp)"))
        XCTAssertTrue(view.contains("b.setAccessibilityLabel(c.accessibilityLabel)"), "VoiceOver reads each control's own label")
        XCTAssertEqual(view.components(separatedBy: "set(mute, s.muteControl,").count - 1, 2, "card and pill share the one mapping")
        XCTAssertTrue(try read("App/UISnapshots.swift").contains("static let noZoomMute = CoachMuteCopy.presentation(reason: .toggleOff, isMuted: false)"))
        // The pill's Mute is the coach's own; Mute in Zoom sits beside it only while it can act.
        XCTAssertTrue(controller.contains("muteMic: { [weak self] in self?.toggleMicMuted() }"))
        XCTAssertTrue(controller.contains("coachMicMuted: micMuted"))
        let toggle = try XCTUnwrap(controller.components(separatedBy: "func toggleMicMuted() {").dropFirst().first?
            .components(separatedBy: "\n    }").first)
        XCTAssertEqual(toggle.trimmingCharacters(in: .whitespacesAndNewlines), "setMicMuted(!micMuted)")
        XCTAssertTrue(view.contains("set(micMute, s.coachMuteControl, glyph: p.buttonGlyph)"))
        XCTAssertTrue(view.contains("let shown: [CardButton] = state.showsMute ? [micMute, mute, pause, stop] : [micMute, pause, stop]"))
        XCTAssertTrue(view.contains("@objc func muteMicPressed(_ sender: Any?) { actions.muteMic() }"))
        XCTAssertTrue(view.contains("b.isEnabled = c.enabled"))
    }

    /// The menu's, the pill's and the card's Mute share one path: menu items and both surfaces' button
    /// end in `CoachController.setMicMuted`, the only place the App reaches the service's Mute, and
    /// card and pill draw the same `coachMuteControl`.
    func testMenuPillAndCardShareOneMutePath() throws {
        let controller = try read("App/CoachController.swift"), view = try read("App/CoachCardView.swift")
        let app = Self.swiftDir.appendingPathComponent("App")
        let calls = try FileManager.default.contentsOfDirectory(atPath: app.path).filter { $0.hasSuffix(".swift") }
            .map { try read("App/" + $0).components(separatedBy: "service.setMicMuted(").count - 1 }.reduce(0, +)
        XCTAssertEqual(calls, 1, "one call site for the coach's Mute")
        let set = try XCTUnwrap(controller.components(separatedBy: "func setMicMuted(_ muted: Bool) {").dropFirst().first?
            .components(separatedBy: "\n    }").first)
        XCTAssertTrue(set.contains("service.setMicMuted(muted)"), "the call site is setMicMuted")
        XCTAssertTrue(controller.contains("@objc func muteMicClicked(_ sender: Any?) { setMicMuted(true) }"), "menu Mute")
        XCTAssertTrue(controller.contains("@objc func unmuteMicClicked(_ sender: Any?) { setMicMuted(false) }"), "menu Unmute")
        let toggle = try XCTUnwrap(controller.components(separatedBy: "func toggleMicMuted() {").dropFirst().first?
            .components(separatedBy: "\n    }").first)
        XCTAssertEqual(toggle.trimmingCharacters(in: .whitespacesAndNewlines), "setMicMuted(!micMuted)")
        XCTAssertEqual(controller.components(separatedBy: "muteMic: { [weak self] in self?.toggleMicMuted() }").count - 1, 1,
                       "one action, handed to the presenter that hosts both the card and the pill")
        XCTAssertEqual(view.components(separatedBy: "@objc func muteMicPressed(_ sender: Any?) { actions.muteMic() }").count - 1, 1,
                       "one handler, on the surface both views share")
        XCTAssertEqual(view.components(separatedBy: "#selector(muteMicPressed(_:))").count - 1, 2, "the card's button and the pill's")
        XCTAssertEqual(view.components(separatedBy: "set(micMute, s.coachMuteControl,").count - 1, 2, "drawn from the same control")
    }

    /// Placement reads no window: the call's display is the one the glow already found.
    func testPlacementReadsNoWindows() throws {
        for f in Self.cardFiles + ["App/CoachController.swift"] {
            let c = code(try read(f))
            for banned in ["CGWindowListCopyWindowInfo", "CallDisplayLocator", "AXUIElement", "kAX", "locateScreen", ".windows"] {
                XCTAssertFalse(c.contains(banned), "\(f) reads \(banned)")
            }
        }
        XCTAssertTrue(try read("App/CoachController.swift").contains("p.callScreen = { [weak self] in self?.service?.glowScreen }"))
        // glowScreen is whatever the service's locateScreen seam chose, so a better window choice there moves the card too.
        let service = try read("Packages/ListenMoreKit/Sources/ListenMoreMac/CoachService.swift")
        XCTAssertTrue(service.contains("let screen = self.locateScreen(self.session.session?.appKey, self.fallbackScreen())\n            self.glowScreen = screen"))
        XCTAssertEqual(code(service).components(separatedBy: "glowScreen = ").count - 1, 2, "set only from locateScreen (and cleared)")
        let panel = try read("App/CoachCardPanel.swift")
        XCTAssertTrue(panel.contains("CoachPlacement.display(call:"))
        XCTAssertTrue(panel.contains("safeAreaTop: Double(s.safeAreaInsets.top), builtIn: CGDisplayIsBuiltin(n) != 0"))
        XCTAssertTrue(panel.contains("defaults.set([o.dx, o.dy], forKey: positionKey)"), "a drag is remembered")
        // Remembered in the app's own defaults domain (its bundle id, so per AppIdentity), never a named suite.
        XCTAssertTrue(try read("App/CoachController.swift").contains("CoachCardPresenter(defaults: defaults, positionKey: Keys.cardPosition"))
        XCTAssertTrue(try read("App/UISnapshots.swift").contains("let suite = AppIdentity.current.scoped(\"snapshots\")\n        guard let defaults = UserDefaults(suiteName: suite) else { return }\n        defaults.removePersistentDomain(forName: suite)\n        let tag"))
        for f in Self.cardFiles { XCTAssertFalse(code(try read(f)).contains("UserDefaults("), "\(f) opens its own defaults") }
        let theme = try read("Core/Theme.swift")
        XCTAssertTrue(theme.contains("public static let callBarClearance: Double = 52"))
        let comment = try XCTUnwrap(theme.components(separatedBy: "public static let callBarClearance").first?
            .components(separatedBy: "\n").suffix(3).joined(separator: "\n"))
        XCTAssertTrue(comment.contains("UNVERIFIED") && comment.contains("Mac hand check"), comment)
    }

    /// Nudges are announced to VoiceOver (unchanged), show their words for `nudgeHold`, then linger
    /// as a glyph until `cueLinger`: a timer redraws at each step.
    func testNudgesAreAnnouncedLingerAndExpire() throws {
        let controller = try read("App/CoachController.swift")
        XCTAssertTrue(controller.contains("s.onCue = { [weak self] cue in self?.showNudge(cue) }"))
        XCTAssertTrue(controller.contains("CoachCardPresenter.announce(n.announcement)"))
        // A cue that arrives while not listening is neither shown nor announced: the status gate comes first.
        let show = try XCTUnwrap(controller.components(separatedBy: "private func showNudge(_ cue: Cue) {").dropFirst().first?
            .components(separatedBy: "\n    }").first)
        let gate = try XCTUnwrap(show.range(of: "guard let n = CoachNudge(cue), nudges.show(n, now: ProcessInfo.processInfo.systemUptime, status: status) else { return }"))
        let announce = try XCTUnwrap(show.range(of: "CoachCardPresenter.announce(n.announcement)"))
        XCTAssertLessThan(gate.lowerBound, announce.lowerBound, "gated before the announcement")
        XCTAssertTrue(show.contains("let status = enabled ? CoachCardState.Status(indicator) : nil"))
        XCTAssertEqual(controller.components(separatedBy: "CoachCardPresenter.announce(").count - 1, 3,
                       "the nudge, Stop and the coach's Mute only: the linger announces nothing")
        XCTAssertTrue(controller.contains("guard let wait = nudges.nextChange(now: ProcessInfo.processInfo.systemUptime) else { return }"))
        XCTAssertTrue(controller.contains("Timer(timeInterval: wait, repeats: false)"))
        XCTAssertTrue(controller.contains("nudge: nudges.active(now: now), lingering: nudges.lingering(now: now)"))
        // A cue from before a pause, a mute or the call's end is dropped before the state is built, and
        // its timer stops; hiding the card does both too.
        let state = try XCTUnwrap(controller.components(separatedBy: "func coachCardState() -> CoachCardState? {").dropFirst().first?
            .components(separatedBy: "\n    }").first)
        let follow = try XCTUnwrap(state.range(of: "if nudges.follow(status) { stopNudgeTimer() }"))
        let build = try XCTUnwrap(state.range(of: "nudge: nudges.active(now: now)"))
        XCTAssertLessThan(follow.lowerBound, build.lowerBound, "dropped before the state reads it")
        XCTAssertTrue(controller.contains("guard let s else {\n            nudges.clear()\n            stopNudgeTimer()"), "the card hides: cue and timer go")
        XCTAssertTrue(try read("App/CoachCardPanel.swift").contains("notification: .announcementRequested"))
    }

    /// Increase Contrast reaches the cue on both surfaces: the controller reads the system setting, the
    /// card's band and the pill's cue bar take their alpha from it, and the lingering glyph is a
    /// semantic text role (which follows it).
    func testCueHonorsIncreaseContrast() throws {
        XCTAssertTrue(try read("App/CoachController.swift").contains("increasedContrast: NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast"))
        let view = try read("App/CoachCardView.swift")
        XCTAssertTrue(view.contains("CardStyle.Coach.nudgeEdgeAlpha(dark: dark, increasedContrast: state.increasedContrast)"), "the pill's cue bar")
        XCTAssertTrue(view.contains("let ic = state.increasedContrast"), "the card's band")
        XCTAssertTrue(view.contains("Theme.text(Theme.CoachCard.lingerGlyphText, style)"), "the lingering glyph's semantic role")
        XCTAssertFalse(view.contains("increasedContrast: false"))
        XCTAssertEqual(Theme.CoachCard.lingerGlyphText, .secondary, "a system label color: Increase Contrast darkens it")
    }

    /// not_listening and self_pivot nudges are off unless MeetingCard turns them on.
    func testNotListeningIsOffByDefault() throws {
        let controller = try read("App/CoachController.swift")
        XCTAssertTrue(controller.contains("static let configOverrides: [String: Any] = [\"cues\": [\"disabled\": [CueType.notListening.rawValue, CueType.selfPivot.rawValue]]]"))
        XCTAssertTrue(controller.contains("config = try ListenMoreConfig.load(overrides: Self.configOverrides)"))
    }

    /// #13c's caption feed drops into the slot; the placeholder stays for hosts without a feed.
    func testCaptionsAreHostedThroughASlot() throws {
        let captions = try read("App/CoachCaptions.swift")
        XCTAssertTrue(captions.contains("protocol CoachCaptionsSlot: AnyObject {\n    func makeView() -> NSView\n}"))
        XCTAssertTrue(captions.contains("NSTextField(wrappingLabelWithString: CoachCardCopy.Captions.empty)"))
        XCTAssertTrue(try read("App/CoachCardPanel.swift").contains("let c = captionsView ?? captions.makeView()"))
        XCTAssertTrue(try read("App/CoachController.swift").contains("captions: CaptionFeedSlot(model: transcript.feed)"))
        XCTAssertTrue(captions.contains("NSHostingView(rootView: CaptionFeedView(model: model, layout: .card))"))
        // The saving badge rides the status line while (and only while) a transcript is being written.
        XCTAssertTrue(try read("App/CoachController.swift").contains("savingBadge: transcript.live.recorder.isSaving ? CoachCopy.savingNow : nil)"))
        let view = try read("App/CoachCardView.swift")
        XCTAssertTrue(view.contains("applyBadge(s.savingBadge)"))
        XCTAssertTrue(view.contains("private let badgeLabel = NSTextField(labelWithString: \"\")"), "a plain label, never truncated")
    }

    /// The motion the App runs is CoachMotion's (Reduce Motion included); windows still appear without AppKit animation.
    func testMotionComesFromTheTokens() throws {
        let panel = try read("App/CoachCardPanel.swift")
        XCTAssertTrue(panel.contains("let steps = CoachMotion.steps(t, reduceMotion: reduceMotion())"))
        XCTAssertTrue(panel.contains("NSWorkspace.shared.accessibilityDisplayShouldReduceMotion"))
        XCTAssertTrue(panel.contains("p.animationBehavior = CardStyle.Material.animates ? .default : .none"))
        XCTAssertTrue(panel.contains("run(.morph, to: target, outgoing: outgoing, incoming: incoming)"), "Reduce Motion: straight to the spot")
        XCTAssertTrue(panel.contains("self?.run(.glide, to: target, outgoing: nil, incoming: incoming)"), "morph in place, then glide")
    }

    /// The headphones-in-call-mode tip: the controller feeds the Kit's tracker from Core Audio state (through the mic)
    /// and the call's start, only while listening; the card shows it on the full card only, and Dismiss ends it.
    func testCallModeTipIsFedFromTheMicAndTheSessionStart() throws {
        let controller = try read("App/CoachController.swift")
        XCTAssertTrue(controller.contains("private var callModeTracker = CallModeHintTracker()"))
        XCTAssertTrue(controller.contains("let listening = enabled && indicator == .listening"))
        XCTAssertTrue(controller.contains("callModeTracker.update(call: service?.session.session?.startedAt,"), "the call is its start time")
        XCTAssertTrue(controller.contains("callMode: listening && ((service?.mic as? MicCapture)?.headphonesInCallMode() ?? false))"),
                      "call mode only while listening, from the mic's Core Audio state")
        XCTAssertTrue(controller.contains("state.callModeTip = callModeTracker.visible"))
        let body = try XCTUnwrap(controller.components(separatedBy: "func dismissCallModeTip() {").dropFirst().first?
            .components(separatedBy: "\n    }").first)
        XCTAssertEqual(body.trimmingCharacters(in: .whitespacesAndNewlines),
                       "if noMicTracker.visible { noMicTracker.dismiss() } else { callModeTracker.dismiss() }\n        refresh()",
                       "one Dismiss: the no-mic notice first, otherwise the call-mode tip")
        XCTAssertTrue(controller.contains("dismissCallModeTip: { [weak self] in self?.dismissCallModeTip() }"))

        let view = try read("App/CoachCardView.swift")
        XCTAssertTrue(view.contains("var dismissCallModeTip: () -> Void = {}"))
        XCTAssertTrue(view.contains("@objc func dismissCallModeTipPressed(_ sender: Any?) { actions.dismissCallModeTip() }"))
        XCTAssertTrue(view.contains("tipTitle.stringValue = s.noMicNotice ? CoachCardCopy.NoMicNotice.title : CoachCardCopy.CallModeTip.title"))
        XCTAssertTrue(view.contains("tipLabel.stringValue = s.noMicNotice ? CoachCardCopy.NoMicNotice.body : CoachCardCopy.CallModeTip.body"))
        XCTAssertTrue(view.contains("tipLabel.setAccessibilityLabel(s.noMicNotice ? CoachCardCopy.NoMicNotice.accessibilityLabel : CoachCardCopy.CallModeTip.accessibilityLabel)"))
        XCTAssertTrue(view.contains("Card.attr(s.noMicNotice ? CoachCardCopy.NoMicNotice.dismiss : CoachCardCopy.CallModeTip.dismiss,"))
        XCTAssertTrue(view.contains("tipLabel.isHidden = !s.tipRow"))
        XCTAssertTrue(view.contains("dismissTip.isHidden = !s.tipRow"))
        XCTAssertTrue(view.contains("height: Theme.CoachCard.cardHeight(tipRow: s.tipRow)"), "the card's size counts the row")
        let pill = try XCTUnwrap(view.components(separatedBy: "final class CoachPillView").dropFirst().first)
        XCTAssertFalse(pill.contains("callModeTip") || pill.contains("CallModeTip") || pill.contains("noMicNotice") || pill.contains("NoMicNotice"),
                       "the pill never shows the tip or the notice")
        let panel = try read("App/CoachCardPanel.swift")
        XCTAssertTrue(panel.contains("CoachFullCardView.frameSize(for: s) != current.frame.size"), "the panel resizes when the row comes or goes")
        for f in Self.cardFiles + ["App/CoachController.swift"] {
            let c = code(try read(f))
            XCTAssertFalse(c.contains("outputCallState"), "\(f) reads Core Audio itself")
        }
    }

    /// The no-mic notice: the controller feeds a second once-per-call tracker from the mic's `noMicStatus`, only while
    /// listening; one Dismiss handles it and the call-mode tip; Settings shows its note only behind the Kit's check.
    func testNoMicNoticeIsFedFromTheMicAndShownInSettings() throws {
        let controller = try read("App/CoachController.swift")
        XCTAssertTrue(controller.contains("private var noMicTracker = OncePerCallNotice()"))
        XCTAssertTrue(controller.contains("noMicTracker.update(call: service?.session.session?.startedAt,"), "the call is its start time")
        XCTAssertTrue(controller.contains("callMode: listening && ((service?.mic as? MicCapture)?.noMicStatus ?? false))"),
                      "only while listening, from the mic's route")
        XCTAssertTrue(controller.contains("state.noMicNotice = noMicTracker.visible"))
        let body = try XCTUnwrap(controller.components(separatedBy: "func dismissCallModeTip() {").dropFirst().first?
            .components(separatedBy: "\n    }").first)
        XCTAssertTrue(body.contains("noMicTracker.dismiss()") && body.contains("callModeTracker.dismiss()"), "Dismiss handles both")

        let settings = try read("App/CoachSettingsWindow.swift")
        XCTAssertTrue(settings.contains("import ListenMoreMac"))
        XCTAssertTrue(settings.contains("CoachSettingsWindow.text(CoachCardCopy.NoMicNotice.settingsNote, font: Theme.Settings.helperFont,"))
        XCTAssertTrue(settings.contains("NoMicNotice.showsSettingsNote(builtInMicPresent: CoreAudioRoutes().snapshot().builtInInput != nil)"))
        XCTAssertTrue(settings.contains("noMicNote.isHidden = !(window.isVisible && NoMicNotice.showsSettingsNote("), "hidden unless the Kit says to show it")
        XCTAssertTrue(settings.contains("let g1 = Self.group([toggleRow, help, noMicNote, gptNote,"))
        let view = try read("App/CoachCardView.swift")
        XCTAssertFalse(code(view).contains("noMicTracker"), "the view reads the state only")
    }

    /// The CI gate checks for every coach card shot the App writes.
    func testSnapshotGateCoversEveryState() throws {
        let shots = try read("App/UISnapshots.swift"), script = try read("scripts/snapshots.sh")
        let names = try NSRegularExpression(pattern: #"\("((?:card|pill)-[a-z-]+)", shotState\("#)
        let found = names.matches(in: shots, range: NSRange(shots.startIndex..., in: shots)).map { (shots as NSString).substring(with: $0.range(at: 1)) }
        XCTAssertEqual(found.count, 34, "card and pill states incl. mic off and Mute in Zoom (shown only while it can act), the call-mode tip and the no-mic notice, the fullest button row over each tip row, and the cue's linger and expiry (with Increase Contrast, and gone when paused or muted)")
        for name in ["card-cue-linger-amber", "card-cue-linger-rose", "card-cue-expired", "card-cue-linger-increased-contrast",
                     "pill-cue-linger-amber", "pill-cue-linger-rose", "pill-cue-expired", "pill-nudge-increased-contrast",
                     "pill-cue-linger-increased-contrast", "card-cue-paused", "pill-cue-muted"] {
            XCTAssertTrue(found.contains(name), "\(name) has a shot")
        }
        XCTAssertTrue(found.contains("card-call-mode-tip"), "the call-mode tip card has a shot")
        XCTAssertTrue(found.contains("card-no-mic-notice"), "the no-mic notice card has a shot")
        for n in found + ["morph-end", "collapse-end"] {
            XCTAssertNotNil(script.range(of: #"(\s|\\\n)\#(n)(\s|;)"#, options: .regularExpression), "snapshots.sh doesn't check \(n)")
        }
        let ci = try read("../.github/workflows/ci.yml")
        XCTAssertTrue(ci.contains("name: coach-card-snapshots"))
        XCTAssertTrue(ci.contains("compare-snapshots.py"), "the reminder cards are still compared pixel for pixel")
    }
}
