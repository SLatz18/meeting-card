import Foundation

/// #11: the muted "Next up" line for back-to-back meetings. Pure: the pool is the scheduler's
/// list-poll cache (the existing 60s poll, no extra calls).
public enum NextUp {
    /// A next meeting starting at most this long after the card's meeting ends counts.
    public static let window: TimeInterval = 15 * 60

    /// Self response that counts: accepted or no response (needsAction / none / no self
    /// attendee). Tentative and declined don't (OQ-8: #11 literally).
    static func responseOK(_ ev: Event) -> Bool {
        guard let me = ev.attendees?.first(where: { $0.isSelf == true }) else { return true }
        switch me.responseStatus {
        case nil, "accepted", "needsAction": return true
        default: return false
        }
    }

    /// The next back-to-back event for `card` from `pool`, or nil. Candidates (OQ-6): exactly
    /// the events that would get a card (skipReason nil, which includes cardKind != nil), not
    /// the card's own id, response accepted/none, starting after the card starts and no later
    /// than its end + window. Earliest wins; ties by the #8 stack key (title, then id).
    public static func next(for card: Event, pool: [Event]) -> Event? {
        guard let (cs, ce) = Timing.times(card) else { return nil }
        return pool.filter { ev in
            guard ev.id != card.id, Timing.skipReason(ev) == nil, responseOK(ev),
                  let (s, _) = Timing.times(ev) else { return false }
            return s > cs && s <= ce.addingTimeInterval(window)
        }.min(by: Timing.stackOrder)
    }

    /// #17: the line in parts so the App can truncate the TITLE only: prefix + title + suffix.
    public struct Parts: Equatable, Sendable {
        public static let prefix = "Next up: "
        public let title: String
        /// " @ 12:35 PM" (+ ", overlaps"): always shown whole.
        public let suffix: String
        public var line: String { Parts.prefix + title + suffix }
    }

    /// #17: "Next up: Team Standup @ 12:35 PM" (+ ", overlaps" when it starts before the card ends).
    public static func parts(for card: Event, pool: [Event], timeZone: TimeZone = .current) -> Parts? {
        guard let n = next(for: card, pool: pool), let (s, _) = Timing.times(n),
              let (_, ce) = Timing.times(card) else { return nil }
        // Codex P2 (0ef30ab): newlines/tabs measure narrow but render multiline, hiding the time.
        let flat = flatten(n.summary ?? "")
        let title = flat.isEmpty ? "(No title)" : flat
        return Parts(title: title, suffix: " @ \(Timing.formatClock(s, timeZone: timeZone))" + (s < ce ? ", overlaps" : ""))
    }

    public static func line(for card: Event, pool: [Event], timeZone: TimeZone = .current) -> String? {
        parts(for: card, pool: pool, timeZone: timeZone)?.line
    }

    /// #17: the longest "prefix + title-head + ... + suffix" that measures <= width (the whole line
    /// if it fits). Truncates the title, never the time; with no room left the title is just "...".
    public static func fit(_ p: Parts, width: Double, measure: (String) -> Double) -> String {
        tailFit(prefix: Parts.prefix, title: p.title, suffix: p.suffix, width: width, measure: measure)
    }

    /// Shared by #17 and v2.5 #4: the longest "prefix + title-head + ... + suffix" that measures
    /// <= width (the whole line if it fits). Only the title shrinks; with no room it is just "...".
    public static func tailFit(prefix: String, title: String, suffix: String, width: Double,
                               measure: (String) -> Double) -> String {
        if measure(prefix + title + suffix) <= width { return prefix + title + suffix }
        let t = Array(title)
        func cut(_ n: Int) -> String {
            let head = String(t.prefix(n)).trimmingCharacters(in: .whitespaces)
            return prefix + head + "\u{2026}" + suffix
        }
        var lo = 0, hi = max(t.count - 1, 0)   // largest n in 0...hi with measure(cut(n)) <= width
        if measure(cut(0)) > width { return cut(0) }
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if measure(cut(mid)) <= width { lo = mid } else { hi = mid - 1 }
        }
        return cut(lo)
    }

    /// Collapse newlines/tabs/runs of spaces (Codex P2, 0ef30ab): they measure narrow but wrap.
    public static func flatten(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}
