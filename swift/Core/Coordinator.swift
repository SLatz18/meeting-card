import Foundation

/// What a card shows, computed from the event (pure; the AppKit view just renders it).
public struct CardModel: Equatable {
    public let title: String
    public let links: [VideoLink]
    public let multi: Bool
    /// What the dark button opens: a video provider, or "calendar" (multi-link invites).
    public let link: VideoLink?
    public let ends: String
    public let flag: String?

    public init(_ ev: Event, timeZone: TimeZone = .current) {
        title = (ev.summary ?? "").isEmpty ? "(No title)" : ev.summary!
        links = Links.videoLinks(ev)
        let calendar = ev.htmlLink.flatMap { $0.isEmpty ? nil : VideoLink("calendar", $0) }
        // One rule (#13): the card view uses the same kind as the list filter and re-checks.
        switch Timing.cardKind(ev) {
        case .multi(let ls):
            // Don't guess between video links; send Scott to the event (Scott, 2026-10-06).
            multi = true; link = calendar; flag = "\(ls.count) video links in this invite"
        case .join(let l):
            multi = false; link = l; flag = nil
        case .noLink:
            multi = false; link = calendar; flag = "No video link"
        case nil:
            // Only reachable for a forced fixture (--fixture skips the filter): old behavior.
            multi = false; link = nil; flag = nil
        }
        ends = Timing.times(ev).map { Timing.formatEnds($0.end, timeZone: timeZone) } ?? ""
    }

    public var buttonTitle: String? {
        guard let link else { return nil }
        return link.provider == "calendar" ? "Open in Calendar" : Links.labels[link.provider]
    }

    /// #4 review P2: the dark button's label given Core's opening state (nil = no button).
    /// Every App rebuild (live update, appearance flip) goes through this, so "Join" can't
    /// come back while Core still says opening.
    public func openingTitle(_ opening: Bool) -> String? {
        guard buttonTitle != nil else { return nil }
        return opening ? "Joining\u{2026}" : buttonTitle
    }
}

/// The on-screen card as the coordinator sees it (AppKit panel in the app, fake in tests).
public protocol CardHandle: AnyObject {
    var ev: Event { get }
    var rk: Rechecker { get }
    func close()
    func place(_ slot: CardSlot)
    /// #11: the muted "Next up" line (nil = none; the card is taller while it is shown).
    func setNextUp(_ line: NextUp.Parts?)
    func refresh(_ ev: Event, now: Date)
    func setNow(_ now: Date)
    /// #4: Join shows "Joining..." while true (a click on it is a no-op); false = Join is back.
    func setOpening(_ on: Bool)
}

/// #8/#11: a stack slot. index 0 = bottom; offset = card-edge points above the first slot.
public struct CardSlot: Equatable, Sendable {
    public let index: Int
    public let offset: Double
    public init(_ index: Int, offset: Double) { self.index = index; self.offset = offset }
}

public enum GetOutcome {
    case event(Event)
    case failed
    case fatal

    var fresh: Event? { if case .event(let e) = self { return e }; return nil }
}

/// Port of app.py's Controller logic (everything but AppKit): poll results, the 1 s tick,
/// pre-fire and live re-check handling, close/join/ignore. Main-thread only.
public final class Coordinator<Card: CardHandle> {
    public let sched: Scheduler
    public private(set) var cards: [Card] = []
    public private(set) var stopped = false
    public let recheck: Bool
    let log: (String) -> Void
    let makeCard: (Event, CardSlot, Date) -> Card
    let spawnGet: (String?, @escaping (GetOutcome) -> Void) -> Void
    let writeState: (Card) -> Void
    /// Status light seam: card count + lead (soonest) card provider after every show/close/link update (default: no-op).
    public var onCards: (Int, String?) -> Void
    let clock: () -> Date
    let mono: () -> TimeInterval
    let probe: () -> OpenProbe
    /// #4: meeting-surface detection (default OpenWatch.detectionEnabled = off: fixed hold).
    let detection: Bool
    /// #4: cards waiting for their meeting surface after Join.
    var watches: [ObjectIdentifier: OpenWatch] = [:]
    /// #8: the stack slot each card was last placed in (a re-place disarms keys, so only move
    /// cards whose slot changes).
    var slots: [ObjectIdentifier: CardSlot] = [:]

    public init(recheck: Bool,
                log: @escaping (String) -> Void,
                makeCard: @escaping (Event, CardSlot, Date) -> Card,
                spawnGet: @escaping (String?, @escaping (GetOutcome) -> Void) -> Void,
                writeState: @escaping (Card) -> Void = { _ in },
                clock: @escaping () -> Date = { Date() },
                mono: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                probe: @escaping () -> OpenProbe = { OpenProbe() },
                detection: Bool = OpenWatch.detectionEnabled,
                onCards: @escaping (Int, String?) -> Void = { _, _ in }) {
        self.onCards = onCards
        self.detection = detection
        self.recheck = recheck
        self.log = log
        self.sched = Scheduler(log: log)
        self.makeCard = makeCard
        self.spawnGet = spawnGet
        self.writeState = writeState
        self.clock = clock
        self.mono = mono
        self.probe = probe
    }

    // MARK: data

    /// #11: a successful poll refreshes every card's Next up line (same data, no extra calls).
    public func pollResult(_ items: [Event]?) {
        guard sched.update(items) else { return }
        refreshNextUps()
    }

    /// #11 review P2-1: the cache changed (poll, or a pre-fire / live re-check replaced a cached
    /// event): recompute Next up for EVERY showing card (change-only delivery), then restack.
    func refreshNextUps() {
        for c in cards { updateNextUp(c) }
        restack()
    }

    /// gws said it deleted credentials: no further gws calls of any kind.
    public func fatal(_ context: String) {
        stopped = true
        log("ERROR \(context) stopped after gws credential-deletion message")
    }

    public func tick() {
        let now = clock()
        let due = sched.due(now)
        let stale = sched.stale(now)
        for ev in due {
            let tok = sched.token(ev)
            if recheck && !stopped {
                spawnGet(ev.id) { [weak self] o in self?.prefireDone(ev, o, token: tok) }
            } else {
                prefireDone(ev, .failed, token: tok)
            }
        }
        for ev in stale {
            // Safety net: a hung/dead get must never swallow a card.
            log("prefire \(ev.id ?? "nil"): no result in \(Int(Scheduler.pendingMax))s; treating as failed check")
            prefireDone(ev, .failed, token: sched.token(ev))
        }
        for c in cards {
            if let (_, end) = Timing.times(c.ev), now >= end {
                log("auto-close \(c.ev.id ?? "nil") (ended)")
                closeCard(c)
                continue
            }
            c.setNow(now)
            if recheck && !stopped, let gen = c.rk.shouldStart(mono()) {
                spawnGet(c.ev.id) { [weak self, weak c] o in
                    guard let self else { return }
                    self.noteFatal(o)  // before the card check: a closed card must not drop the stop
                    guard let c else { return }
                    self.liveDone(c, gen, o)
                }
            }
        }
    }

    func noteFatal(_ o: GetOutcome) {
        if case .fatal = o, !stopped { fatal("polling + rechecks") }
    }

    public func prefireDone(_ cached: Event, _ o: GetOutcome, token: Int?) {
        noteFatal(o)
        let now = clock()
        let fresh = o.fresh
        let (act, ev) = Timing.recheckAction(cached: cached, fresh: fresh, now: now, phase: .prefire)
        guard let token, sched.resolve(cached, act, ev, token: token) else {
            log("prefire \(cached.id ?? "nil"): late result dropped")
            return
        }
        log("prefire \(cached.id ?? "nil"): \(act.rawValue)\(fresh == nil ? " (check failed)" : "")")
        refreshNextUps()   // #11 review P2-1: resolve may have replaced the cached copy
        if act == .show { showCard(ev) }
    }

    public func liveDone(_ c: Card, _ gen: Int, _ o: GetOutcome) {
        noteFatal(o)
        guard c.rk.accept(mono(), gen) else { return }  // closed, or superseded generation
        let now = clock()
        let fresh = o.fresh
        let (act, ev) = Timing.recheckAction(cached: c.ev, fresh: fresh, now: now, phase: .live)
        if fresh == nil { log("recheck \(c.ev.id ?? "nil"): failed; keeping card") }
        if act == .keep { return }
        log("recheck \(c.ev.id ?? "nil"): \(act.rawValue)")
        switch act {
        case .close:
            if Timing.skipReason(ev) != nil { sched.skippedClosed(ev) }
            closeCard(c)   // closeCard refreshes every remaining card's Next up (P2-1)
        case .closeReschedule:
            sched.reschedule(ev)
            closeCard(c)
        case .update:
            sched.rekey(ev)
            let target = CardModel(c.ev).link
            c.refresh(ev, now: now)
            reportCards()   // a link edit can change the lead provider
            // #11: a moved start / end changes this card's window; #11 review P2-1: the replaced
            // cache entry can change OTHER cards' lines too. #8: a moved start can change slots.
            refreshNextUps()
            if isOpening(c) {
                // #4 review P2: the watch belongs to the link that was clicked. A new actionable
                // target (provider/URL, or card kind: Join vs Open in Calendar) drops it and
                // restores the normal button; a title/end-only update keeps it. Codex P2 (9f2f2d2):
                // in hold mode (detection off) nothing is watched, so a link change keeps the
                // fixed "Joining..." hold and its original deadline.
                let hold = watches[ObjectIdentifier(c)]?.expect == .hold
                if !hold && CardModel(ev).link != target {
                    watches[ObjectIdentifier(c)] = nil
                    log("opening \(c.ev.id ?? "nil") cancelled (link changed)")
                    c.setOpening(false)
                } else {
                    c.setOpening(true)   // refresh rebuilt the button
                }
            }
            writeState(c)
        default:
            break
        }
    }

    // MARK: cards

    @discardableResult
    public func showCard(_ ev: Event) -> Card {
        // #8/#11: create the card directly in its final slot (no show-then-move).
        let index = cards.firstIndex { Self.stackOrder(ev, $0.ev) } ?? cards.count
        let slot = CardSlot(index, offset: offset(below: Array(cards.prefix(index))))
        let c = makeCard(ev, slot, clock())
        cards.insert(c, at: index)
        slots[ObjectIdentifier(c)] = slot
        updateNextUp(c)
        restack()
        let link = CardModel(ev).link
        log("fire \(ev.id ?? "nil") start=\(ev.start?.dateTime ?? "nil") link=\(link.map { "\($0.provider) \($0.url)" } ?? "none")")
        writeState(c)
        reportCards()
        return c
    }

    /// Status light: count + the LEAD (soonest) card's provider.
    func reportCards() {
        let lead = cards.min { Self.stackOrder($0.ev, $1.ev) }
        onCards(cards.count, lead.flatMap { CardModel($0.ev).link?.provider })
    }

    /// #8: fixed stack key (start, title, id; nil = ""). See Timing.stackOrder.
    public static func stackOrder(_ a: Event, _ b: Event) -> Bool { Timing.stackOrder(a, b) }

    /// #11: the Next up line each card shows (absent = none).
    var nextUps: [ObjectIdentifier: NextUp.Parts] = [:]
    public func nextUp(_ c: Card) -> String? { nextUps[ObjectIdentifier(c)]?.line }

    /// #11: recompute one card's line from the list-poll cache; tell the card only on change.
    @discardableResult
    func updateNextUp(_ c: Card) -> Bool {
        let line = NextUp.parts(for: c.ev, pool: sched.cache)
        let id = ObjectIdentifier(c)
        guard line != nextUps[id] else { return false }
        // #11 review P2-2: a grow/shrink is a placement for the KeyGate (AppKit re-sends hover-enter
        // under a resting cursor once the tracking area grows). Forget the slot so the caller's
        // restack() re-places this card AFTER the resize: place() feeds `.placed(cursor:)`.
        if (line != nil) != (nextUps[id] != nil) { slots[id] = nil }
        nextUps[id] = line
        c.setNextUp(line)
        return true
    }

    /// #11: card-edge offset of a slot above `below` (a Next up line makes a card taller).
    func offset(below: [Card]) -> Double {
        CardLayout.stackOffset(below: below.map { nextUps[ObjectIdentifier($0)] != nil })
    }

    /// #8: sort by stackOrder and re-place only the cards whose slot changed (#11: index or
    /// offset, since a card below may have grown or shrunk).
    func restack() {
        cards.sort { Self.stackOrder($0.ev, $1.ev) }
        for (i, c) in cards.enumerated() {
            let slot = CardSlot(i, offset: offset(below: Array(cards.prefix(i))))
            guard slots[ObjectIdentifier(c)] != slot else { continue }
            slots[ObjectIdentifier(c)] = slot
            c.place(slot)
        }
    }

    public func closeCard(_ c: Card) {
        c.rk.close()
        watches[ObjectIdentifier(c)] = nil
        sched.closed(c.ev)
        c.close()
        cards.removeAll { $0 === c }
        slots[ObjectIdentifier(c)] = nil
        nextUps[ObjectIdentifier(c)] = nil
        refreshNextUps()   // #11 review P2-1: a close often follows a cache replacement
        log("card closed \(c.ev.id ?? "nil")")
        reportCards()
    }

    /// Join / Open in Calendar: returns the URL the app must open (nil = no button, or already
    /// opening). #4: a video Join keeps the card up in "Joining..." for the fixed hold (detection off) or until `openTick` sees the
    /// meeting surface (or times out); Open in Calendar still closes at once (nothing to detect).
    public func join(_ c: Card) -> String? {
        guard let link = CardModel(c.ev).link else { return nil }
        let id = c.ev.id ?? "nil"
        if isOpening(c) {
            log("click join \(id) ignored (already opening)")
            return nil
        }
        let calendar = link.provider == "calendar"
        log("click \(calendar ? "calendar" : "join") \(id) url=\(link.url)")
        sched.ignore(c.ev)
        if calendar {
            closeCard(c)
        } else {
            let w = detection ? OpenWatch(provider: link.provider, at: mono(), probe: probe())
                              : OpenWatch(holdAt: mono())
            watches[ObjectIdentifier(c)] = w
            c.setOpening(true)
            log("opening \(id) waiting for \(w.label)")
        }
        return link.url
    }

    public func isOpening(_ c: Card) -> Bool { watches[ObjectIdentifier(c)] != nil }
    public var anyOpening: Bool { !watches.isEmpty }

    /// #4 poll (App: every 0.5s). One snapshot per call, and none while nothing is opening.
    public func openTick() {
        guard !watches.isEmpty else { return }
        let p = detection ? probe() : OpenProbe(), t = mono()
        for c in cards {
            guard let w = watches[ObjectIdentifier(c)] else { continue }
            switch w.step(p, at: t) {
            case .waiting: break
            case .opened(let why):
                log("opened \(c.ev.id ?? "nil") (\(why))")
                closeCard(c)
            case .timedOut:
                watches[ObjectIdentifier(c)] = nil
                log("open timeout \(c.ev.id ?? "nil") after \(Int(OpenWatch.timeout))s; Join is back")
                c.setOpening(false)
            }
        }
    }

    public func ignore(_ c: Card) {
        log("click ignore \(c.ev.id ?? "nil")")
        sched.ignore(c.ev)
        closeCard(c)
    }
}
