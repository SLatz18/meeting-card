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
    public enum SkipReason: String, Error { case manual = "display is custom (manual)", perDevice = "per-device override" }
    enum Command { case configure(Display); case write(device: String, program: String) }

    public static let defaultProgram = "off\n#FF00FF 1.6s pulse\nrepeat"
    public static let maxProgramBytes = 512
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

    /// Missing / garbled / missing key / unknown value => agent. custom or a per-device entry => skip.
    public static func prior(settingsData: Data?, device: String) -> Result<Display, SkipReason> {
        guard let d = settingsData,
              let o = (try? JSONSerialization.jsonObject(with: d)) as? [String: Any] else { return .success(.agent) }
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

    public static func program(_ override: String?, log: (String) -> Void) -> String {
        guard let o = override else { return defaultProgram }
        if o.isEmpty || o.utf8.count > maxProgramBytes {
            log("status light: custom program rejected (\(o.utf8.count) bytes); using default")
            return defaultProgram
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
    let markerURL: URL
    let programText: String
    let runner: CommandRunner
    let env: [String: String]
    let timeout: TimeInterval
    let enqueue: (@escaping () -> Void) -> Void
    let after: (TimeInterval, @escaping () -> Void) -> Void
    let log: (String) -> Void

    // main-thread state
    var prev = 0
    // queue state
    var isOn = false
    var prior: Display = .agent
    var root: String?
    var generation = 0
    var loggedDisabled = false

    public init(enabled: Bool, disabledReason: String = "opted out",
                cli: @escaping () -> String?, device: @escaping () -> String?,
                readSettings: @escaping () -> Data?, readLED: @escaping (String) -> Data?,
                markerURL: URL, program: String, runner: CommandRunner, env: [String: String],
                timeout: TimeInterval = 5,
                enqueue: @escaping (@escaping () -> Void) -> Void,
                after: @escaping (TimeInterval, @escaping () -> Void) -> Void,
                log: @escaping (String) -> Void) {
        self.enabled = enabled; self.disabledReason = disabledReason
        self.cli = cli; self.device = device; self.readSettings = readSettings; self.readLED = readLED
        self.markerURL = markerURL; self.programText = program; self.runner = runner; self.env = env
        self.timeout = timeout; self.enqueue = enqueue; self.after = after; self.log = log
    }

    /// Main thread: edge detection only.
    public func cardCount(_ n: Int) {
        let p = prev
        prev = n
        if p == 0 && n > 0 { enqueue { [self] in on() } }
        else if p > 0 && n == 0 { enqueue { [self] in off(deadline: nil) } }
    }

    /// Launch: a leftover marker means we died mid-card; restore its prior.
    public func recoverFromMarker() {
        enqueue { [self] in
            guard let d = try? Data(contentsOf: markerURL) else { return }
            let p = ((try? JSONSerialization.jsonObject(with: d)) as? [String: Any])
                .flatMap { $0["prior"] as? String }.flatMap(Display.init(rawValue:))
            let restore = (p == nil || p == .custom) ? Display.agent : p!
            guard let exe = cli() else { log("status light: marker found but no sidepulse CLI"); return }
            guard run(exe, .configure(restore), "configure", timeout) else {
                log("status light: restore failed; marker kept for next launch"); return
            }
            try? FileManager.default.removeItem(at: markerURL)
            log("status light off (recovered, prior=\(restore.rawValue))")
        }
    }

    /// Quit: run Off (if on) and wait at most `timeout`.
    public func shutdown(timeout budget: TimeInterval = 3) {
        let sem = DispatchSemaphore(value: 0)
        let deadline = Date().addingTimeInterval(budget)
        enqueue { [self] in off(deadline: deadline); sem.signal() }
        if sem.wait(timeout: .now() + budget) == .timedOut { log("status light off: timed out") }
    }

    // MARK: queue-side

    func on() {
        guard !isOn else { return }
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
        isOn = true; prior = p; root = dev; generation += 1
        log("status light on (prior=\(p.rawValue))")
        // A failed configure leaves state on so Off still restores the prior.
        guard run(exe, .configure(.custom), "configure", timeout) else { return }
        guard run(exe, .write(device: dev, program: programText), "write", timeout) else { return }
        let gen = generation
        after(2) { [self] in enqueue { [self] in recheck(gen) } }
    }

    func recheck(_ gen: Int) {
        guard isOn, gen == generation, let dev = root, let exe = cli() else { return }
        let cur = readLED(dev).map { String(decoding: $0, as: UTF8.self) } ?? ""
        if Self.trimmed(cur) != Self.trimmed(programText) {
            run(exe, .write(device: dev, program: programText), "write", timeout)
        }
    }

    func off(deadline: Date?) {
        guard isOn else { return }
        isOn = false; generation += 1
        let t = deadline.map { min(timeout, max(0.1, $0.timeIntervalSinceNow)) } ?? timeout
        // Keep the marker unless the restore succeeded, so the next launch retries it.
        guard let exe = cli(), run(exe, .configure(prior), "configure", t) else {
            log("status light: restore failed; marker kept for next launch"); return
        }
        try? FileManager.default.removeItem(at: markerURL)
        log("status light off")
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
