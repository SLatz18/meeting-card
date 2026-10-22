import Foundation

/// Pure scheduling state: cached events, pending pre-fire checks, fire-once and ignore
/// sets, ids on screen. Port of scheduler.py. Main-thread only (no locks needed in Swift:
/// every mutation is delivered on the main queue).
public final class Scheduler {
    public static let pendingMax: TimeInterval = 20

    public private(set) var cache: [Event] = []
    public var fired = Set<EventKey>()
    public private(set) var ignored = Set<EventKey>()
    /// In-flight pre-fire checks. `token` is a monotonic request id: a reply must match it, so a
    /// superseded (late, post-fallback) reply can never resolve a newer request for the same key.
    public private(set) var pending: [EventKey: (ev: Event, since: Date, token: Int)] = [:]
    public private(set) var showing = Set<String?>()
    private var nextToken = 0
    let log: (String) -> Void

    public init(log: @escaping (String) -> Void = { _ in }) { self.log = log }

    /// Replace the cache from a successful fetch. nil = failed fetch: keep cache.
    @discardableResult
    public func update(_ items: [Event]?) -> Bool {
        guard let items else {
            log("poll failed; keeping \(cache.count) cached events")
            return false
        }
        var kept: [Event] = []
        for ev in items {
            if let r = Timing.skipReason(ev) {
                log("skip \(ev.id ?? "nil"): \(r)")
            } else {
                kept.append(ev)
            }
        }
        cache = kept
        log("poll ok: \(items.count) items, \(kept.count) kept")
        return true
    }

    /// Events that need a pre-fire check now; marks them pending. Caller must resolve() each.
    public func due(_ now: Date) -> [Event] {
        var out: [Event] = []
        var busy = showing.union(pending.values.map { $0.ev.id })
        for ev in cache {
            let k = Timing.key(ev)
            if fired.contains(k) || ignored.contains(k) || pending[k] != nil { continue }
            // #13: a fresh single-event get said skip (e.g. no-video). Never offered again until a
            // SUCCESSFUL list poll replaces this copy: bounds gets to the poll interval.
            if Timing.skipReason(ev) != nil { continue }
            if busy.contains(ev.id) { continue }  // same id checking or on screen: never a 2nd card
            if Timing.isDue(ev, now) {
                nextToken += 1
                pending[k] = (ev, now, nextToken)
                busy.insert(ev.id)
                out.append(ev)
            }
        }
        return out
    }

    /// Pending checks older than pendingMax: caller treats them as failed (show cached).
    public func stale(_ now: Date) -> [Event] {
        pending.values.filter { now.timeIntervalSince($0.since) > Scheduler.pendingMax }.map { $0.ev }
    }

    /// Token of the in-flight pre-fire check for ev's key (nil = not pending).
    public func token(_ ev: Event) -> Int? { pending[Timing.key(ev)]?.token }

    private func replace(_ fresh: Event) {
        cache = cache.map { $0.id == fresh.id ? fresh : $0 }
    }

    /// Apply a pre-fire decision. false = not pending, or pending under a different request
    /// token (superseded reply): drop it. token nil = the current request (unit tests only).
    @discardableResult
    public func resolve(_ cached: Event, _ action: RecheckAction, _ ev: Event, token: Int? = nil) -> Bool {
        let k = Timing.key(cached)
        guard let p = pending[k], token == nil || p.token == token else { return false }
        pending.removeValue(forKey: k)
        switch action {
        case .show:
            fired.insert(k)
            fired.insert(Timing.key(ev))
            showing.insert(ev.id)
            replace(ev)
        case .skip:
            if Timing.skipReason(ev) != nil {
                replace(ev)  // fresh result wins the cache; due() skips it until a good poll
                if Timing.skipReason(ev) != "no-video" { fired.insert(k) }
            } else {
                fired.insert(k)
            }
        case .reschedule:
            fired.insert(k)
            replace(ev)
        default:
            break
        }
        return true
    }

    /// A live card's event moved/changed: cache the fresh copy and mark its key fired.
    public func rekey(_ ev: Event) {
        fired.insert(Timing.key(ev))
        replace(ev)
    }

    /// Live card closed because its start moved out of the window: the new key fires later.
    public func reschedule(_ ev: Event) { replace(ev) }

    /// #13: a live card closed because the fresh copy is skipped: the fresh copy wins the cache
    /// (due() never offers it). For no-video also forget EVERY fired key for the id (rekeys
    /// included), so a restored link at any start fires again.
    public func skippedClosed(_ fresh: Event) {
        replace(fresh)
        if Timing.skipReason(fresh) == "no-video" { fired = fired.filter { $0.id != fresh.id } }
    }

    /// A card for ev's id left the screen (any reason).
    public func closed(_ ev: Event) { showing.remove(ev.id) }

    public func ignore(_ ev: Event) { ignored.insert(Timing.key(ev)) }
}
