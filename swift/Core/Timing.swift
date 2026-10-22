import Foundation

/// Port of the time half of events.py: parse, filter, due window, countdown, recheck decision.
public enum Timing {
    public static let lead: TimeInterval = 2 * 60   // card appears at start - 2 min
    public static let grace: TimeInterval = 5 * 60  // appear window closes at start + 5 min

    private static let rfc3339 = try! NSRegularExpression(pattern:
        // [0-9], never \d: ICU \d matches Unicode digits (e.g. Arabic-Indic) that Int() rejects.
        #"^([0-9]{4})-([0-9]{2})-([0-9]{2})T([0-9]{2}):([0-9]{2})(?::([0-9]{2})(\.[0-9]+)?)?(Z|z|[+-][0-9]{2}:?[0-9]{2})$"#)

    /// Parse an RFC3339 dateTime honoring its offset. The event timeZone field is ignored.
    /// nil for anything without an explicit offset (Python would fail comparing naive/aware).
    public static func parseDT(_ s: String) -> Date? {
        let ns = s as NSString
        guard let m = rfc3339.firstMatch(in: s, range: NSRange(location: 0, length: ns.length)) else { return nil }
        func g(_ i: Int) -> String? {
            let r = m.range(at: i)
            return r.location == NSNotFound ? nil : ns.substring(with: r)
        }
        // No force-unwraps on parsed external data: any surprise is nil (-> bad-dateTime), never a trap.
        guard let y = g(1).flatMap({ Int($0) }), let mo = g(2).flatMap({ Int($0) }),
              let day = g(3).flatMap({ Int($0) }), let h = g(4).flatMap({ Int($0) }),
              let mi = g(5).flatMap({ Int($0) }), let sec = Int(g(6) ?? "0"),
              let off = g(8) else { return nil }
        // Range-check like Python fromisoformat; Calendar would silently normalize (month 13).
        guard (1...12).contains(mo), (1...31).contains(day), (0...23).contains(h),
              (0...59).contains(mi), (0...59).contains(sec) else { return nil }
        var c = DateComponents()
        c.year = y; c.month = mo; c.day = day; c.hour = h; c.minute = mi; c.second = sec
        var secs = 0
        if off != "Z" && off != "z" {
            let sign = off.hasPrefix("-") ? -1 : 1
            let digits = off.dropFirst().replacingOccurrences(of: ":", with: "")
            guard let oh = Int(digits.prefix(2)), let om = Int(digits.suffix(2)) else { return nil }
            secs = sign * (oh * 3600 + om * 60)
        }
        guard let tz = TimeZone(secondsFromGMT: secs) else { return nil }
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        guard let d = cal.date(from: c), cal.component(.day, from: d) == c.day else { return nil }
        let frac = g(7).flatMap { Double("0" + $0) } ?? 0
        return d.addingTimeInterval(frac)
    }

    /// A reason string if the event should never show, else nil. Same order as Python.
    public static func skipReason(_ ev: Event) -> String? {
        let start = ev.start ?? EventTime()
        if start.date != nil && start.dateTime == nil { return "all-day" }
        let et = ev.eventType ?? "default"
        if et != "default" { return "eventType=\(et)" }
        if ev.status == "cancelled" { return "cancelled" }
        for a in ev.attendees ?? [] where a.isSelf == true && a.responseStatus == "declined" {
            return "declined"
        }
        guard let s = start.dateTime, let e = ev.end?.dateTime else { return "no-dateTime" }
        // Swift-only guard (no exceptions): an unparseable time must never reach the timers.
        if parseDT(s) == nil || parseDT(e) == nil { return "bad-dateTime" }
        if cardKind(ev) == nil { return "no-video" }  // #13: last, so earlier reasons win
        return nil
    }

    /// #13: the ONE rule for which card an event gets (list filter, pre-fire, live re-check
    /// and the card view all go through here). nil = no card (`no-video`).
    /// Video link(s) -> Join / multi-link. No link -> a "No video link" card only when someone
    /// else organized it (missing organizer counts as someone else) and location is blank.
    public static func cardKind(_ ev: Event) -> CardKind? {
        let links = Links.videoLinks(ev)
        if links.count >= 2 { return .multi(links) }
        if let l = links.first { return .join(l) }
        let blank = (ev.location ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        if ev.organizer?.isSelf != true && blank { return .noLink }
        return nil
    }

    public static func times(_ ev: Event) -> (start: Date, end: Date)? {
        guard let s = ev.start?.dateTime.flatMap(parseDT), let e = ev.end?.dateTime.flatMap(parseDT) else { return nil }
        return (s, e)
    }

    /// True if now is within [start-LEAD, start+GRACE] and before end.
    public static func isDue(_ ev: Event, _ now: Date) -> Bool {
        guard let (start, end) = times(ev) else { return false }
        return start.addingTimeInterval(-lead) <= now && now <= start.addingTimeInterval(grace) && now < end
    }

    /// #8: fixed stack / tie-break key, ascending: start, then title, then id (nil = "").
    public static func stackOrder(_ a: Event, _ b: Event) -> Bool {
        let sa = times(a)?.start ?? .distantFuture, sb = times(b)?.start ?? .distantFuture
        if sa != sb { return sa < sb }
        let ta = a.summary ?? "", tb = b.summary ?? ""
        if ta != tb { return ta < tb }
        return (a.id ?? "") < (b.id ?? "")
    }

    public static func key(_ ev: Event) -> EventKey { EventKey(id: ev.id, start: ev.start?.dateTime) }

    /// "in N min" rounded UP (T-2:00..T-1:01 -> 2, T-1:00..T-0:01 -> 1), then "now".
    public static func countdownSuffix(_ ev: Event, _ now: Date) -> String {
        guard let (start, _) = times(ev) else { return "now" }
        let secs = start.timeIntervalSince(now)
        if secs <= 0 { return "now" }
        return "in \(Int((secs / 60.0).rounded(.up))) min"
    }

    /// "Ends 9:55 AM" in the given time zone (default: the Mac's).
    public static func formatEnds(_ end: Date, timeZone: TimeZone = .current) -> String {
        "Ends " + formatClock(end, timeZone: timeZone)
    }

    /// "9:55 AM" (12-hour) in the given time zone.
    public static func formatClock(_ d: Date, timeZone: TimeZone = .current) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let hour = cal.component(.hour, from: d)
        let minute = cal.component(.minute, from: d)
        let h = hour % 12 == 0 ? 12 : hour % 12
        return String(format: "%d:%02d %@", h, minute, hour < 12 ? "AM" : "PM")
    }

    static func content(_ ev: Event) -> [AnyHashable] {
        [ev.summary as AnyHashable, ev.end?.dateTime as AnyHashable,
         Links.videoLinks(ev) as AnyHashable, ev.htmlLink as AnyHashable,
         cardKind(ev) as AnyHashable]
    }

    /// Decide what to do with a card given a fresh single-event get.
    /// fresh == nil means the get FAILED: never suppress or close on failure.
    public static func recheckAction(cached: Event, fresh: Event?, now: Date, phase: Phase) -> (RecheckAction, Event) {
        let pre = phase == .prefire
        guard let fresh else { return pre ? (.show, cached) : (.keep, cached) }
        if skipReason(fresh) != nil { return pre ? (.skip, fresh) : (.close, fresh) }
        let moved = fresh.start?.dateTime != cached.start?.dateTime
        if !pre {
            // Live: the appear window does not apply; the card stays until end.
            guard let (start, end) = times(fresh) else { return (.keep, cached) }
            if now >= end { return (.close, fresh) }  // fresh end first: moved + ended closes
            if moved && start.addingTimeInterval(-lead) > now { return (.closeReschedule, fresh) }
            if moved { return (.update, fresh) }
            if content(fresh) != content(cached) { return (.update, fresh) }
            return (.keep, cached)
        }
        let due = isDue(fresh, now)
        if moved && !due { return (.reschedule, fresh) }
        if !due { return (.skip, fresh) }
        return (.show, fresh)
    }
}

public enum CardKind: Hashable, Sendable {
    case join(VideoLink)
    case multi([VideoLink])
    case noLink
}

public struct EventKey: Hashable, Sendable {
    public let id: String?
    public let start: String?
}

public enum Phase: Sendable { case prefire, live }

public enum RecheckAction: String, Sendable {
    case show, skip, reschedule, keep, close, closeReschedule = "close_reschedule", update
}

/// Per-card live re-check state (pure, monotonic clock injected). One request in flight
/// at a time; next check measured from completion; >20 s in flight = lost; replies from a
/// superseded generation or after close are dropped.
public final class Rechecker {
    public static let interval: TimeInterval = 10
    public static let inflightMax: TimeInterval = 20

    public private(set) var nextCheck: TimeInterval
    public private(set) var inflight = false
    public private(set) var inflightSince: TimeInterval?
    public private(set) var closed = false
    public private(set) var gen = 0
    let log: (String) -> Void

    public init(now: TimeInterval, log: @escaping (String) -> Void = { _ in }) {
        nextCheck = now + Rechecker.interval
        self.log = log
    }

    /// A generation id (pass back to accept) when a check should start now, else nil.
    public func shouldStart(_ now: TimeInterval) -> Int? {
        if closed { return nil }
        if inflight {
            let age = now - (inflightSince ?? now)
            if age <= Rechecker.inflightMax { return nil }
            log(String(format: "recheck: get in flight %.0fs; treating as lost", age))
        } else if now < nextCheck {
            return nil
        }
        inflight = true
        inflightSince = now
        gen += 1
        return gen
    }

    /// false = drop the result (card closed, or a superseded generation).
    public func accept(_ now: TimeInterval, _ g: Int) -> Bool {
        if g != gen { return false }
        inflight = false
        if closed { return false }
        nextCheck = now + Rechecker.interval
        return true
    }

    public func close() { closed = true }
}
