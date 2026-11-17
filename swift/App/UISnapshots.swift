import AppKit
import ListenMoreCore
import ListenMoreMac
import MeetingCardCore

/// Fixture-run seams for the CI screenshots of the call coach UI (never active on a live run, and
/// they render UI only: no audio, no service, no network).
///   MEETING_CARD_COACH_CHIP=on|listening|paused  put that chip on the fixture card
///   MEETING_CARD_COACH_SHOTS=<dir>               write glow, Settings and onboarding PNGs, then quit
enum UISnapshots {
    static func demoChip(_ env: [String: String]) -> CoachChip? {
        switch env["MEETING_CARD_COACH_CHIP"] {
        case "on": CoachChip(mode: .on)
        case "listening": CoachChip(mode: .listening)
        case "paused": CoachChip(mode: .paused)
        default: nil
        }
    }

    @MainActor
    static func schedule(_ env: [String: String], card: Card, controller: Controller) {
        guard let dir = env["MEETING_CARD_COACH_SHOTS"] else { return }
        controller.schedule(1.0, repeats: false) { [weak card] in
            MainActor.assumeIsolated {
                guard let card else { return }
                let tag = card.isDark ? "dark" : "light"
                for (name, color) in [("rose", CueColor.red), ("amber", CueColor.amber)] {
                    let ok = glowShot(color, card: card, path: "\(dir)/glow-\(name)-\(tag).png")
                    controller.log("coach shot glow-\(name)-\(tag) ok=\(ok)")
                }
                settingsShots(dir: dir, tag: tag, controller: controller)
                NSApp.terminate(nil)
            }
        }
    }

    static func image(of view: NSView) -> CGImage? {
        view.layoutSubtreeIfNeeded()
        guard let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.cgImage
    }

    /// 1440x900 neutral desktop with the glow at peak opacity and the live card bottom-right.
    @MainActor
    static func glowShot(_ color: CueColor, card: Card, path: String) -> Bool {
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
                                  bytesPerRow: 0, space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
        let full = CGRect(x: 0, y: 0, width: size.width * scale, height: size.height * scale)
        ctx.setFillColor(card.isDark ? CGColor(srgbRed: 0.12, green: 0.12, blue: 0.13, alpha: 1)
                                     : CGColor(srgbRed: 0.85, green: 0.85, blue: 0.87, alpha: 1))
        ctx.fill(full)
        ctx.setAlpha(CGFloat(style.profile.peakOpacity))
        ctx.draw(glowImg, in: full)
        ctx.setAlpha(1)
        let cw = CGFloat(cardImg.width), ch = CGFloat(cardImg.height)
        let margin = CGFloat(Theme.Metrics.cardMargin) * scale
        ctx.draw(cardImg, in: CGRect(x: full.width - cw - margin, y: margin, width: cw, height: ch))
        guard let out = ctx.makeImage() else { return false }
        return Card.writePNG(out, path)
    }

    /// Settings (toggle off, the default) and the three onboarding screens, from scratch defaults.
    @MainActor
    static func settingsShots(dir: String, tag: String, controller: Controller) {
        let suite = "com.slatz.meetingcard.swift.snapshots"
        guard let defaults = UserDefaults(suiteName: suite) else { return }
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let keychain = KeychainStore(service: "com.slatz.meetingcard.swift.snapshots", account: "none")
        for i in 0..<CoachCopy.onboarding.count {
            guard let coach = try? CoachController(defaults: defaults, keychain: keychain) else { return }
            let w = CoachSettingsWindow(coach: coach, onboardingScreen: i)
            let ok = image(of: w.window.contentView!).map { Card.writePNG($0, "\(dir)/onboarding-\(i + 1)-\(tag).png") } ?? false
            controller.log("coach shot onboarding-\(i + 1)-\(tag) ok=\(ok)")
        }
        defaults.set(true, forKey: CoachController.Keys.onboarded)
        guard let coach = try? CoachController(defaults: defaults, keychain: keychain) else { return }
        let w = CoachSettingsWindow(coach: coach)
        w.update()
        let ok = image(of: w.window.contentView!).map { Card.writePNG($0, "\(dir)/settings-\(tag).png") } ?? false
        controller.log("coach shot settings-\(tag) ok=\(ok)")
    }
}
