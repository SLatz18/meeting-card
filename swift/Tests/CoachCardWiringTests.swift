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

    /// Mute is CallControlsModel's one press of Zoom's own control; it never pauses or stops the
    /// coach's capture. The card shows CoachMuteCopy's presentation: disabled Mute says why in its tooltip.
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
        XCTAssertTrue(view.contains("b.setAccessibilityLabel(c.accessibilityLabel)"), "VoiceOver reads CoachMuteCopy's label (its own on Meet)")
        XCTAssertEqual(view.components(separatedBy: "set(mute, s.muteControl,").count - 1, 2, "card and pill share the one mapping")
        XCTAssertTrue(try read("App/UISnapshots.swift").contains("CoachMuteCopy.presentation(reason: r, isMuted: false)"))
        XCTAssertTrue(view.contains("b.isEnabled = c.enabled"))
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

    /// Nudges tint and widen the pill for `nudgeHold` and are announced to VoiceOver.
    func testNudgesAreAnnouncedAndExpire() throws {
        let controller = try read("App/CoachController.swift")
        XCTAssertTrue(controller.contains("s.onCue = { [weak self] cue in self?.showNudge(cue) }"))
        XCTAssertTrue(controller.contains("CoachCardPresenter.announce(n.announcement)"))
        XCTAssertTrue(controller.contains("Timer(timeInterval: nudges.hold, repeats: false)"))
        XCTAssertTrue(controller.contains("nudge: nudges.active(now: now)"))
        XCTAssertTrue(try read("App/CoachCardPanel.swift").contains("notification: .announcementRequested"))
    }

    /// not_listening nudges are off unless MeetingCard turns them on.
    func testNotListeningIsOffByDefault() throws {
        let controller = try read("App/CoachController.swift")
        XCTAssertTrue(controller.contains("static let configOverrides: [String: Any] = [\"cues\": [\"disabled\": [CueType.notListening.rawValue]]]"))
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

    /// The CI gate checks for every coach card shot the App writes.
    func testSnapshotGateCoversEveryState() throws {
        let shots = try read("App/UISnapshots.swift"), script = try read("scripts/snapshots.sh")
        let names = try NSRegularExpression(pattern: #"\("((?:card|pill)-[a-z-]+)", shotState\("#)
        let found = names.matches(in: shots, range: NSRange(shots.startIndex..., in: shots)).map { (shots as NSString).substring(with: $0.range(at: 1)) }
        XCTAssertEqual(found.count, 19, "#19's 15 states, #13c's card-saving and card-saving-nudge, and the mic-off card and pill")
        for n in found + ["morph-end", "collapse-end"] {
            XCTAssertNotNil(script.range(of: #"(\s|\\\n)\#(n)(\s|;)"#, options: .regularExpression), "snapshots.sh doesn't check \(n)")
        }
        let ci = try read("../.github/workflows/ci.yml")
        XCTAssertTrue(ci.contains("name: coach-card-snapshots"))
        XCTAssertTrue(ci.contains("compare-snapshots.py"), "the reminder cards are still compared pixel for pixel")
    }
}
