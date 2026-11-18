import AppKit
import ListenMoreCore
import ListenMoreMac
import MeetingCardCore

/// Fixture-run seams for the CI screenshots of the call coach UI (never active on a live run, and
/// they render UI only: no audio, no service, no network).
///   MEETING_CARD_COACH_CHIP=on|listening|paused|muted|mic-off  put that chip on the fixture card
///   MEETING_CARD_COACH_CHIP_LABEL=<text>         a longer chip label (shows the icon-only collapse)
///   MEETING_CARD_COACH_SHOTS=<dir>               write glow, Settings, onboarding, menu and
///                                                 feedback-notice PNGs, plus the design packet, then quit
///   MEETING_CARD_COACH_CARD_SHOTS=<dir>          write the coach card and pill in each state
///                                                 (`coachCardShotNames`), then morph the fixture card
///                                                 into the coach card and collapse it, writing both
///                                                 end states, then quit
/// Design packet: `packet-<surface>-<light|dark>.png`, the plain reminder card beside each coach
/// surface (chip, the Muted chip, glow, Settings, Settings with Use Zoom/Meet controls on, onboarding,
/// status menu off / listening / muted / Mute / Unmute, feedback notice, the caption feed as it sits in a card, the
/// saving indicator, the transcript notice and transcript settings) for a side-by-side design review.
/// Caption text is synthetic and nothing is saved (an in-memory transcript store).
enum UISnapshots {
    /// Synthetic caption lines for the screenshots.
    static let demoCaptions: [CaptionEvent] = [
        .final(.others, text: "Shall we start with the timeline for the next release?"),
        .final(.me, text: "Yes, the first draft is ready for review."),
        .partial(.others, item: "demo", text: "Great, let's go through it section by"),
    ]

    /// Holds transcript text in memory for the screenshots; never touches disk.
    final class MemoryTranscriptStore: TranscriptStore {
        var files: [URL: String] = [:]
        func prepare(folder: URL) throws {}
        func exists(_ url: URL) -> Bool { files[url] != nil }
        func write(_ text: String, to url: URL) throws { files[url] = text }
        func remove(_ url: URL) throws { files[url] = nil }
    }

    /// The caption feed (CaptionFeedView at the card's width on the card surface: lines, lines while
    /// saving, before anyone talks, the cost-cap note, the indicator alone), then the one-time notice and
    /// the Settings group with captions and saving on during a call. The feed has no window and
    /// renders directly; the notice and Settings are shown briefly so AppKit draws them.
    @MainActor
    static func transcriptShots(dir: String, tag: String, controller: Controller, packet: @escaping (String, CGImage?) -> Void,
                                done: @escaping () -> Void) {
        let suite = AppIdentity.current.scoped("transcript-snapshots")
        guard let defaults = UserDefaults(suiteName: suite) else { return done() }
        defaults.removePersistentDomain(forName: suite)
        let live = LiveTranscript(settings: .init(captions: true, saving: true, folder: CoachTranscript.defaultFolder, keyUsable: true),
                                  store: MemoryTranscriptStore(), captions: CaptionBuffer(maxLines: Theme.Captions.visibleLines),
                                  labels: CoachTranscript.speakerLabels)
        live.callStarted()
        demoCaptions.forEach { live.receive($0) }
        let feed = CaptionFeedModel()
        CoachTranscript.update(feed, from: live)
        live.callEnded()
        let header = CoachCopy.captionsHeader
        let feeds: [(String, CaptionFeedModel)] = [
            ("caption-feed", CaptionFeedModel(header: header, lines: feed.lines, footnote: CoachCopy.captionsNote)),
            ("caption-feed-saving", CaptionFeedModel(header: header, lines: feed.lines, footnote: feed.footnote,
                                                     savingLabel: feed.savingLabel)),
            ("caption-feed-empty", CaptionFeedModel(header: header, placeholder: CoachCopy.captionsEmpty,
                                                    footnote: CoachCopy.captionsNote)),
            ("caption-feed-stopped", CaptionFeedModel(header: header, note: CoachCopy.captionsStopped,
                                                      footnote: CoachCopy.captionsNote)),
            ("saving-indicator", CaptionFeedModel(savingLabel: CoachCopy.savingNow)),
        ]
        // The card layout, at the coach card's captions-area size (what the coach card hosts).
        let cardFeeds: [(String, CaptionFeedModel)] = [
            ("caption-feed-card", CaptionFeedModel(lines: feed.lines)),
            ("caption-feed-card-empty", CaptionFeedModel(placeholder: CoachCopy.captionsEmpty)),
        ]
        let scale = NSScreen.main?.backingScaleFactor ?? 2
        for (name, model) in cardFeeds {
            let img = CaptionFeedSnapshot.cardImage(model, dark: tag == "dark", scale: scale)
            let ok = img.map { Card.writePNG($0, "\(dir)/\(name)-\(tag).png") } ?? false
            controller.log("coach shot \(name)-\(tag) ok=\(ok)")
            packet(name, img)
        }
        for (name, model) in feeds {
            let img = CaptionFeedSnapshot.image(model, dark: tag == "dark", scale: scale)
            let ok = img.map { Card.writePNG($0, "\(dir)/\(name)-\(tag).png") } ?? false
            controller.log("coach shot \(name)-\(tag) ok=\(ok)")
            packet(name, img)
        }
        func finish() {
            defaults.removePersistentDomain(forName: suite)
            done()
        }
        func settingsShot() {
            for key in [CoachController.Keys.onboarded, CoachController.Keys.enabled, CoachTranscript.Keys.captions,
                        CoachTranscript.Keys.saveTranscripts, CoachTranscript.Keys.noticeSeen] { defaults.set(true, forKey: key) }
            // Shot with the other opt-ins at their defaults: Use Zoom/Meet controls off, GPT as the cue judge.
            defaults.set(false, forKey: CoachController.Keys.callControls)
            defaults.set(JudgeProviderKind.gpt.rawValue, forKey: CoachController.Keys.judgeProvider)
            let keychain = KeychainStore(service: suite, account: "none")
            guard let coach = try? CoachController(defaults: defaults, keychain: keychain, showsStatusItem: false,
                                                   transcriptStore: MemoryTranscriptStore()) else { return finish() }
            coach.service?.setEnabled(false)
            coach.keyStored = true
            coach.transcript.sync(keyUsable: coach.transcriptKeyUsable)
            coach.transcript.callStarted()
            demoCaptions.forEach { coach.transcript.receive($0) }
            coach.transcript.record(CostReading(transcribeUsd: 0.0085, judgeUsd: 0.0012, budgetUsd: 1, billedAudioS: 30))
            let w = CoachSettingsWindow(coach: coach)
            w.update()
            w.window.appearance = NSApp.effectiveAppearance
            w.window.center()
            w.window.orderFrontRegardless()
            controller.schedule(0.5, repeats: false) {
                MainActor.assumeIsolated {
                    let img = w.transcriptGroupView.flatMap { viewImage($0, in: w.window) }
                    let ok = img.map { Card.writePNG($0, "\(dir)/transcript-settings-\(tag).png") } ?? false
                    controller.log("coach shot transcript-settings-\(tag) ok=\(ok)")
                    packet("transcript-settings", img)
                    w.window.orderOut(nil)
                    coach.transcript.callEnded()
                    finish()
                }
            }
        }
        func noticeShot() {
            let notice = CoachNotice { _ in }
            notice.window.appearance = NSApp.effectiveAppearance
            notice.window.center()
            notice.window.orderFrontRegardless()
            controller.schedule(0.5, repeats: false) {
                MainActor.assumeIsolated {
                    let img = notice.window.contentView.flatMap { layerImage($0, scale: notice.window.backingScaleFactor > 0 ? notice.window.backingScaleFactor : 2) }
                    let ok = img.map { Card.writePNG($0, "\(dir)/notice-\(tag).png") } ?? false
                    controller.log("coach shot notice-\(tag) ok=\(ok)")
                    packet("notice", img)
                    notice.window.orderOut(nil)
                    settingsShot()
                }
            }
        }
        noticeShot()
    }

    static func demoChip(_ env: [String: String]) -> CoachChip? {
        let label = env["MEETING_CARD_COACH_CHIP_LABEL"]
        switch env["MEETING_CARD_COACH_CHIP"] {
        case "on": return CoachChip(mode: .on, labelOverride: label)
        case "listening": return CoachChip(mode: .listening, labelOverride: label)
        case "paused": return CoachChip(mode: .paused, labelOverride: label)
        case "muted": return CoachChip(mode: .muted, labelOverride: label)
        case "mic-off": return CoachChip(mode: .micOff, labelOverride: label)
        default: return nil
        }
    }

    @MainActor
    static func schedule(_ env: [String: String], card: Card, controller: Controller) {
        if let dir = env["MEETING_CARD_COACH_CARD_SHOTS"] { return coachCardShots(dir: dir, card: card, controller: controller) }
        guard let dir = env["MEETING_CARD_COACH_SHOTS"] else { return }
        controller.schedule(1.0, repeats: false) { [weak card] in
            MainActor.assumeIsolated {
                guard let card else { return }
                let tag = card.isDark ? "dark" : "light"
                let chip = card.coach
                let withChip = card.snapshotImage()
                card.setCoach(nil)
                controller.schedule(0.5, repeats: false) { [weak card] in
                    MainActor.assumeIsolated {
                        guard let card else { return }
                        let plain = card.snapshotImage()
                        card.setCoach(chip)
                        controller.schedule(0.5, repeats: false) { [weak card] in
                            MainActor.assumeIsolated {
                                guard let card else { return }
                                shots(dir: dir, tag: tag, card: card, plain: plain, withChip: chip == nil ? nil : withChip,
                                      controller: controller)
                            }
                        }
                    }
                }
            }
        }
    }

    @MainActor
    static func shots(dir: String, tag: String, card: Card, plain: CGImage?, withChip: CGImage?, controller: Controller) {
        func packet(_ name: String, _ surface: CGImage?) {
            guard let plain, let surface, let img = pair(plain, surface, dark: card.isDark) else {
                return controller.log("coach packet \(name)-\(tag) ok=false")
            }
            let ok = Card.writePNG(img, "\(dir)/packet-\(name)-\(tag).png")
            controller.log("coach packet \(name)-\(tag) ok=\(ok)")
        }
        if withChip != nil { packet("chip", withChip) }
        // The Muted chip, each step after a redraw like the plain card.
        let chip = card.coach
        card.setCoach(CoachChip(mode: .muted))
        controller.schedule(0.5, repeats: false) { [weak card] in
            MainActor.assumeIsolated {
                guard let card else { return }
                packet("chip-muted", card.snapshotImage())
                card.setCoach(chip)
                controller.schedule(0.5, repeats: false) { [weak card] in
                    MainActor.assumeIsolated {
                        guard let card else { return }
                        for (name, color) in [("rose", CueColor.red), ("amber", CueColor.amber)] {
                            let img = glowImage(color, card: card)
                            let ok = img.map { Card.writePNG($0, "\(dir)/glow-\(name)-\(tag).png") } ?? false
                            controller.log("coach shot glow-\(name)-\(tag) ok=\(ok)")
                            packet("glow-\(name)", img)
                        }
                        settingsShots(dir: dir, tag: tag, controller: controller, packet: packet) {
                            transcriptShots(dir: dir, tag: tag, controller: controller, packet: packet) {
                                startToggleCheck(tag: tag, controller: controller)
                                symbolCheck(tag: tag, controller: controller)
                                menuShots(dir: dir, tag: tag, controller: controller, packet: packet)
                                noticeShot(dir: dir, tag: tag, controller: controller, packet: packet) { NSApp.terminate(nil) }
                            }
                        }
                    }
                }
            }
        }
    }

    /// The reminder card (left) beside a coach surface (right) on the desktop tone, both at their
    /// own scale; a surface taller than `maxHeight` pixels is scaled down to fit.
    static func pair(_ card: CGImage, _ surface: CGImage, dark: Bool, maxHeight: CGFloat = 1200) -> CGImage? {
        let pad = CGFloat(CardStyle.Spacing.stack * 2) * 2
        let k = min(1, maxHeight / CGFloat(surface.height))
        let sw = CGFloat(surface.width) * k, sh = CGFloat(surface.height) * k
        let cw = CGFloat(card.width), ch = CGFloat(card.height)
        let w = pad + cw + pad + sw + pad, h = pad + max(ch, sh) + pad
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(desktop(dark: dark))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.interpolationQuality = .high
        ctx.draw(card, in: CGRect(x: pad, y: h - pad - ch, width: cw, height: ch))
        ctx.draw(surface, in: CGRect(x: pad + cw + pad, y: h - pad - sh, width: sw, height: sh))
        return ctx.makeImage()
    }

    // MARK: coach card and pill

    static let liveMute = CoachMuteCopy.presentation(reason: nil, isMuted: false)
    static let mutedMute = CoachMuteCopy.presentation(reason: nil, isMuted: true)
    /// Use Zoom/Meet controls off (the default): no Mute in Zoom.
    static let noZoomMute = CoachMuteCopy.presentation(reason: .toggleOff, isMuted: false)
    static let amberNudge = CoachNudge(kind: .missedQuestion, tone: .amber)
    static let roseNudge = CoachNudge(kind: .interrupt, tone: .rose)

    static func shotState(_ st: CoachCardState.Status, _ m: MuteControlPresentation, _ n: CoachNudge?, _ mode: CoachCardState.Mode,
                          lingering: CoachNudge? = nil, ic: Bool = false, saving: Bool = false, callModeTip: Bool = false,
                          noMicNotice: Bool = false) -> CoachCardState {
        CoachCardState(status: st, mute: m, micMuted: m == mutedMute, coachMicMuted: st == .micOff, nudge: n, lingering: lingering, mode: mode,
                       increasedContrast: ic, savingBadge: saving ? CoachCopy.savingNow : nil, callModeTip: callModeTip,
                       noMicNotice: noMicNotice)
    }

    /// Each coach card and pill state as `coach-<name>-<appearance>.png`, with Use Zoom/Meet controls
    /// off unless the shot is about Mute in Zoom (shown only while it can act: Zoom muted, or a Zoom
    /// call). A shot with a tooltip draws it under the surface.
    static let coachCardStates: [(name: String, state: CoachCardState, tooltip: String?)] = [
        ("card-idle", shotState(.idle, noZoomMute, nil, .card), nil),
        ("card-listening", shotState(.listening, noZoomMute, nil, .card), nil),
        ("card-paused", shotState(.paused, noZoomMute, nil, .card), nil),
        ("card-muted", shotState(.muted, mutedMute, nil, .card), nil),
        ("card-mic-off", shotState(.micOff, noZoomMute, nil, .card), nil),
        ("card-zoom-mute", shotState(.listening, liveMute, nil, .card), nil),
        ("card-nudge-amber", shotState(.listening, noZoomMute, amberNudge, .card), nil),
        ("card-nudge-rose", shotState(.listening, noZoomMute, roseNudge, .card), nil),
        // After the words: the cue's glyph lingers in the status glyph (held role) until the linger
        // ends; then the card is back to listening (the expiry state).
        ("card-cue-linger-amber", shotState(.listening, noZoomMute, nil, .card, lingering: amberNudge), nil),
        ("card-cue-linger-rose", shotState(.listening, noZoomMute, nil, .card, lingering: roseNudge), nil),
        ("card-cue-expired", shotState(.listening, noZoomMute, nil, .card), nil),
        // Increase Contrast: the lingering glyph in the high-contrast held role.
        ("card-cue-linger-increased-contrast", shotState(.listening, noZoomMute, nil, .card, lingering: amberNudge, ic: true), nil),
        // Paused with a cue still lingering from before: the cue is gone (a plain paused card).
        ("card-cue-paused", shotState(.paused, noZoomMute, nil, .card, lingering: roseNudge), nil),
        ("card-increased-contrast", shotState(.listening, noZoomMute, amberNudge, .card, ic: true), nil),
        // Save transcripts on (#13c): the saving badge on the status line, and still there under a nudge.
        ("card-saving", shotState(.listening, noZoomMute, nil, .card, saving: true), nil),
        ("card-saving-nudge", shotState(.listening, noZoomMute, amberNudge, .card, saving: true), nil),
        // Headphones in call mode: the tip row under the buttons, with its Dismiss.
        ("card-call-mode-tip", shotState(.listening, noZoomMute, nil, .card, callModeTip: true), nil),
        // Bluetooth headphones on a Mac with no built-in mic: the same row, with the no-mic notice.
        ("card-no-mic-notice", shotState(.listening, noZoomMute, nil, .card, noMicNotice: true), nil),
        // The fullest button row (the coach's Mute, Mute in Zoom, Pause, Stop Coach) above each tip row.
        ("card-zoom-call-mode-tip", shotState(.listening, liveMute, nil, .card, callModeTip: true), CoachCardCopy.Tooltip.muteMic),
        ("card-zoom-no-mic-notice", shotState(.micOff, liveMute, nil, .card, noMicNotice: true), CoachCardCopy.Tooltip.unmuteMic),
        ("pill-idle", shotState(.idle, noZoomMute, nil, .pill), nil),
        ("pill-listening", shotState(.listening, noZoomMute, nil, .pill), CoachCardCopy.Tooltip.muteMic),
        ("pill-muted", shotState(.muted, mutedMute, nil, .pill), nil),
        ("pill-mic-off", shotState(.micOff, noZoomMute, nil, .pill), CoachCardCopy.Tooltip.unmuteMic),
        ("pill-zoom-mute", shotState(.listening, liveMute, nil, .pill), CoachMuteCopy.muteTooltip),
        ("pill-paused", shotState(.paused, noZoomMute, nil, .pill), nil),
        // The pill never widens for a cue: the cue's glyph in its tone with the tone's bar while the
        // nudge holds, then in the held role while it lingers; the words are its tooltip.
        ("pill-nudge-amber", shotState(.listening, noZoomMute, amberNudge, .pill), amberNudge.words),
        ("pill-nudge-rose", shotState(.listening, noZoomMute, roseNudge, .pill), roseNudge.words),
        ("pill-cue-linger-amber", shotState(.listening, noZoomMute, nil, .pill, lingering: amberNudge), amberNudge.words),
        ("pill-cue-linger-rose", shotState(.listening, noZoomMute, nil, .pill, lingering: roseNudge), roseNudge.words),
        ("pill-cue-expired", shotState(.listening, noZoomMute, nil, .pill), CoachCardCopy.Tooltip.expand),
        // Increase Contrast: the cue's bar at full strength, the glyph in the high-contrast tone.
        ("pill-nudge-increased-contrast", shotState(.listening, noZoomMute, roseNudge, .pill, ic: true), roseNudge.words),
        ("pill-cue-linger-increased-contrast", shotState(.listening, noZoomMute, nil, .pill, lingering: amberNudge, ic: true), amberNudge.words),
        // Muted in Zoom with a cue from before: no cue glyph, edge or tooltip (Expand coach).
        ("pill-cue-muted", shotState(.muted, mutedMute, nil, .pill, lingering: roseNudge), CoachCardCopy.Tooltip.expand),
    ]

    /// Every PNG `coachCardShots` writes, per appearance (the CI gate checks for them).
    static var coachCardShotNames: [String] { coachCardStates.map(\.name) + ["morph-end", "collapse-end"] }

    @MainActor
    static func coachCardShots(dir: String, card: Card, controller: Controller) {
        let suite = AppIdentity.current.scoped("snapshots")
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defaults.removePersistentDomain(forName: suite)
        let tag = card.isDark ? "dark" : "light"
        let p = CoachCardPresenter(defaults: defaults, positionKey: CoachController.Keys.cardPosition, captions: CoachCaptionsPlaceholder())
        p.reduceMotion = { false }
        func write(_ name: String, tooltip: String? = nil) {
            let scale = p.panel.backingScaleFactor > 0 ? p.panel.backingScaleFactor : 2
            let img = layerImage(p.root, scale: scale).flatMap { framed($0, tooltip: tooltip, dark: card.isDark, scale: scale) }
            let ok = img.map { Card.writePNG($0, "\(dir)/coach-\(name)-\(tag).png") } ?? false
            controller.log("coach card shot \(name)-\(tag) ok=\(ok)")
        }
        func next(_ i: Int) {
            guard i < coachCardStates.count else { return transitions() }
            let (name, state, tooltip) = coachCardStates[i]
            p.hide()
            p.panel.appearance = state.increasedContrast
                ? NSAppearance(named: card.isDark ? .accessibilityHighContrastDarkAqua : .accessibilityHighContrastAqua) : nil
            p.applyChrome()
            p.show(state, from: nil)
            controller.schedule(0.4, repeats: false) {
                MainActor.assumeIsolated {
                    write(name, tooltip: tooltip)
                    next(i + 1)
                }
            }
        }
        // The real morph out of the fixture card (then its glide), and the real collapse to the pill.
        func transitions() {
            p.hide()
            p.panel.appearance = nil
            p.applyChrome()
            let state = coachCardStates[1].state
            p.show(state, from: card)
            let morph = CoachMotion.duration(.morph, reduceMotion: false) + CoachMotion.duration(.glide, reduceMotion: false)
            controller.schedule(morph + 0.6, repeats: false) {
                MainActor.assumeIsolated {
                    write("morph-end")
                    var pill = state
                    pill.mode = .pill
                    p.update(pill)
                    controller.schedule(CoachMotion.duration(.collapse, reduceMotion: false) + 0.6, repeats: false) {
                        MainActor.assumeIsolated {
                            write("collapse-end")
                            NSApp.terminate(nil)
                        }
                    }
                }
            }
        }
        controller.schedule(1.0, repeats: false) { MainActor.assumeIsolated { next(0) } }
    }

    /// A shown view's layer tree as drawn (like the card's snapshot).
    @MainActor
    static func layerImage(_ view: NSView, scale backing: CGFloat) -> CGImage? {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let scale = backing > 0 ? backing : 2
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(view.bounds.width * scale), height: Int(view.bounds.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.scaleBy(x: scale, y: scale)
        view.layer?.render(in: ctx)
        return ctx.makeImage()
    }

    /// A coach surface on the desktop tone, with room around it; `tooltip` is drawn under it like
    /// AppKit's tooltip, for the states whose difference only shows on hover.
    static func framed(_ img: CGImage, tooltip: String?, dark: Bool, scale: CGFloat) -> CGImage? {
        let pad = CGFloat(CardStyle.Spacing.stack) * scale
        let font = Theme.font(CardStyle.Typography.caption)
        let text = tooltip.map { NSAttributedString(string: $0, attributes: [.font: font, .foregroundColor: dark ? NSColor.white : NSColor.black]) }
        let ts = text?.size() ?? .zero
        let tipW = text == nil ? 0 : (ts.width + CGFloat(CardStyle.Spacing.control) * 2) * scale
        let tipH = text == nil ? 0 : (ts.height + CGFloat(CardStyle.Spacing.control)) * scale
        let w = max(CGFloat(img.width), tipW) + 2 * pad, h = CGFloat(img.height) + 2 * pad + (text == nil ? 0 : tipH + pad / 2)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(w), height: Int(h), bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(desktop(dark: dark))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(img, in: CGRect(x: pad, y: h - pad - CGFloat(img.height), width: CGFloat(img.width), height: CGFloat(img.height)))
        if let text {
            let box = CGRect(x: pad, y: pad, width: tipW, height: tipH)
            ctx.setFillColor(dark ? CGColor(srgbRed: 0.25, green: 0.25, blue: 0.26, alpha: 1) : CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1))
            ctx.fill(box)
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
            ctx.scaleBy(x: scale, y: scale)
            text.draw(at: NSPoint(x: box.minX / scale + CGFloat(CardStyle.Spacing.control), y: box.minY / scale + CGFloat(CardStyle.Spacing.control) / 2))
            NSGraphicsContext.restoreGraphicsState()
        }
        return ctx.makeImage()
    }

    static func desktop(dark: Bool) -> CGColor {
        dark ? CGColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1) : CGColor(srgbRed: 0.85, green: 0.85, blue: 0.87, alpha: 1)
    }

    static func image(of view: NSView) -> CGImage? {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    /// 1440x900 neutral desktop with the glow at peak opacity and the live card bottom-right.
    @MainActor
    static func glowImage(_ color: CueColor, card: Card) -> CGImage? {
        let size = NSSize(width: 1440, height: 900)
        let scale: CGFloat = 2
        let style = CoachController.glowStyle()
        let glow = GlowView(frame: NSRect(origin: .zero, size: size), style: style)
        glow.appearance = NSApp.effectiveAppearance
        glow.setColor(color == .red ? .amber : .red)
        glow.setColor(color)
        guard let glowImg = image(of: glow), let cardImg = card.snapshotImage(),
              let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(size.width * scale), height: Int(size.height * scale), bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let full = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
        ctx.setFillColor(desktop(dark: card.isDark))
        ctx.fill(full)
        ctx.setAlpha(CGFloat(style.profile.peakOpacity))
        ctx.draw(glowImg, in: full)
        ctx.setAlpha(1)
        let cw = CGFloat(cardImg.width), ch = CGFloat(cardImg.height)
        let margin = CGFloat(Theme.Metrics.cardMargin) * scale
        ctx.draw(cardImg, in: CGRect(x: full.width - cw - margin, y: margin, width: cw, height: ch))
        return ctx.makeImage()
    }

    /// Start Coach while the coach is off must show in Settings at once: with Settings already open
    /// (and still after reopening it), and with Settings opened after Start. Writes one fixture log
    /// line that snapshots.sh gates on; the coach is switched off again and nothing is kept.
    /// The coach Mute's glyphs load as SF Symbols on this macOS (a missing name draws nothing). One
    /// fixture log line that snapshots.sh gates on.
    @MainActor
    static func symbolCheck(tag: String, controller: Controller) {
        let s = Theme.CoachCard.Symbols.self
        let found = [s.coachHearing, s.coachNotHearing].map { name in
            "\(name)=\(NSImage(systemSymbolName: name, accessibilityDescription: nil) == nil ? "missing" : "ok")"
        }
        controller.log("coach check symbols-\(tag) \(found.joined(separator: " "))")
    }

    @MainActor
    static func startToggleCheck(tag: String, controller: Controller) {
        let suite = AppIdentity.current.scoped("start-check")
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        let keychain = KeychainStore(service: suite, account: "none")
        func coach() -> CoachController? {
            defaults.removePersistentDomain(forName: suite)
            defaults.set(true, forKey: CoachController.Keys.onboarded)
            return try? CoachController(defaults: defaults, keychain: keychain, showsStatusItem: false,
                                        transcriptStore: MemoryTranscriptStore())
        }
        func state(_ c: CoachController) -> String { c.settingsWindow?.coachSwitchOn == true ? "on" : "off" }
        func done(_ c: CoachController) {
            c.settingsWindow?.window.orderOut(nil)
            c.setEnabled(false) { _ in }
        }
        var result = "unavailable"
        if let open = coach() {
            open.showSettings()
            let before = state(open)
            open.startClicked(nil)
            let after = state(open)
            open.settingsWindow?.window.orderOut(nil)
            open.showSettings()
            let reopened = state(open)
            done(open)
            if let fresh = coach() {
                fresh.startClicked(nil)
                fresh.showSettings()
                result = "before=\(before) open=\(after) reopened=\(reopened) fresh=\(state(fresh))"
                done(fresh)
            }
        }
        defaults.removePersistentDomain(forName: suite)
        controller.log("coach check start-toggle-\(tag) \(result)")
    }

    /// The coach status menu, off, waiting for a call (Start Coach), while listening (no key, so the
    /// GPT-off note shows), muted in the call app, and with a key the Mute and Unmute entries
    /// (listening, and the coach's own mic off), opened as a real NSMenu and captured from the screen while it tracks. The capture uses
    /// `screencapture` on the menu's window; without screen-recording access it falls back to the
    /// window's layer render.
    @MainActor
    static func menuShots(dir: String, tag: String, controller: Controller, packet: (String, CGImage?) -> Void) {
        let suite = AppIdentity.current.scoped("snapshots")
        guard let defaults = UserDefaults(suiteName: suite),
              let coach = try? CoachController(defaults: defaults, keychain: KeychainStore(service: suite, account: "none"),
                                               showsStatusItem: false) else { return }
        defaults.removePersistentDomain(forName: suite)
        let states: [(String, [CoachMenuItem])] = [
            ("menu-off", CoachMenu.items(enabled: false, indicator: .hidden, gptAvailable: false)),
            ("menu-waiting", CoachMenu.items(enabled: true, indicator: .hidden, gptAvailable: true)),
            ("menu-listening", CoachMenu.items(enabled: true, indicator: .listening, gptAvailable: false)),
            ("menu-muted", CoachMenu.items(enabled: true, indicator: .muted, gptAvailable: false)),
            ("menu-mute", CoachMenu.items(enabled: true, indicator: .listening, gptAvailable: true)),
            ("menu-unmute", CoachMenu.items(enabled: true, indicator: .micOff, gptAvailable: true, micMuted: true)),
        ]
        NSApp.activate()
        for (name, items) in states {
            let menu = coach.menu(for: items)
            menu.appearance = NSApp.effectiveAppearance
            var shot: CGImage?
            let t = Timer(timeInterval: 0.6, repeats: false) { _ in
                MainActor.assumeIsolated {
                    shot = menuWindowImage(log: controller.log)
                    menu.cancelTracking()
                }
            }
            RunLoop.main.add(t, forMode: .common)
            let screen = NSScreen.main?.frame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
            menu.popUp(positioning: nil, at: NSPoint(x: screen.midX, y: screen.midY + screen.height / 4), in: nil)
            let ok = shot.map { Card.writePNG($0, "\(dir)/\(name)-\(tag).png") } ?? false
            controller.log("coach shot \(name)-\(tag) ok=\(ok)")
            packet(name, shot)
        }
    }

    @MainActor
    static func menuWindowImage(log: (String) -> Void) -> CGImage? {
        let menus = NSApp.windows.filter { $0.isVisible && String(describing: type(of: $0)).contains("Menu") }
        log("coach menu windows: \(menus.map { String(describing: type(of: $0)) })")
        guard let w = menus.max(by: { $0.frame.height < $1.frame.height }) else { return nil }
        return screenImage(w, name: "menu", log: log)
    }

    /// The public-issue notice before the browser opens: the real NSAlert, shown without running it
    /// modally, captured from the screen like the menus.
    @MainActor
    static func noticeShot(dir: String, tag: String, controller: Controller, packet: @escaping (String, CGImage?) -> Void,
                           done: @escaping () -> Void) {
        let alert = FeedbackAction.noticeAlert()
        alert.window.appearance = NSApp.effectiveAppearance
        alert.window.hidesOnDeactivate = false
        alert.layout()
        alert.window.center()
        alert.window.orderFrontRegardless()
        controller.schedule(0.5, repeats: false) {
            MainActor.assumeIsolated {
                let img = screenImage(alert.window, name: "notice", log: controller.log)
                let ok = img.map { Card.writePNG($0, "\(dir)/feedback-notice-\(tag).png") } ?? false
                controller.log("coach shot feedback-notice-\(tag) ok=\(ok)")
                packet("feedback-notice", img)
                alert.window.orderOut(nil)
                done()
            }
        }
    }

    /// A visible window captured with `screencapture`; without screen-recording access, its layer render.
    @MainActor
    static func screenImage(_ w: NSWindow, name surface: String, log: (String) -> Void) -> CGImage? {
        let f = w.frame
        let top = (NSScreen.screens.first?.frame.height ?? f.maxY) - f.maxY
        log("coach \(surface) frame: \(Int(f.minX)),\(Int(top)) \(Int(f.width))x\(Int(f.height)) number=\(w.windowNumber)")
        let attempts: [(String, [String])] = [
            ("window", ["-x", "-o", "-l\(w.windowNumber)"]),
            ("rect", ["-x", "-R\(Int(f.minX)),\(Int(top)),\(Int(f.width)),\(Int(f.height))"]),
        ]
        for (name, args) in attempts {
            let path = NSTemporaryDirectory() + "coach-\(surface)-\(UUID().uuidString).png"
            defer { try? FileManager.default.removeItem(atPath: path) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = args + [path]
            try? p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0, let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                log("coach \(surface) capture \(name): failed status=\(p.terminationStatus)")
                continue
            }
            let drawn = hasContent(img)
            log("coach \(surface) capture \(name): \(img.width)x\(img.height) content=\(drawn)")
            if drawn { return img }
        }
        let img = windowImage(w)
        log("coach \(surface) capture render: content=\(img.map(hasContent) ?? false)")
        return img
    }

    /// True when the image isn't one flat color (a capture without access returns blank pixels).
    static func hasContent(_ img: CGImage) -> Bool {
        let n = 24
        var px = [UInt8](repeating: 0, count: n * n * 4)
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: &px, width: n, height: n, bitsPerComponent: 8, bytesPerRow: n * 4, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: n, height: n))
        let first = Array(px[0..<4])
        return stride(from: 0, to: px.count, by: 4).contains { i in
            (0..<4).contains { abs(Int(px[i + $0]) - Int(first[$0])) > 8 }
        }
    }

    /// A shown window's content over its window background; a clear window (the onboarding card)
    /// gets no backing, like on screen. Layer render, like the card snapshot (`cacheDisplay` skips
    /// most controls of a window that was never on screen).
    @MainActor
    static func windowImage(_ window: NSWindow) -> CGImage? {
        guard let view = window.contentView else { return nil }
        return viewImage(view, in: window)
    }

    /// Settings / onboarding as on screen: the groups, cropped to the window height scrolled to the
    /// top (or, with `atEnd`, to the bottom).
    @MainActor
    static func settingsImage(_ w: CoachSettingsWindow, atEnd: Bool = false) -> CGImage? {
        let (view, visible) = w.snapshotContent
        guard let full = viewImage(view, in: w.window) else { return nil }
        let scale = CGFloat(full.width) / max(view.bounds.width, 1)
        let h = min(CGFloat(full.height), visible * scale)
        return full.cropping(to: CGRect(x: 0, y: atEnd ? CGFloat(full.height) - h : 0, width: CGFloat(full.width), height: h))
    }

    @MainActor
    static func viewImage(_ view: NSView, in window: NSWindow) -> CGImage? {
        view.layoutSubtreeIfNeeded()
        view.displayIfNeeded()
        let scale = window.backingScaleFactor > 0 ? window.backingScaleFactor : 2
        guard let cs = CGColorSpace(name: CGColorSpace.sRGB),
              let ctx = CGContext(data: nil, width: Int(view.bounds.width * scale), height: Int(view.bounds.height * scale),
                                  bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        if window.isOpaque {
            var bg = CGColor(gray: 1, alpha: 1)
            window.effectiveAppearance.performAsCurrentDrawingAppearance { bg = window.backgroundColor.cgColor }
            ctx.setFillColor(bg)
            ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        }
        ctx.scaleBy(x: scale, y: scale)
        view.layer?.render(in: ctx)
        return ctx.makeImage()
    }

    /// Settings (toggles off, the default), Settings scrolled to its end (the feedback row), Settings
    /// local-only, Settings with "Use Zoom/Meet controls" on (its permission explainer: CI grants
    /// nothing), the TypeSafe cue judge without its key and after judging stopped on an auth
    /// failure, and the three onboarding screens, from scratch defaults.
    /// Each window is shown briefly so AppKit draws it, captured, then closed.
    @MainActor
    static func settingsShots(dir: String, tag: String, controller: Controller, packet: @escaping (String, CGImage?) -> Void,
                              done: @escaping () -> Void) {
        let suite = AppIdentity.current.scoped("snapshots")
        guard let defaults = UserDefaults(suiteName: suite) else { return done() }
        defaults.removePersistentDomain(forName: suite)
        let keychain = KeychainStore(service: suite, account: "none")
        typealias Shot = (name: String, atEnd: Bool, make: () -> CoachSettingsWindow?)
        let onboarding: [Shot] = (0..<CoachCopy.onboarding.count).map { i in
            ("onboarding-\(i + 1)", false, {
                guard let coach = try? CoachController(defaults: defaults, keychain: keychain, showsStatusItem: false) else { return nil }
                return CoachSettingsWindow(coach: coach, onboardingScreen: i)
            })
        }
        let shots: [Shot] = onboarding + [("settings", false, {
            defaults.set(true, forKey: CoachController.Keys.onboarded)
            guard let coach = try? CoachController(defaults: defaults, keychain: keychain, showsStatusItem: false) else { return nil }
            let w = CoachSettingsWindow(coach: coach)
            w.update()
            return w
        }), ("settings-scrolls", false, {
            guard let coach = try? CoachController(defaults: defaults, keychain: keychain, showsStatusItem: false) else { return nil }
            let w = CoachSettingsWindow(coach: coach, visibleHeightOverride: 480)
            w.update()
            return w
        }), ("settings-feedback", true, {
            guard let coach = try? CoachController(defaults: defaults, keychain: keychain, showsStatusItem: false) else { return nil }
            let w = CoachSettingsWindow(coach: coach, visibleHeightOverride: 480)
            w.update()
            return w
        }), ("settings-local-only", false, {
            defaults.set(true, forKey: CoachController.Keys.enabled)
            guard let coach = try? CoachController(defaults: defaults, keychain: keychain, showsStatusItem: false) else { return nil }
            coach.service?.setEnabled(false)
            let w = CoachSettingsWindow(coach: coach)
            w.update()
            return w
        }), ("settings-call-controls", false, {
            defaults.set(false, forKey: CoachController.Keys.enabled)
            defaults.set(true, forKey: CoachController.Keys.callControls)
            guard let coach = try? CoachController(defaults: defaults, keychain: keychain, showsStatusItem: false) else { return nil }
            let w = CoachSettingsWindow(coach: coach)
            w.update()
            return w
        }), ("settings-judge-typesafe", false, {
            defaults.set(false, forKey: CoachController.Keys.enabled)
            defaults.set(JudgeProviderKind.typesafe.rawValue, forKey: CoachController.Keys.judgeProvider)
            defaults.set(false, forKey: CoachController.Keys.callControls)
            guard let coach = try? CoachController(defaults: defaults, keychain: keychain, showsStatusItem: false) else { return nil }
            let w = CoachSettingsWindow(coach: coach)
            w.update()
            return w
        }), ("settings-judge-stopped", false, {
            defaults.set(JudgeProviderKind.typesafe.rawValue, forKey: CoachController.Keys.judgeProvider)
            guard let coach = try? CoachController(defaults: defaults, keychain: keychain, showsStatusItem: false) else { return nil }
            coach.typeSafeKeyStored = true
            coach.previewJudgeStop = .http(401)
            let w = CoachSettingsWindow(coach: coach)
            w.update()
            return w
        })]
        func next(_ i: Int) {
            guard i < shots.count else {
                defaults.removePersistentDomain(forName: suite)
                return done()
            }
            let (name, atEnd, make) = shots[i]
            // Each shot starts from the defaults (Use Zoom/Meet controls off, the GPT cue judge); a shot
            // about either sets it itself, so no shot depends on the one before it.
            defaults.set(false, forKey: CoachController.Keys.callControls)
            defaults.set(JudgeProviderKind.gpt.rawValue, forKey: CoachController.Keys.judgeProvider)
            guard let w = make() else { return next(i + 1) }
            w.window.appearance = NSApp.effectiveAppearance
            w.window.center()
            w.update()
            w.window.orderFrontRegardless()
            w.update()
            controller.schedule(0.5, repeats: false) {
                MainActor.assumeIsolated {
                    let img = settingsImage(w, atEnd: atEnd)
                    let ok = img.map { Card.writePNG($0, "\(dir)/\(name)-\(tag).png") } ?? false
                    controller.log("coach shot \(name)-\(tag) ok=\(ok)")
                    packet(name, img)
                    w.window.orderOut(nil)
                    next(i + 1)
                }
            }
        }
        next(0)
    }
}
