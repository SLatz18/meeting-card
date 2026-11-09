import Foundation

/// The runner shape is generic (executable + argv + env + timeout); the name is historical.
public typealias CommandRunner = GwsRunner

/// Optional SidePulse status light: while at least one card is up, the light pulses a program;
/// when the last card closes the SidePulse display mode returns to what it was.
/// Only two CLI commands are ever built (see `allowedPrefixes`); everything else is refused.
/// Threading: `cardCount` is main-only edge detection; every decision, file I/O and CLI call runs
/// on the injected serial queue (`enqueue`), so a fast 1->0->1 reads the prior AFTER the Off ran.
public final class StatusLight {
    public enum Display: String { case agent, battery, custom }
    public enum SkipReason: String, Error {
        case manual = "display is custom (manual)", perDevice = "per-device override", unreadable = "settings unreadable"
    }
    enum Command { case configure(Display); case write(device: String, program: String) }

    public static let maxProgramBytes = 512
    /// While on: touch `<root>/keepalive` and re-check LEDS.LED this often. The SD reader can power the
    /// device off after ~3 min without I/O (it then reboots into INIT.LED and our program is gone).
    public static let keepaliveInterval: TimeInterval = 60
    static let allowedPrefixes: [[String]] = [["battery", "configure", "--display"], ["write", "--device"]]

    // MARK: pure helpers

    public static func candidatePaths(env: [String: String], home: String) -> [String] {
        var c: [String] = []
        if let o = env["MEETING_CARD_SIDEPULSE"], o.hasPrefix("/") { c.append(o) }   // absolute only
        c += [home + "/.local/bin/sidepulse", "/opt/homebrew/bin/sidepulse", "/usr/local/bin/sidepulse"]
        return c
    }

    public static func settingsPath(env: [String: String], home: String) -> String {
        let base = env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 } ?? home + "/.config"
        return base + "/sidepulse/agent-monitor/settings.json"
    }

    public static func findDevice(volumes: [String], hasLED: (String) -> Bool) -> String? {
        volumes.sorted().first(where: hasLED)
    }

    /// LED-only color: the brand #2D8CFF reads cyan on the LEDs (strong green channel), so the light uses
    /// Zoom's deeper brand blue. The card outline keeps `Brand.zoom`.
    public static let ledZoom: UInt32 = 0x0B5CFF

    /// The LED colors for a provider, from `Brand` (base colors in light and dark: an LED has no background).
    /// Multi-color providers use 8 positional colors; one color = all LEDs. Anything else: neutral white.
    static func colors(provider: String?) -> String {
        let hs: [UInt32]
        switch provider {
        case "meet": hs = [Brand.meetGreen, Brand.meetGreen, Brand.meetYellow, Brand.meetYellow,
                           Brand.meetBlue, Brand.meetBlue, Brand.meetRed, Brand.meetRed]
        case "webex": hs = [Brand.webexCyan, Brand.webexCyan, Brand.webexGreen, Brand.webexGreen,
                            Brand.webexCyan, Brand.webexCyan, Brand.webexGreen, Brand.webexGreen]
        case "zoom": hs = [ledZoom]
        case "teams": hs = [Brand.teams]
        default: hs = [0xFFFFFF]   // "calendar" (multi-link / no-link), nil link, unknown provider
        }
        return hs.map { String(format: "#%06X", $0) }.joined(separator: " ")
    }

    /// Calm breathing in the provider's brand colors: a 3.2s rise and fall, 0.8s dark, a 4s cycle
    /// (slower than a 1.6s attention pulse, and no flashing).
    public static func program(provider: String?) -> String {
        let c = colors(provider: provider)
        return "off\n\(c) 3.2s pulse\noff 800ms none\nrepeat"
    }

    /// Current display from the settings file. nil data = file absent = agent. Present but not a JSON
    /// object (the CLI rewrites it non-atomically) => unreadable. Missing / unknown led_display => agent.
    static func display(settingsData: Data?) -> Display? {
        guard let d = settingsData else { return .agent }
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return nil }
        return (o["led_display"] as? String).flatMap(Display.init(rawValue:)) ?? .agent
    }

    /// Absent / missing key / unknown value => agent. Unreadable, custom or a per-device entry => skip.
    public static func prior(settingsData: Data?, device: String) -> Result<Display, SkipReason> {
        guard let d = settingsData else { return .success(.agent) }
        guard let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return .failure(.unreadable) }
        if let devs = o["devices"] as? [[String: Any]] {
            let norm = { (s: String) -> String in s.count > 1 && s.hasSuffix("/") ? String(s.dropLast()) : s }
            let dev = norm(device)
            if devs.contains(where: { e in [e["id"], e["path"]].contains { ($0 as? String).map(norm) == dev } }) {
                return .failure(.perDevice)
            }
        }
        let disp = (o["led_display"] as? String).flatMap(Display.init(rawValue:)) ?? .agent
        return disp == .custom ? .failure(.manual) : .success(disp)
    }

    /// The `StatusLightProgram` override: nil = none or rejected (the provider program is used).
    public static func validOverride(_ override: String?, log: (String) -> Void) -> String? {
        guard let o = override else { return nil }
        if o.isEmpty || o.utf8.count > maxProgramBytes {
            log("status light: custom program rejected (\(o.utf8.count) bytes); using provider colors")
            return nil
        }
        return o
    }

    /// The allowlist: returns argv only if it starts with an allowed prefix.
    static func checked(_ argv: [String]) -> [String]? {
        allowedPrefixes.contains { argv.count > $0.count && Array(argv.prefix($0.count)) == $0 } ? argv : nil
    }

    /// The ONLY argv builder.
    static func argv(_ cmd: Command) -> [String]? {
        switch cmd {
        case .configure(let d): return checked(["battery", "configure", "--display", d.rawValue])
        case .write(let dev, let prog): return checked(["write", "--device", dev, "--", prog])
        }
    }

    static func trimmed(_ s: String) -> String {
        var t = Substring(s)
        while let l = t.last, l.isWhitespace || l.isNewline { t = t.dropLast() }
        return String(t)
    }

    // MARK: instance

    let enabled: Bool
    let disabledReason: String
    let cli: () -> String?
    let device: () -> String?
    let readSettings: () -> Data?
    let readLED: (String) -> Data?
    let touch: (String) -> Void
    let markerURL: URL
    let override: String?
    let runner: CommandRunner
    let env: [String: String]
    let timeout: TimeInterval
    let enqueue: (@escaping () -> Void) -> Void
    let after: (TimeInterval, @escaping () -> Void) -> Void
    let log: (String) -> Void

    // main-thread state
    var prev = 0
    var sentProgram: String?
    // queue state
    var isOn = false
    var prior: Display = .agent
    var root: String?
    var generation = 0
    var programText = ""
    var loggedDisabled = false

    public init(enabled: Bool, disabledReason: String = "opted out",
                cli: @escaping () -> String?, device: @escaping () -> String?,
                readSettings: @escaping () -> Data?, readLED: @escaping (String) -> Data?,
                touch: @escaping (String) -> Void = { _ in },
                markerURL: URL, override: String? = nil, runner: CommandRunner, env: [String: String],
                timeout: TimeInterval = 5,
                enqueue: @escaping (@escaping () -> Void) -> Void,
                after: @escaping (TimeInterval, @escaping () -> Void) -> Void,
                log: @escaping (String) -> Void) {
        self.enabled = enabled; self.disabledReason = disabledReason
        self.cli = cli; self.device = device; self.readSettings = readSettings; self.readLED = readLED; self.touch = touch
        self.markerURL = markerURL; self.override = override; self.runner = runner; self.env = env
        self.timeout = timeout; self.enqueue = enqueue; self.after = after; self.log = log
    }

    func programFor(_ provider: String?) -> String { override ?? Self.program(provider: provider) }

    /// Main thread: edge detection only. `provider` is the lead (soonest) card's provider.
    public func cards(_ n: Int, provider: String?) {
        let p = prev
        prev = n
        if p == 0 && n > 0 {
            let prog = programFor(provider); sentProgram = prog
            enqueue { [self] in on(prog) }
        } else if p > 0 && n == 0 {
            sentProgram = nil
            enqueue { [self] in off(deadline: nil) }
        } else if n > 0, programFor(provider) != sentProgram {
            let prog = programFor(provider); sentProgram = prog
            enqueue { [self] in retarget(prog) }
        }
    }

    /// Launch: a leftover marker means we died mid-card; restore its prior.
    public func recoverFromMarker() {
        enqueue { [self] in _ = restorePending(timeout) }
    }

    /// Quit: retry any pending restore (on or not) and wait at most `timeout`.
    public func shutdown(timeout budget: TimeInterval = 3) {
        let sem = DispatchSemaphore(value: 0)
        let deadline = Date().addingTimeInterval(budget)
        enqueue { [self] in off(deadline: deadline); sem.signal() }
        if sem.wait(timeout: .now() + budget) == .timedOut { log("status light off: timed out") }
    }

    // MARK: queue-side

    /// The marker file is the single source of truth for "a restore is pending".
    /// true = nothing pending afterwards. Restores only while the settings still say custom (our switch).
    func restorePending(_ t: TimeInterval) -> Bool {
        guard let d = try? Data(contentsOf: markerURL) else { return true }
        guard let cur = Self.display(settingsData: readSettings()) else {
            log("status light: restore pending (settings unreadable); marker kept"); return false
        }
        if cur != .custom {
            try? FileManager.default.removeItem(at: markerURL)
            log("status light: stale marker retired"); return true
        }
        let p = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])
            .flatMap { $0["prior"] as? String }.flatMap(Display.init(rawValue:))
        let restore = (p == nil || p == .custom) ? Display.agent : p!
        guard let exe = cli() else { log("status light: restore pending but no sidepulse CLI"); return false }
        guard run(exe, .configure(restore), "configure", t) else {
            log("status light: restore failed; marker kept for next launch"); return false
        }
        try? FileManager.default.removeItem(at: markerURL)
        log("status light off (prior=\(restore.rawValue))")
        return true
    }

    func on(_ program: String) {
        guard !isOn else { return }
        guard restorePending(timeout) else { log("status light skipped: restore pending"); return }
        guard enabled else { return logDisabled(disabledReason) }
        guard let exe = cli() else { return logDisabled("no sidepulse CLI") }
        guard let dev = device() else { return logDisabled("no device") }
        let p: Display
        switch StatusLight.prior(settingsData: readSettings(), device: dev) {
        case .failure(let r): log("status light skipped: \(r.rawValue)"); return
        case .success(let d): p = d
        }
        // Crash marker FIRST.
        do {
            try FileManager.default.createDirectory(at: markerURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("{\"prior\":\"\(p.rawValue)\"}".utf8).write(to: markerURL, options: .atomic)
        } catch {
            log("status light skipped: marker write failed"); return
        }
        isOn = true; prior = p; root = dev; generation += 1; programText = program
        log("status light on (prior=\(p.rawValue))")
        // A failed configure leaves state on so Off still restores the prior.
        guard run(exe, .configure(.custom), "configure", timeout) else { return }
        guard run(exe, .write(device: dev, program: programText), "write", timeout) else { return }
        let gen = generation
        after(2) { [self] in enqueue { [self] in recheck(gen) } }
    }

    /// 2s after On, then every `keepaliveInterval` while this On lasts: keep the device awake and
    /// rewrite the program only if LEDS.LED no longer holds it (a racing service tick, or a device reboot).
    func recheck(_ gen: Int) {
        guard isOn, gen == generation, let dev = root, let exe = cli() else { return }
        touch(dev)
        let cur = readLED(dev).map { String(decoding: $0, as: UTF8.self) } ?? ""
        if Self.trimmed(cur) != Self.trimmed(programText) {
            run(exe, .write(device: dev, program: programText), "write", timeout)
        }
        after(Self.keepaliveInterval) { [self] in enqueue { [self] in recheck(gen) } }
    }

    /// Lead card's provider changed while on: ONE write, no configure.
    func retarget(_ program: String) {
        guard isOn, let dev = root, let exe = cli() else { return }
        programText = program
        run(exe, .write(device: dev, program: program), "write", timeout)
    }

    /// Off (and quit): the marker carries the prior, so a failed restore stays pending for
    /// shutdown, the next card and the next launch.
    func off(deadline: Date?) {
        if isOn { isOn = false; generation += 1 }
        let t = deadline.map { min(timeout, max(0.1, $0.timeIntervalSinceNow)) } ?? timeout
        _ = restorePending(t)
    }

    func logDisabled(_ reason: String) {
        guard !loggedDisabled else { return }
        loggedDisabled = true
        log("status light: disabled (\(reason))")
    }

    @discardableResult
    func run(_ exe: String, _ cmd: Command, _ name: String, _ t: TimeInterval) -> Bool {
        guard let a = Self.argv(cmd) else { log("status light: sidepulse \(name) refused (not allowlisted)"); return false }
        switch runner.run(executable: exe, args: a, env: env, timeout: t) {
        case .exited(let rc, _, _):
            if rc != 0 { log("status light: sidepulse \(name) rc=\(rc)") }
            return rc == 0
        case .timedOut: log("status light: sidepulse \(name) rc=timeout"); return false
        case .launchFailed: log("status light: sidepulse \(name) rc=launch"); return false
        }
    }
}
