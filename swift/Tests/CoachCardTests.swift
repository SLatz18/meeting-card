import XCTest
@testable import MeetingCardCore

/// The coach card and pill: tokens, placement, what each control shows, nudge timing and contrast,
/// Mute's disabled reasons, motion, and screen-share exclusion.
final class CoachCardTests: XCTestCase {
    typealias F = Theme.CoachCard.Frame

    // MARK: tokens

    /// The saving badge (#13c) is off unless the host sets it, and changes the state when set.
    func testSavingBadgeIsOffByDefault() {
        let mute = CoachMuteCopy.presentation(reason: nil, isMuted: false)
        let plain = CoachCardState(status: .listening, mute: mute)
        XCTAssertNil(plain.savingBadge)
        var saving = plain
        saving.savingBadge = "Saving transcript"
        XCTAssertNotEqual(plain, saving)
        XCTAssertEqual(CoachCardState(status: .listening, mute: mute, savingBadge: "Saving transcript"), saving)
    }

    /// The call-mode tip is off unless the host sets it, and changes the state when set.
    func testCallModeTipIsOffByDefault() {
        let plain = CoachCardState(status: .listening, mute: Self.live)
        XCTAssertFalse(plain.callModeTip)
        var tip = plain
        tip.callModeTip = true
        XCTAssertNotEqual(plain, tip)
        XCTAssertEqual(CoachCardState(status: .listening, mute: Self.live, callModeTip: true), tip)
        XCTAssertFalse(CoachCardState(status: .listening, mute: Self.live, savingBadge: "Saving transcript").callModeTip)
    }

    /// The no-mic notice is off unless the host sets it, and changes the state when set.
    func testNoMicNoticeIsOffByDefault() {
        let plain = CoachCardState(status: .listening, mute: Self.live)
        XCTAssertFalse(plain.noMicNotice)
        var notice = plain
        notice.noMicNotice = true
        XCTAssertNotEqual(plain, notice)
        XCTAssertEqual(CoachCardState(status: .listening, mute: Self.live, noMicNotice: true), notice)
        XCTAssertFalse(CoachCardState(status: .listening, mute: Self.live, savingBadge: "Saving transcript", callModeTip: true).noMicNotice)
        XCTAssertFalse(notice.callModeTip, "the two are separate flags")
    }

    /// The tip row (and the card's extra height) shows when either flag is set, and the card is as tall for both.
    func testTipRowShowsForEitherFlag() {
        let k = Theme.CoachCard.self
        let none = CoachCardState(status: .listening, mute: Self.live)
        let tip = CoachCardState(status: .listening, mute: Self.live, callModeTip: true)
        let notice = CoachCardState(status: .listening, mute: Self.live, noMicNotice: true)
        let both = CoachCardState(status: .listening, mute: Self.live, callModeTip: true, noMicNotice: true)
        XCTAssertFalse(none.tipRow)
        for s in [tip, notice, both] {
            XCTAssertTrue(s.tipRow)
            XCTAssertEqual(k.cardHeight(tipRow: s.tipRow), k.height + k.tipExtra, accuracy: 1e-9)
        }
        XCTAssertEqual(k.cardHeight(tipRow: none.tipRow), k.height)
    }

    /// The no-mic notice's approved words, exactly, and nothing naming a call app.
    func testNoMicNoticeApprovedCopy() {
        let c = CoachCardCopy.NoMicNotice.self
        XCTAssertFalse(c.isDraft, "approved")
        XCTAssertEqual(c.title, "Speaking cues are off")
        XCTAssertEqual(c.body, "With Bluetooth headphones, Call coach can't hear you on this Mac. It has no built-in mic, and the coach doesn't use headset mics. Captions and cues about the others still work.")
        XCTAssertEqual(c.dismiss, "Got it")
        XCTAssertEqual(c.accessibilityLabel, "Speaking cues are off. With Bluetooth headphones, Call coach can't hear you on this Mac. It has no built-in mic, and the coach doesn't use headset mics. Captions and cues about the others still work.",
                       "VoiceOver reads the title, then the body")
        XCTAssertEqual(c.settingsNote, "On a Mac with no built-in mic, Call coach can't hear you while you use Bluetooth headphones, so cues about how you speak are off. Captions and cues about the others still work.")
        for app in ["Zoom", "Meet", "Teams", "Slack", "Webex", "FaceTime"] {
            for s in [c.title, c.body, c.dismiss, c.accessibilityLabel, c.settingsNote] { XCTAssertFalse(s.contains(app), "the notice names \(app)") }
        }
    }

    /// The tip's approved words, exactly, and nothing naming a call app.
    func testCallModeTipApprovedCopy() {
        let c = CoachCardCopy.CallModeTip.self
        XCTAssertFalse(c.isDraft, "approved")
        XCTAssertEqual(c.title, "Headphones sound quiet?")
        XCTAssertEqual(c.body, "Your headphones may be in call mode, which lowers sound quality and volume. To keep full volume, choose your Mac's mic in your call app.")
        XCTAssertEqual(c.dismiss, "Got it")
        XCTAssertEqual(c.accessibilityLabel, "Tip: your headphones may be in call mode, which lowers volume. Choose your Mac's mic in your call app to keep full volume.")
        for app in ["Zoom", "Meet", "Teams", "Slack", "Webex", "FaceTime"] {
            for s in [c.title, c.body, c.accessibilityLabel] { XCTAssertFalse(s.contains(app), "the tip names \(app)") }
        }
    }

    /// The tip row adds `tipExtra` to the card's height and sits under the usual content, in the captions' font and role.
    func testCallModeTipRowAddsToTheCardHeight() {
        let k = Theme.CoachCard.self
        XCTAssertEqual(k.cardHeight(tipRow: false), k.height)
        XCTAssertEqual(k.cardHeight(tipRow: true), k.height + k.tipExtra, accuracy: 1e-9)
        XCTAssertGreaterThan(k.tipExtra, 0)
        XCTAssertEqual(k.tipFont, CardStyle.Typography.caption)
        XCTAssertEqual(k.tipTextColor, CardStyle.Text.secondary)
        XCTAssertEqual(k.tipFont, k.captionsFont)
        XCTAssertEqual(k.tipTextColor, k.captionsText)
        XCTAssertEqual(k.tipTextHeight, Double(k.tipLines) * Theme.Metrics.captionHeight, accuracy: 1e-9)
        let dismiss = k.tipDismissButton(labelWidth: 50), text = k.tipText
        XCTAssertEqual(dismiss.y, k.vertical, accuracy: 1e-9, "Dismiss rests on the card's bottom inset")
        XCTAssertEqual(text.y - dismiss.maxY, k.rowGap, accuracy: 1e-9)
        XCTAssertEqual(k.tipTitle.y, text.maxY, accuracy: 1e-9, "the title sits right above the text")
        XCTAssertEqual(k.tipTitle.maxY, k.tipExtra, accuracy: 1e-9, "the usual content starts right above the title")
        XCTAssertEqual(text.x, k.leading)
        XCTAssertEqual(text.maxX, k.width - k.trailing, accuracy: 1e-9)
        XCTAssertLessThanOrEqual(dismiss.maxX, k.width - k.trailing)
        XCTAssertEqual(k.stopButton(labelWidth: 70).y + k.tipExtra - k.tipTitle.maxY, k.vertical, accuracy: 1e-9, "the card's usual inset sits between")
    }

    func testMotionAndCoachTokens() {
        XCTAssertEqual(CardStyle.Motion.morphKeyframes, [0, 0.120, 0.280])
        XCTAssertEqual(CardStyle.Motion.morph, 0.280)
        XCTAssertEqual(CardStyle.Motion.reduceMotionCrossfade, 0.200)
        XCTAssertEqual(CardStyle.Motion.move, 0.240)
        XCTAssertFalse(CardStyle.Material.animates, "windows still appear without AppKit's animation")
        let c = CardStyle.Coach.self
        XCTAssertEqual(c.nudgeHold, 4.5)
        XCTAssertEqual(c.pill.width, 200); XCTAssertEqual(c.pill.height, 45); XCTAssertEqual(c.pill.radius, 15)
        XCTAssertEqual(c.nudgeTint(dark: false, increasedContrast: false), 0.12)
        XCTAssertEqual(c.nudgeTint(dark: true, increasedContrast: false), 0.16)
        XCTAssertEqual(c.nudgeTint(dark: false, increasedContrast: true), 0.20)
        XCTAssertEqual(c.nudgeTint(dark: true, increasedContrast: true), 0.26)
        XCTAssertEqual(c.nudgeBar, 5)
        XCTAssertEqual(c.grabber.width, 28); XCTAssertEqual(c.grabber.height, 3.5)
        XCTAssertEqual(c.nudgeEdgeAlpha(dark: false, increasedContrast: true), 1, "full-strength bar and full-alpha border")
        XCTAssertEqual(c.nudgeEdgeAlpha(dark: true, increasedContrast: true), 1)
        XCTAssertLessThan(c.nudgeEdgeAlpha(dark: false, increasedContrast: false), 1)
        XCTAssertLessThan(c.nudgeEdgeAlpha(dark: true, increasedContrast: false), 1)
        XCTAssertEqual(c.callBarClearance, 52)
        XCTAssertEqual(c.topGap, 12)
    }

    /// Card and pill sizes derive from CardStyle; the card's rows sit on the reminder card's insets.
    func testCardAndPillLayoutDeriveFromCardStyle() {
        let k = Theme.CoachCard.self, p = Theme.CoachPill.self
        XCTAssertEqual(k.width, CardLayout.W)
        XCTAssertEqual(k.radius, CardStyle.Radius.card)
        XCTAssertEqual(k.height, 2 * CardStyle.Spacing.controlBottom + 2 * CardStyle.Size.control
                       + 2 * CardStyle.Spacing.control + 3 * Theme.Metrics.captionHeight)
        XCTAssertEqual(k.micMuteButton.x, Theme.Metrics.leadingInset, "the coach's Mute starts where Ignore starts")
        XCTAssertEqual(k.buttonGap, CardStyle.Spacing.control)
        XCTAssertEqual(k.muteButton.x - k.micMuteButton.maxX, k.buttonGap, accuracy: 1e-9, "Mute in Zoom right after it")
        XCTAssertEqual(k.pauseButton(showsMute: true).x - k.muteButton.maxX, k.buttonGap, accuracy: 1e-9)
        XCTAssertEqual(k.pauseButton(showsMute: false).x, k.muteButton.x, accuracy: 1e-9, "no Mute in Zoom: Pause takes its place")
        for b in [k.micMuteButton, k.muteButton, k.pauseButton(showsMute: true)] {
            XCTAssertEqual(b.width, CardStyle.Size.control); XCTAssertEqual(b.height, CardStyle.Size.control)
            XCTAssertEqual(b.y, k.vertical, accuracy: 1e-9)
        }
        let stop = k.stopButton(labelWidth: 70)
        XCTAssertEqual(stop.maxX, k.width - Theme.Metrics.trailingInset, accuracy: 1e-9, "Stop Coach ends where Join ends")
        XCTAssertEqual(stop.width, 70 + 2 * k.textButtonPadding, accuracy: 1e-9)
        XCTAssertEqual(stop.y, k.vertical, accuracy: 1e-9)
        XCTAssertGreaterThanOrEqual(stop.x - k.pauseButton(showsMute: true).maxX, k.buttonGap,
                                    "the fullest row keeps a control gap before Stop Coach")
        XCTAssertEqual(k.minimizeButton.maxX, stop.maxX, accuracy: 1e-9)
        XCTAssertEqual(k.minimizeButton.x - k.statusRow.maxX, CardStyle.Spacing.control, accuracy: 1e-9)
        XCTAssertEqual(k.captions.y, k.micMuteButton.maxY + CardStyle.Spacing.control, accuracy: 1e-9)
        XCTAssertEqual(k.statusRow.y, k.captions.maxY + CardStyle.Spacing.control, accuracy: 1e-9)
        XCTAssertEqual(k.statusRow.maxY + CardStyle.Spacing.controlBottom, k.height, accuracy: 1e-9)
        XCTAssertEqual(p.button, Theme.Coach.pauseButtonSize)
        XCTAssertEqual(p.wordsInset, Theme.Coach.glyphGap)
        XCTAssertEqual(p.buttonRadius, Theme.Coach.pauseButtonRadius)
        let xs = p.buttonXs(pillWidth: p.width)
        XCTAssertEqual(xs.count, 3, "the coach's Mute, Pause/Resume, Stop")
        XCTAssertEqual(xs[2] + p.button + p.padding, p.width, accuracy: 1e-9)
        XCTAssertGreaterThan(xs[0], p.glyphX + p.glyphSize, "the glyph clears the buttons")
        let four = p.buttonXs(pillWidth: p.width, buttons: 4)
        XCTAssertEqual(four.count, 4, "Mute in Zoom beside the coach's Mute while it can act")
        XCTAssertEqual(four[3], xs[2], accuracy: 1e-9, "Stop stays at the trailing edge")
        XCTAssertGreaterThan(four[0], p.glyphX + p.glyphSize, "four buttons still clear the glyph")
        XCTAssertLessThan(p.rowMidY + p.button / 2, p.height - p.grabberTop - p.grabber.height, "buttons sit under the grabber")
    }

    // MARK: placement

    /// 1440x900 with a 24 pt menu bar; a notched built-in display whose safe area is taller than its menu bar.
    let external = CoachDisplay(id: 2, frame: F(x: 1512, y: 0, width: 1440, height: 900),
                                visibleFrame: F(x: 1512, y: 70, width: 1440, height: 806))
    let builtIn = CoachDisplay(id: 1, frame: F(x: 0, y: 0, width: 1512, height: 982),
                               visibleFrame: F(x: 0, y: 0, width: 1512, height: 945), safeAreaTop: 38, builtIn: true)

    func testTopOffsetIsTheScreenMetricPlusCallBarClearancePlusTwelve() {
        XCTAssertEqual(CoachPlacement.topOffset(on: external), 24 + 52 + 12, "menu bar height")
        XCTAssertEqual(CoachPlacement.topOffset(on: builtIn), 38 + 52 + 12, "the notch's safe area, taller than the 37 pt menu bar")
        XCTAssertEqual(CardStyle.Coach.screenMetric(safeAreaTop: 0, menuBarHeight: 0), 0, "auto-hidden menu bar, no notch")
        XCTAssertEqual(CardStyle.Coach.topOffset(screenMetric: 30), 94)
    }

    func testDisplayChoice() {
        let all = [external, builtIn]
        XCTAssertEqual(CoachPlacement.display(call: 1, card: 2, displays: all)?.id, 1, "call on the built-in display: under the camera")
        XCTAssertEqual(CoachPlacement.display(call: 2, card: 1, displays: all)?.id, 2, "call elsewhere: that display")
        XCTAssertEqual(CoachPlacement.display(call: nil, card: 2, displays: all)?.id, 2, "call display not known yet: the card's")
        XCTAssertEqual(CoachPlacement.display(call: 9, card: nil, displays: all)?.id, 1, "unknown ids: the built-in display")
        XCTAssertEqual(CoachPlacement.display(call: nil, card: nil, displays: [external])?.id, 2)
        XCTAssertNil(CoachPlacement.display(call: nil, card: nil, displays: []))
    }

    func testDefaultSpotIsTopCenterUnderTheCallBar() {
        let size = (w: Theme.CoachCard.width, h: Theme.CoachCard.height)
        let o = CoachPlacement.origin(size: size, on: builtIn)
        XCTAssertEqual(o.x + size.w / 2, 756, accuracy: 1e-9, "centered under the camera")
        XCTAssertEqual(o.y + size.h, 982 - 102, accuracy: 1e-9)
        let e = CoachPlacement.origin(size: size, on: external)
        XCTAssertEqual(e.x + size.w / 2, 1512 + 720, accuracy: 1e-9)
        XCTAssertEqual(e.y + size.h, 900 - 88, accuracy: 1e-9)
    }

    func testDragIsClampedAndRestored() {
        let size = (w: Theme.CoachCard.width, h: Theme.CoachCard.height)
        let dropped = CoachPlacement.clamp(origin: (-300, 2000), size: size, on: builtIn)
        XCTAssertEqual(dropped.x, 0); XCTAssertEqual(dropped.y, 945 - size.h, "kept inside the visible frame")
        let moved = CoachPlacement.clamp(origin: (100, 500), size: size, on: builtIn)
        let off = CoachPlacement.offset(origin: moved, size: size, on: builtIn)
        let back = CoachPlacement.origin(size: size, on: builtIn, offset: off)
        XCTAssertEqual(back.x, 100, accuracy: 1e-9); XCTAssertEqual(back.y, 500, accuracy: 1e-9, "restored where it was left")
        let far = CoachPlacement.origin(size: size, on: external, offset: CoachOffset(dx: 5000, dy: -5000))
        XCTAssertEqual(far.x, 1512 + 1440 - size.w, accuracy: 1e-9)
        XCTAssertEqual(far.y, 70, accuracy: 1e-9, "a restored offset off this display is clamped")
    }

    func testPillAndCardShareTheirTopCenter() {
        let card = (w: Theme.CoachCard.width, h: Theme.CoachCard.height), pill = (w: Theme.CoachPill.width, h: Theme.CoachPill.height)
        let o = CoachPlacement.origin(size: card, on: builtIn)
        let p = CoachPlacement.resize(origin: o, from: card, to: pill, on: builtIn)
        XCTAssertEqual(p.x + pill.w / 2, o.x + card.w / 2, accuracy: 1e-9)
        XCTAssertEqual(p.y + pill.h, o.y + card.h, accuracy: 1e-9)
        let corner = CoachPlacement.resize(origin: (0, 0), from: pill, to: card, on: builtIn)
        XCTAssertEqual(corner.x, 0); XCTAssertEqual(corner.y, 0, "expanding at the edge stays on screen")
    }

    // MARK: controls

    static let live = CoachMuteCopy.presentation(reason: nil, isMuted: false)
    static let muted = CoachMuteCopy.presentation(reason: nil, isMuted: true)

    func testPillStateMapping() {
        let s = Theme.CoachCard.Symbols.self
        func st(_ status: CoachCardState.Status, _ mute: MuteControlPresentation = Self.live, micMuted: Bool = false,
                _ nudge: CoachNudge? = nil) -> CoachCardState {
            CoachCardState(status: status, mute: mute, micMuted: micMuted, nudge: nudge, mode: .pill)
        }
        XCTAssertEqual(st(.idle).pauseControl.enabled, false, "nothing to pause before a session")
        XCTAssertEqual(st(.listening).pauseControl, CoachControl(symbol: s.pause, tooltip: "Pause coach", accessibilityLabel: "Pause call coach"))
        XCTAssertEqual(st(.muted).pauseControl.symbol, s.pause, "the user's pause wins over mute")
        XCTAssertEqual(st(.paused).pauseControl, CoachControl(symbol: s.resume, tooltip: "Resume coach", accessibilityLabel: "Resume call coach"))
        XCTAssertEqual(st(.listening).muteControl, CoachControl(symbol: s.mute, tooltip: "Mute in Zoom", accessibilityLabel: "Mute your mic in Zoom"))
        XCTAssertEqual(st(.muted, Self.muted, micMuted: true).muteControl,
                       CoachControl(symbol: s.unmute, tooltip: "Unmute in Zoom", accessibilityLabel: "Unmute your mic in Zoom"))
        XCTAssertTrue(st(.listening).showsMute, "a Zoom call it can act on: Mute in Zoom shows")
        XCTAssertEqual(st(.listening).pillButtons, 4)
        for why in MuteDisabledReason.allCases {
            let state = st(.listening, CoachMuteCopy.presentation(reason: why, isMuted: false))
            XCTAssertFalse(state.showsMute, "\(why): hidden, not greyed out")
            XCTAssertEqual(state.pillButtons, 3, "\(why): the coach's Mute, Pause, Stop")
        }
        for status in CoachCardState.Status.allCases {
            XCTAssertEqual(st(status).stopControl,
                           CoachControl(symbol: s.stop, tooltip: "Stop coach for this call", accessibilityLabel: "Stop call coach for the rest of this call"))
            XCTAssertEqual(st(status).sizeControl.tooltip, "Expand coach")
            XCTAssertEqual(st(status).sizeControl.accessibilityLabel, "Expand call coach card")
            XCTAssertEqual(st(status).live, status == .listening)
            XCTAssertEqual(st(status).held, status == .paused || status == .muted)
        }
        var card = st(.listening); card.mode = .card
        XCTAssertEqual(card.sizeControl.tooltip, "Minimize coach")
        XCTAssertEqual(card.sizeControl.accessibilityLabel, "Minimize call coach card")
        // A nudge tints and widens; the words are always there, so color is never the only cue.
        let amber = st(.listening, Self.live, CoachNudge(kind: .missedQuestion, tone: .amber))
        XCTAssertEqual(amber.tone, .amber)
        XCTAssertEqual(st(.listening, Self.live, CoachNudge(kind: .interrupt, tone: .rose)).tone, .rose)
        XCTAssertNil(st(.listening).tone)
        XCTAssertEqual(st(.listening).pillWidth(wordsWidth: 150), Theme.CoachPill.width, "no nudge: the pill's width")
        XCTAssertGreaterThan(amber.pillWidth(wordsWidth: 150), Theme.CoachPill.width)
        XCTAssertEqual(amber.pillWidth(wordsWidth: 2000), CardLayout.W, "never wider than the card")
        XCTAssertGreaterThanOrEqual(Theme.CoachPill.wordsRoom(pillWidth: amber.pillWidth(wordsWidth: 150)), 150 - 1e-9)
        for kind in CoachNudge.Kind.allCases {
            XCTAssertFalse(CoachNudge(kind: kind, tone: .amber).words.isEmpty)
            XCTAssertTrue(CoachNudge(kind: kind, tone: .amber).announcement.hasPrefix("Call coach: "))
        }
    }

    /// The pill's and the card's Mute is the coach's own (Mute My Mic for Coach), never Zoom's: Unmute while the
    /// coach's Mute is on (also through Pause and Zoom's mute), the coach menu's symbols, nothing to
    /// mute before a session.
    func testPillMuteIsTheCoachsOwn() {
        let m = Theme.Coach.menuSymbols
        func control(_ status: CoachCardState.Status, coachMuted: Bool = false) -> CoachControl {
            CoachCardState(status: status, mute: Self.live, coachMicMuted: coachMuted, mode: .pill).coachMuteControl
        }
        XCTAssertEqual(control(.listening), CoachControl(symbol: m.mute, tooltip: "Mute My Mic for Coach", accessibilityLabel: "Mute My Mic for Coach"))
        XCTAssertEqual(control(.micOff), CoachControl(symbol: m.unmute, tooltip: "Unmute My Mic for Coach", accessibilityLabel: "Unmute My Mic for Coach"))
        XCTAssertEqual(control(.paused, coachMuted: true).tooltip, "Unmute My Mic for Coach")
        XCTAssertEqual(control(.muted, coachMuted: true).tooltip, "Unmute My Mic for Coach")
        XCTAssertEqual(control(.paused).tooltip, "Mute My Mic for Coach")
        XCTAssertFalse(control(.idle).enabled, "nothing to mute before a session")
        for status in [CoachCardState.Status.listening, .paused, .muted, .micOff] { XCTAssertTrue(control(status).enabled) }
        XCTAssertNotEqual(control(.listening).tooltip, CoachCardState(status: .listening, mute: Self.live).muteControl.tooltip,
                          "the two mutes never share a label")
        for status in CoachCardState.Status.allCases {
            for coachMuted in [false, true] {
                XCTAssertEqual(CoachCardState(status: status, mute: Self.live, coachMicMuted: coachMuted, mode: .card).coachMuteControl,
                               control(status, coachMuted: coachMuted), "the card's Mute is the pill's: \(status) \(coachMuted)")
            }
        }
    }

    func testCopy() {
        XCTAssertEqual(CoachCardCopy.Button.stop, "Stop Coach", "the same casing as the menu's Stop Coach")
        XCTAssertEqual(CoachCardCopy.A11y.skipped, "Call coach is off for the rest of this call.")
        XCTAssertEqual(CoachCardCopy.Captions.empty, "Captions will show here once someone talks.")
        XCTAssertEqual([CoachMuteCopy.muteTooltip, CoachMuteCopy.unmuteTooltip, CoachCardCopy.Tooltip.pause, CoachCardCopy.Tooltip.resume,
                        CoachCardCopy.Tooltip.stop, CoachCardCopy.Tooltip.expand, CoachCardCopy.Tooltip.minimize],
                       ["Mute in Zoom", "Unmute in Zoom", "Pause coach", "Resume coach", "Stop coach for this call", "Expand coach",
                        "Minimize coach"])
        XCTAssertEqual([CoachMuteCopy.muteAccessibilityLabel, CoachMuteCopy.unmuteAccessibilityLabel, CoachCardCopy.A11y.pause,
                        CoachCardCopy.A11y.resume, CoachCardCopy.A11y.stop, CoachCardCopy.A11y.expand, CoachCardCopy.A11y.minimize],
                       ["Mute your mic in Zoom", "Unmute your mic in Zoom", "Pause call coach", "Resume call coach",
                        "Stop call coach for the rest of this call", "Expand call coach card", "Minimize call coach card"])
    }

    // MARK: nudges

    func testNudgeHoldsForFourAndAHalfSeconds() {
        var h = CoachNudgeHold()
        XCTAssertEqual(h.hold, CardStyle.Coach.nudgeHold)
        let a = CoachNudge(kind: .monologue, tone: .amber), r = CoachNudge(kind: .talkOver, tone: .rose)
        XCTAssertNil(h.active(now: 0))
        h.show(a, now: 10)
        XCTAssertEqual(h.active(now: 10), a)
        XCTAssertEqual(h.active(now: 14.49), a)
        XCTAssertNil(h.active(now: 14.5), "gone after nudgeHold")
        XCTAssertFalse(h.expire(now: 14.4))
        h.show(r, now: 13)
        XCTAssertEqual(h.active(now: 17.4), r, "a newer nudge replaces it and restarts the hold")
        XCTAssertNil(h.active(now: 17.5))
        XCTAssertTrue(h.expire(now: 17.5))
        XCTAssertNil(h.nudge)
        XCTAssertFalse(h.expire(now: 30), "nothing left to drop")
    }

    /// Nudge words keep 4.5:1 on the tint in light and dark, standard and Increase Contrast. The
    /// check itself fails below 4.5:1 (a heavier tint does).
    func testNudgeTextContrastAtLeast4p5() {
        for dark in [false, true] {
            for ic in [false, true] {
                for tone in [CoachNudge.Tone.rose, .amber] {
                    let ratio = CoachNudgeColors.textContrast(tone, dark: dark, increasedContrast: ic)
                    XCTAssertTrue(CoachNudgeColors.meetsContrast(ratio), "\(tone) dark=\(dark) ic=\(ic): \(ratio)")
                    XCTAssertGreaterThanOrEqual(ratio, 4.5)
                }
            }
        }
        XCTAssertFalse(CoachNudgeColors.meetsContrast(4.49))
        XCTAssertTrue(CoachNudgeColors.meetsContrast(4.5))
        let heavy = RGBA(Theme.Glow.rose(dark: true).r, Theme.Glow.rose(dark: true).g, Theme.Glow.rose(dark: true).b, 0.9)
            .over(CardStyle.for(dark: true).surface)
        let text = CardStyle.primaryTextSRGB(dark: true).over(heavy)
        XCTAssertFalse(CoachNudgeColors.meetsContrast(RGBA.contrast(text, heavy)), "a 90% tint would fail the check")
    }

    func testNudgeEdgeIsStrongerUnderIncreaseContrast() {
        for dark in [false, true] {
            for tone in [CoachNudge.Tone.rose, .amber] {
                XCTAssertEqual(CoachNudgeColors.edge(tone, dark: dark, increasedContrast: true).a, 1)
                XCTAssertLessThan(CoachNudgeColors.edge(tone, dark: dark, increasedContrast: false).a, 1)
                let std = CoachNudgeColors.tint(tone, dark: dark, increasedContrast: false)
                let ic = CoachNudgeColors.tint(tone, dark: dark, increasedContrast: true)
                let surface = CardStyle.for(dark: dark).surface
                XCTAssertGreaterThan(RGBA.contrast(ic, surface), RGBA.contrast(std, surface), "a stronger tint")
            }
        }
    }

    // MARK: motion

    func testMorphCollapseAndExpandFollowTheKeyframes() {
        for t in [CoachTransition.morph, .collapse, .expand] {
            let s = CoachMotion.steps(t, reduceMotion: false)
            XCTAssertEqual(s.map(\.duration).reduce(0, +), CardStyle.Motion.morph, accuracy: 1e-9)
            XCTAssertEqual(s.first?.duration ?? 0, CardStyle.Motion.morphKeyframes[1], accuracy: 1e-9)
            XCTAssertEqual(s.first?.outgoingAlpha, 0, "the old content is out by the second keyframe")
            XCTAssertEqual(s.first?.incomingAlpha, 0)
            XCTAssertEqual(s.last?.incomingAlpha, 1)
            XCTAssertEqual(s.last?.frameProgress, 1)
            XCTAssertTrue(s.allSatisfy(\.animatesFrame))
        }
        XCTAssertEqual(CoachMotion.duration(.glide, reduceMotion: false), CardStyle.Motion.move)
        XCTAssertEqual(CoachMotion.duration(.widen, reduceMotion: false), CardStyle.Motion.move)
        XCTAssertEqual(CoachMotion.duration(.appear, reduceMotion: false), 0, "windows appear without animation")
    }

    func testReduceMotionCrossfadesAndNeverAnimatesAFrame() {
        for t in [CoachTransition.morph, .glide, .collapse, .expand] {
            let s = CoachMotion.steps(t, reduceMotion: true)
            XCTAssertEqual(CoachMotion.duration(t, reduceMotion: true), CardStyle.Motion.reduceMotionCrossfade, accuracy: 1e-9)
            XCTAssertEqual(s.map(\.surfaceAlpha), [0, 1], "fades out, then back in at the new frame")
            XCTAssertEqual(s.map(\.frameProgress), [0, 1])
        }
        for t in CoachTransition.allCases {
            XCTAssertFalse(CoachMotion.steps(t, reduceMotion: true).contains(where: \.animatesFrame), "\(t)")
        }
    }

    // MARK: screen sharing

    func testEveryCoachStateIsLeftOutOfScreenShares() {
        XCTAssertEqual(Set(CoachSurface.allCases.map(\.sharing)), [.excluded])
        var seen: Set<String> = []
        for mode in [CoachCardState.Mode.card, .pill] {
            for nudge in [nil, CoachNudge(kind: .interrupt, tone: .rose)] {
                for status in CoachCardState.Status.allCases {
                    for moving in [false, true] {
                        let state = CoachCardState(status: status, mute: Self.live, nudge: nudge, mode: mode)
                        let s = CoachSurface.surface(for: state, transitioning: moving)
                        XCTAssertEqual(s.sharing, .excluded)
                        seen.insert("\(s)")
                    }
                }
            }
        }
        XCTAssertEqual(seen.count, CoachSurface.allCases.count, "card, pill, morph and both nudges are all reached")
    }
}
