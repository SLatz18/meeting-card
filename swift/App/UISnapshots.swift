import AppKit
import ListenMoreCore
import ListenMoreMac
import MeetingCardCore

/// Fixture-run seams for the CI screenshots of the call coach UI (never active on a live run, and
/// they render UI only: no audio, no service, no network).
///   MEETING_CARD_COACH_CHIP=on|listening|paused  put that chip on the fixture card
///   MEETING_CARD_COACH_CHIP_LABEL=<text>         a longer chip label (shows the icon-only collapse)
///   MEETING_CARD_COACH_SHOTS=<dir>               write glow, Settings, onboarding and menu PNGs,
///                                                 plus the design packet, then quit
/// Design packet: `packet-<surface>-<light|dark>.png`, the plain reminder card beside each coach
/// surface (chip, glow, Settings, onboarding, status menu) for a side-by-side design review.
enum UISnapshots {
    static func demoChip(_ env: [String: String]) -> CoachChip? {
        let label = env["MEETING_CARD_COACH_CHIP_LABEL"]
        switch env["MEETING_CARD_COACH_CHIP"] {
        case "on": return CoachChip(mode: .on, labelOverride: label)
        case "listening": return CoachChip(mode: .listening, labelOverride: label)
        case "paused": return CoachChip(mode: .paused, labelOverride: label)
        default: return nil
        }
    }

    @MainActor
    static func schedule(_ env: [String: String], card: Card, controller: Controller) {
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
        for (name, color) in [("rose", CueColor.red), ("amber", CueColor.amber)] {
            let img = glowImage(color, card: card)
            let ok = img.map { Card.writePNG($0, "\(dir)/glow-\(name)-\(tag).png") } ?? false
            controller.log("coach shot glow-\(name)-\(tag) ok=\(ok)")
            packet("glow-\(name)", img)
        }
        settingsShots(dir: dir, tag: tag, controller: controller, packet: packet) {
            menuShots(dir: dir, tag: tag, controller: controller, packet: packet)
            NSApp.terminate(nil)
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

    /// The coach status menu, off and while listening (no key, so the GPT-off note shows), opened
    /// as a real NSMenu and captured from the screen while it tracks. The capture uses
    /// `screencapture` on the menu's window; without screen-recording access it falls back to the
    /// window's layer render.
    @MainActor
    static func menuShots(dir: String, tag: String, controller: Controller, packet: (String, CGImage?) -> Void) {
        let suite = "com.slatz.meetingcard.swift.snapshots"
        guard let defaults = UserDefaults(suiteName: suite),
              let coach = try? CoachController(defaults: defaults, keychain: KeychainStore(service: suite, account: "none"),
                                               showsStatusItem: false) else { return }
        defaults.removePersistentDomain(forName: suite)
        let states: [(String, [CoachMenuItem])] = [
            ("menu-off", CoachMenu.items(enabled: false, indicator: .hidden, gptAvailable: false)),
            ("menu-listening", CoachMenu.items(enabled: true, indicator: .listening, gptAvailable: false)),
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
        let f = w.frame
        let top = (NSScreen.screens.first?.frame.height ?? f.maxY) - f.maxY
        log("coach menu frame: \(Int(f.minX)),\(Int(top)) \(Int(f.width))x\(Int(f.height)) number=\(w.windowNumber)")
        let attempts: [(String, [String])] = [
            ("window", ["-x", "-o", "-l\(w.windowNumber)"]),
            ("rect", ["-x", "-R\(Int(f.minX)),\(Int(top)),\(Int(f.width)),\(Int(f.height))"]),
        ]
        for (name, args) in attempts {
            let path = NSTemporaryDirectory() + "coach-menu-\(UUID().uuidString).png"
            defer { try? FileManager.default.removeItem(atPath: path) }
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            p.arguments = args + [path]
            try? p.run()
            p.waitUntilExit()
            guard p.terminationStatus == 0, let src = CGImageSourceCreateWithURL(URL(fileURLWithPath: path) as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
                log("coach menu capture \(name): failed status=\(p.terminationStatus)")
                continue
            }
            let drawn = hasContent(img)
            log("coach menu capture \(name): \(img.width)x\(img.height) content=\(drawn)")
            if drawn { return img }
        }
        let img = windowImage(w)
        log("coach menu capture render: content=\(img.map(hasContent) ?? false)")
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

    /// A shown window's content over its resolved background (layer render, like the card snapshot;
    /// `cacheDisplay` skips most controls of a window that was never on screen).
    @MainActor
    static func windowImage(_ window: NSWindow) -> CGImage? {
        guard let view = window.contentView else { return nil }
        return viewImage(view, in: window)
    }

    /// Settings / onboarding as on screen: the groups, cropped to the scrolled-to-top window height.
    @MainActor
    static func settingsImage(_ w: CoachSettingsWindow) -> CGImage? {
        let (view, visible) = w.snapshotContent
        guard let full = viewImage(view, in: w.window) else { return nil }
        let scale = CGFloat(full.width) / max(view.bounds.width, 1)
        return full.cropping(to: CGRect(x: 0, y: 0, width: CGFloat(full.width), height: min(CGFloat(full.height), visible * scale)))
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
        var bg = CGColor(gray: 1, alpha: 1)
        window.effectiveAppearance.performAsCurrentDrawingAppearance { bg = NSColor.windowBackgroundColor.cgColor }
        ctx.setFillColor(bg)
        ctx.fill(CGRect(x: 0, y: 0, width: ctx.width, height: ctx.height))
        ctx.scaleBy(x: scale, y: scale)
        view.layer?.render(in: ctx)
        return ctx.makeImage()
    }

    /// Settings (toggle off, the default) and the three onboarding screens, from scratch defaults.
    /// Each window is shown briefly so AppKit draws it, captured, then closed.
    @MainActor
    static func settingsShots(dir: String, tag: String, controller: Controller, packet: @escaping (String, CGImage?) -> Void,
                              done: @escaping () -> Void) {
        let suite = "com.slatz.meetingcard.swift.snapshots"
        guard let defaults = UserDefaults(suiteName: suite) else { return done() }
        defaults.removePersistentDomain(forName: suite)
        let keychain = KeychainStore(service: "com.slatz.meetingcard.swift.snapshots", account: "none")
        let onboarding: [(String, () -> CoachSettingsWindow?)] = (0..<CoachCopy.onboarding.count).map { i in
            ("onboarding-\(i + 1)", {
                guard let coach = try? CoachController(defaults: defaults, keychain: keychain, showsStatusItem: false) else { return nil }
                return CoachSettingsWindow(coach: coach, onboardingScreen: i)
            })
        }
        let shots: [(String, () -> CoachSettingsWindow?)] = onboarding + [("settings", {
            defaults.set(true, forKey: CoachController.Keys.onboarded)
            guard let coach = try? CoachController(defaults: defaults, keychain: keychain, showsStatusItem: false) else { return nil }
            let w = CoachSettingsWindow(coach: coach)
            w.update()
            return w
        }), ("settings-scrolls", {
            guard let coach = try? CoachController(defaults: defaults, keychain: keychain, showsStatusItem: false) else { return nil }
            let w = CoachSettingsWindow(coach: coach, visibleHeightOverride: 480)
            w.update()
            return w
        }), ("settings-local-only", {
            defaults.set(true, forKey: CoachController.Keys.enabled)
            guard let coach = try? CoachController(defaults: defaults, keychain: keychain, showsStatusItem: false) else { return nil }
            coach.service?.setEnabled(false)
            let w = CoachSettingsWindow(coach: coach)
            w.update()
            return w
        })]
        func next(_ i: Int) {
            guard i < shots.count else {
                defaults.removePersistentDomain(forName: suite)
                return done()
            }
            let (name, make) = shots[i]
            guard let w = make() else { return next(i + 1) }
            w.window.appearance = NSApp.effectiveAppearance
            w.window.center()
            w.update()
            w.window.orderFrontRegardless()
            controller.schedule(0.5, repeats: false) {
                MainActor.assumeIsolated {
                    let img = settingsImage(w)
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
