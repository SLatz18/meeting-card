import AppKit
import MeetingCardCore
import ServiceManagement

struct Args {
    var fixture: String?
    var noPoll = false
    var noRecheck = false
    var snapshot: String?
    var appearance: String?
    var nextFixture: String?

    /// Same flags as the Python app; unknown args (LaunchServices -psn_*) are ignored.
    static func parse(_ argv: [String]) -> Args {
        var a = Args()
        var it = argv.dropFirst().makeIterator()
        while let s = it.next() {
            switch s {
            // Once --fixture is seen, this is a fixture run even if its value is missing (codex P2 on
            // 208d53a: a bare trailing --fixture left fixture=nil, so the run counted as live and could
            // register the login item / poll). "" = fixture mode with an unloadable file.
            case "--fixture": a.fixture = it.next().map { URL(fileURLWithPath: $0).standardizedFileURL.path } ?? (a.fixture ?? "")
            case "--no-poll": a.noPoll = true
            case "--no-recheck": a.noRecheck = true
            case "--snapshot": a.snapshot = it.next()
            case "--appearance": a.appearance = it.next()
            case "--next-fixture": a.nextFixture = it.next().map { URL(fileURLWithPath: $0).standardizedFileURL.path }
            default: break
            }
        }
        // A fixture run never polls the real calendar (codex P2 on c87a2ef): otherwise real meetings would
        // render as "DEMO ·" cards bottom-left AND double-fire alongside the live app.
        if a.fixture != nil { a.noPoll = true }
        return a
    }
}

/// App shell around MeetingCardCore.Coordinator: timers, gws on a background queue
/// (results hopped to main), AppKit cards, test seams. Port of app.py's Controller.
final class Controller: NSObject, NSApplicationDelegate {
    static let pollInterval: TimeInterval = 60
    static let tickInterval: TimeInterval = 1
    static let openInterval: TimeInterval = 0.5

    let args: Args
    let paths: AppPaths
    let logger: Logger
    let gws: Gws
    let state: StateWriter
    let dryJoin = ProcessInfo.processInfo.environment["MEETING_CARD_DRY_JOIN"] == "1"
    let gwsQueue = DispatchQueue(label: "com.slatz.meetingcard.swift.gws", attributes: .concurrent)
    var coord: Coordinator<Card>!
    var light: StatusLight!
    let lightQueue = DispatchQueue(label: "com.slatz.meetingcard.swift.statuslight")
    var pollInFlight = false
    var timers: [Timer] = []
    var signalSources: [DispatchSourceSignal] = []

    init(args: Args) {
        self.args = args
        paths = AppPaths.forRun(fixture: args.fixture != nil)
        logger = Logger(paths: paths)
        let l = logger
        gws = Gws(log: { l.log($0) })
        state = StateWriter(paths: paths)
        super.init()
        light = Controller.makeStatusLight(fixture: args.fixture != nil, paths: paths, queue: lightQueue,
                                           log: { l.log($0) })
        let recheck = !(args.fixture != nil || args.noPoll || args.noRecheck)
        coord = Coordinator<Card>(
            recheck: recheck, log: { l.log($0) },
            makeCard: { [unowned self] ev, slot, now in self.makeCard(ev, slot, now) },
            spawnGet: { [unowned self] id, done in self.spawnGet(id, done) },
            writeState: { [unowned self] c in self.state.write(windowNumber: c.panel.windowNumber, ev: c.ev) },
            probe: { OpenProbeReader.read() })
        coord.onCards = { [unowned self] n, p in self.light.cards(n, provider: p) }
    }

    /// Optional SidePulse light. Fixture runs drive it only with MEETING_CARD_STATUS_LIGHT=1.
    static func makeStatusLight(fixture: Bool, paths: AppPaths, queue: DispatchQueue,
                                log: @escaping (String) -> Void) -> StatusLight {
        let env = ProcessInfo.processInfo.environment
        let home = Gws.homeDir()
        let optIn = UserDefaults.standard.object(forKey: "StatusLight") as? Bool ?? true
        let seam = !fixture || env["MEETING_CARD_STATUS_LIGHT"] == "1"
        let fm = FileManager.default
        return StatusLight(
            enabled: optIn && seam, disabledReason: optIn ? "fixture run" : "opted out",
            cli: { StatusLight.candidatePaths(env: env, home: home).first(where: Gws.isExecutableFile) },
            device: {
                let vols = ((try? fm.contentsOfDirectory(atPath: "/Volumes")) ?? []).map { "/Volumes/" + $0 }
                return StatusLight.findDevice(volumes: vols) { fm.fileExists(atPath: $0 + "/LEDS.LED") }
            },
            readSettings: { fm.contents(atPath: StatusLight.settingsPath(env: env, home: home)) },
            readLED: { fm.contents(atPath: $0 + "/LEDS.LED") },
            markerURL: paths.stateDir.appendingPathComponent("status-light.json"),
            override: StatusLight.validOverride(UserDefaults.standard.string(forKey: "StatusLightProgram"), log: log),
            runner: ProcessGwsRunner(), env: Gws.buildEnv(),
            enqueue: { queue.async(execute: $0) },
            after: { queue.asyncAfter(deadline: .now() + $0, execute: $1) },
            log: log)
    }

    func log(_ s: String) { logger.log(s) }

    // MARK: lifecycle

    func applicationDidFinishLaunching(_ n: Notification) {
        installSignalHandlers()
        light.recoverFromMarker()
        log("start pid=\(getpid()) fixture=\(args.fixture ?? "None") no_poll=\(args.noPoll) recheck=\(coord.recheck)")
        registerLoginItem()
        switch args.appearance {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: break
        }
        if args.fixture == nil {
            log("env keys: \(ProcessInfo.processInfo.environment.keys.sorted())")
        }
        if let f = args.fixture {
            do {
                // #11 render seam: feed the card + a "next" event through the real poll path first.
                if let nf = args.nextFixture {
                    let card = try Event.decode(try Data(contentsOf: URL(fileURLWithPath: f)))
                    coord.pollResult([card, try Event.decode(try Data(contentsOf: URL(fileURLWithPath: nf)))])
                }
                coord.showCard(try Event.decode(try Data(contentsOf: URL(fileURLWithPath: f))))
            } catch {
                log("ERROR fixture \(f): \(type(of: error))")
                NSApp.terminate(nil)
                return
            }
        }
        // #4: watch Join'd cards for their meeting surface (no-op unless one is opening).
        schedule(Controller.openInterval, repeats: true) { [unowned self] in self.coord.openTick() }
        if !args.noPoll {
            poll()
            schedule(Controller.pollInterval, repeats: true) { [unowned self] in self.poll() }
            schedule(Controller.tickInterval, repeats: true) { [unowned self] in self.coord.tick() }
        }
    }

    /// v2.5 #1: launch at login. One attempt per launch, never a loop; never unregisters (Scott turns
    /// it off in System Settings > General > Login Items). Gated by LoginItem.shouldRegister so a
    /// build/dd product, a scratch copy, or a fixture run never becomes the login item.
    private func registerLoginItem() {
        let svc = SMAppService.mainApp
        let name = { (s: SMAppService.Status) -> String in
            switch s {
            case .notRegistered: "notRegistered"
            case .enabled: "enabled"
            case .requiresApproval: "requiresApproval"
            case .notFound: "notFound"
            @unknown default: "unknown(\(s.rawValue))"
            }
        }
        let bundle = Bundle.main.bundleURL.resolvingSymlinksInPath().path
        let home = FileManager.default.homeDirectoryForCurrentUser.resolvingSymlinksInPath().path
        guard LoginItem.shouldRegister(bundlePath: bundle, fixture: args.fixture != nil, home: home) else {
            log(LoginItem.logLine(status: name(svc.status),
                                  outcome: .skipped(args.fixture != nil ? "fixture" : "not installed copy")))
            return
        }
        if svc.status == .enabled { log(LoginItem.logLine(status: "enabled", outcome: .already)); return }
        // requiresApproval = pending, or Scott switched it off in Login Items: respect it, never re-register.
        if svc.status == .requiresApproval {
            log(LoginItem.logLine(status: "requiresApproval", outcome: .skipped("needs approval in Login Items"))); return
        }
        do {
            try svc.register()
            log(LoginItem.logLine(status: name(svc.status), outcome: .registered))  // requiresApproval: logged, not retried
        } catch {
            log(LoginItem.logLine(status: name(svc.status), outcome: .error("\(error)")))
        }
    }

    func applicationWillTerminate(_ n: Notification) {
        light.shutdown(timeout: 3)
        log("exiting")
    }

    func installSignalHandlers() {
        for sig in [SIGTERM, SIGINT] {
            signal(sig, SIG_IGN)
            let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            src.setEventHandler { [unowned self] in
                self.log("\(sig == SIGTERM ? "SIGTERM" : "SIGINT"); exiting")
                NSApp.terminate(nil)
            }
            src.resume()
            signalSources.append(src)
        }
    }

    @discardableResult
    func schedule(_ interval: TimeInterval, repeats: Bool, _ body: @escaping () -> Void) -> Timer {
        let t = Timer(timeInterval: interval, repeats: repeats) { _ in body() }
        RunLoop.main.add(t, forMode: .common)
        timers.append(t)
        return t
    }

    // MARK: data

    /// One list poll on the gws queue (never two at once); result delivered on main.
    func poll() {
        guard !coord.stopped, !pollInFlight else { return }
        pollInFlight = true
        let g = gws
        gwsQueue.async { [weak self] in
            var items: [Event]?
            var fatal = false
            do { items = try g.fetch() } catch { fatal = true }
            DispatchQueue.main.async {
                guard let self else { return }
                self.pollInFlight = false
                if fatal { self.coord.fatal("polling") } else { self.coord.pollResult(items) }
            }
        }
    }

    /// Single-event get on the gws queue; outcome delivered on the main thread.
    func spawnGet(_ id: String?, _ done: @escaping (GetOutcome) -> Void) {
        let g = gws
        gwsQueue.async {
            let o: GetOutcome
            do { o = try g.getEvent(id).map { .event($0) } ?? .failed } catch { o = .fatal }
            DispatchQueue.main.async { done(o) }
        }
    }

    // MARK: cards

    func makeCard(_ ev: Event, _ slot: CardSlot, _ now: Date) -> Card {
        let l = logger
        let env = ProcessInfo.processInfo.environment
        let c = Card(ev: ev, rk: Rechecker(now: ProcessInfo.processInfo.systemUptime, log: { l.log($0) }), now: now,
                     target: self, ignoreAction: #selector(ignoreClicked(_:)), joinAction: #selector(joinClicked(_:)),
                     fixtureRun: args.fixture != nil, log: { l.log($0) })
        c.show(slot)
        // Test seam: flip the app appearance after show to exercise the live refresh path.
        if args.fixture != nil, env["MEETING_CARD_APPEARANCE_FLIP"] == "1" {
            schedule(0.4, repeats: false) {
                let dark = c.isDark
                NSApp.appearance = NSAppearance(named: dark ? .aqua : .darkAqua)
            }
        }
        // Test seam (#12 review P1): close the card, flip the appearance, survive, quit.
        if args.fixture != nil, env["MEETING_CARD_APPEARANCE_FLIP"] == "after-close" {
            schedule(0.3, repeats: false) { [weak self, weak c] in
                guard let self, let c else { return }
                self.coord.closeCard(c)
                self.log("flip-after-close: card closed")
            }
            schedule(0.6, repeats: false) {
                let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                NSApp.appearance = NSAppearance(named: dark ? .aqua : .darkAqua)
            }
            schedule(1.4, repeats: false) { [unowned self] in
                self.log("flip-after-close: survived")
                NSApp.terminate(nil)
            }
        }
        // Test seam (provider border): refresh the live card with a second fixture mid-run, the same
        // `refresh` path a Coordinator `.update` takes, so the outline must recolor / vanish / appear.
        if args.fixture != nil, let swap = env["MEETING_CARD_BORDER_SWAP"] {
            schedule(Double(env["MEETING_CARD_BORDER_SWAP_DELAY"] ?? "") ?? 3.0, repeats: false) { [unowned self, weak c] in
                guard let c else { return }
                do {
                    let ev2 = try Event.decode(try Data(contentsOf: URL(fileURLWithPath: swap)))
                    self.log("border swap: \(swap)")
                    c.refresh(ev2, now: Date())
                } catch { self.log("ERROR border swap \(swap): \(type(of: error))") }
            }
        }
        if let snap = args.snapshot {
            schedule(0.8, repeats: false) { [unowned self] in
                guard let last = self.coord.cards.last else { return }
                self.log(last.contrastReport())
                self.log("snapshot render(in:) -> \(snap) ok=\(last.snapshot(to: snap))")
            }
        }
        if let st = env["MEETING_CARD_SELFTEST"], st == "join" || st == "ignore" || st == "join-wait" {
            let delay = Double(env["MEETING_CARD_SELFTEST_DELAY"] ?? "") ?? 1.5
            schedule(delay, repeats: false) { [unowned self] in self.selftest(st) }
        }
        return c
    }

    func card(for sender: Any?) -> Card? {
        coord.cards.first { sender as AnyObject? === $0.ignoreButton || sender as AnyObject? === $0.joinButton }
    }

    @objc func joinClicked(_ sender: Any?) {
        guard let c = card(for: sender), let url = coord.join(c) else { return }
        if dryJoin {
            log("DRY_JOIN would open \(url)")
        } else if let u = URL(string: url) {
            NSWorkspace.shared.open(u)
        }
    }

    @objc func ignoreClicked(_ sender: Any?) {
        guard let c = card(for: sender) else { return }
        coord.ignore(c)
    }

    func selftest(_ which: String) {
        guard let c = coord.cards.last else {
            log("selftest \(which): no card")
            return
        }
        log("selftest performClick \(which)")
        (which == "ignore" ? c.ignoreButton : c.joinButton)?.performClick(nil)
        if which == "join-wait" {
            // #4 seam: stay up past the hold / open timeout so the log shows Joining... -> closed (or Join back).
            log("selftest join-wait: open cards=\(coord.cards.count) opening=\(coord.isOpening(c))")
            schedule((OpenWatch.detectionEnabled ? OpenWatch.timeout : OpenWatch.joinHold) + 2, repeats: false) { [unowned self] in
                self.log("selftest join-wait done; open cards=\(self.coord.cards.count) opening=\(self.coord.cards.first.map { self.coord.isOpening($0) } ?? false); quitting")
                NSApp.terminate(nil)
            }
            return
        }
        log("selftest done; open cards=\(coord.cards.count); quitting")
        NSApp.terminate(nil)
    }
}

/// #4 snapshot reader. Read-only and grant-free: NSWorkspace for the frontmost app and the default
/// https handler, libproc (`proc_listallpids` + `proc_pidpath`) for Zoom's CptHost helper, which
/// NSRunningApplication does not list. Never window titles, Accessibility or AppleScript.
enum OpenProbeReader {
    static let cptHostSuffix = "/zoom.us.app/Contents/Frameworks/CptHost.app/Contents/MacOS/CptHost"

    static func read() -> OpenProbe {
        let ws = NSWorkspace.shared
        let browser = URL(string: "https://example.com").flatMap { ws.urlForApplication(toOpen: $0) }
            .flatMap { Bundle(url: $0)?.bundleIdentifier }
        return OpenProbe(frontmost: ws.frontmostApplication?.bundleIdentifier,
                         zoomMeetingPIDs: pids(pathSuffix: cptHostSuffix), defaultBrowser: browser)
    }

    static func pids(pathSuffix: String) -> Set<Int32> {
        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return [] }
        var all = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&all, Int32(all.count * MemoryLayout<pid_t>.size))
        guard got > 0 else { return [] }
        var buf = [CChar](repeating: 0, count: 4 * Int(MAXPATHLEN))
        var out: Set<Int32> = []
        for p in all.prefix(Int(got)) where p > 0 {
            if proc_pidpath(p, &buf, UInt32(buf.count)) > 0, String(cString: buf).hasSuffix(pathSuffix) { out.insert(p) }
        }
        return out
    }
}
