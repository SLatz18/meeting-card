import Foundation
import ListenMoreCore

/// A cue the rules say must (or, at a threshold's edge, may) fire, in a window of scenario seconds.
public struct ExpectedCue: Sendable {
    public var type: CueType
    public var level: CueLevel?
    public var window: ClosedRange<Double>
    /// Borderline (within the tolerance of a threshold): firing or not both pass.
    public var optional: Bool
    public var reason: String
}

public struct CueMatch: Sendable {
    public struct Outcome: Sendable {
        public var expected: ExpectedCue
        public var actual: CueRecord?
    }

    public var outcomes: [Outcome]
    /// Cues no rule called for.
    public var falseCues: [CueRecord]
    /// Cues a rule may raise here but the oracle can't time (judge verdicts live, edge cases).
    public var tolerated: [CueRecord]

    public var missed: [ExpectedCue] { outcomes.filter { $0.actual == nil && !$0.expected.optional }.map(\.expected) }
    public var passed: Bool { missed.isEmpty && falseCues.isEmpty }
}

/// The cue rules, restated from the config's constants, applied to the realized script: which cues
/// must fire and when. Independent of the engine's code: it reads only `ListenMoreConfig` values and
/// the script (who spoke when, what was said, mute / pause / unmute times), so a rule regression in the
/// engine shows up as a missed or false cue. Covers what the scenarios exercise: cut-in (overlap,
/// continue, backchannel, question nearby, unmute grace), monologue (soft/strong, relative and how/why
/// thresholds), missed question (direct answer, shared words, decide words, end of turn), the
/// cooldowns, the closing-phrase quiet, and the pause and mute gates.
public enum CueOracle {
    public struct Facts: Sendable {
        public var keyless: Bool
        public var gptStopT: Double?
        public var mode: Mode

        public init(keyless: Bool, gptStopT: Double?, mode: Mode) {
            self.keyless = keyless
            self.gptStopT = gptStopT
            self.mode = mode
        }
    }

    public static func expected(_ timeline: Timeline, config c: ListenMoreConfig, facts: Facts) -> (cues: [ExpectedCue], tolerated: Set<CueType>) {
        let l = c.local
        let hang = Double(c.vad.hangoverMs) / 1000
        let end = timeline.duration
        let mutes = timeline.windows(.mute, .unmute, end: end)
        let pauses = timeline.windows(.pause, .resume, end: end)
        let unmutes = timeline.times(.unmute)
        let stops = timeline.times(.callEnds).map { $0 + c.trigger.stopAfterS } + timeline.times(.stopCoach)
        let captureEnd = stops.min() ?? end
        let live = facts.mode == .live
        func inside(_ ws: [ClosedRange<Double>], _ t: Double) -> Bool { ws.contains { $0.contains(t) } }
        func textOn(_ t: Double) -> Bool { !facts.keyless && (facts.gptStopT.map { t < $0 } ?? true) }
        let lines = timeline.lines.sorted { $0.start < $1.start }
        let you = lines.filter { $0.line.voice == .you }
        let them = lines.filter { $0.line.voice != .you }
        func heard(_ p: PlacedLine) -> Bool {
            p.start < captureEnd && !inside(pauses, p.start) && !(p.line.voice == .you && inside(mutes, p.start))
        }

        var cands: [ExpectedCue] = []
        var tolerated: Set<CueType> = live ? [.notListening] : []

        // Cut-in.
        let cutOverlap = l.cutInMinOverlapMs / 1000, cutContinue = l.cutInOthersContinueMs / 1000
        let cutBackchannel = l.cutInBackchannelMaxMs / 1000, cutMidPause = l.cutInOthersPauseMs / 1000
        for u in you where heard(u) {
            if unmutes.contains(where: { u.start >= $0 && u.start < $0 + l.unmuteGraceS }) { continue }
            let active = them.filter { heard($0) && $0.start <= u.start && ($0.end + hang >= u.start || u.start - $0.end <= cutMidPause) }
            guard let th = active.max(by: { $0.end < $1.end }) else { continue }
            let overlap = min(u.end, th.end) - u.start
            let othersAfter = th.end - u.start
            let run = u.end + hang - u.start
            if overlap >= cutOverlap && othersAfter >= cutContinue && run >= cutBackchannel {
                let fire = u.start + max(cutBackchannel, cutOverlap, cutContinue)
                let questionNear = textOn(fire) && them.contains {
                    ScriptText.endsWithQuestion($0.line.text) && $0.end >= u.start - l.cutInQuestionLookbackS && $0.end <= u.start + 2
                }
                if questionNear || inside(pauses, fire) || inside(mutes, fire) || fire >= captureEnd { continue }
                let window = live ? (u.start + 0.6)...(fire + 2.0) : (fire - 0.25)...(fire + 0.5)
                cands.append(ExpectedCue(type: .interrupt, level: nil, window: window, optional: false,
                                         reason: "\(u.line.id) cuts in on \(th.line.id): overlap \(fmt(overlap)) s, they continue \(fmt(othersAfter)) s"))
            } else if overlap >= l.cutInTrailingMinOverlapMs / 1000 && abs(th.end - u.start) <= l.cutInTrailingWindowS {
                tolerated.insert(.interrupt)
            }
        }

        // Monologue: runs of You speech (gaps under monologue_me_gap_reset_s, Them not holding the floor
        // for monologue_others_floor_ms), reset by Mute and by Pause (a new engine).
        var prior: [Double] = []
        var runStart: Double?
        var runEnd = 0.0
        func closeRun() {
            guard let s = runStart else { return }
            let length = runEnd + hang - s
            var soft = l.monologueSoftS
            let done = prior.filter { $0 >= l.monologueRelativeMinRunS }
            if done.count >= l.monologueRelativeMinRuns {
                soft = min(soft, max(l.monologueRelativeFactor * median(done), l.monologueRelativeMinS))
            }
            let howWhy = textOn(s) && them.contains { p in
                p.end >= s - c.text.howWhyLookbackS && p.end <= s + 0.5 && ScriptText.sentences(p.line.text).contains {
                    $0.hasSuffix("?") && ScriptText.tokens($0).first.map { c.text.howWhyWords.contains($0) } == true
                }
            }
            let raise = howWhy ? l.monologueHowWhyRaise : 1
            let edge = live ? 3.0 : 1.5
            for (level, threshold) in [(CueLevel.soft, soft * raise), (.strong, l.monologueStrongS * raise)] {
                guard length >= threshold - edge else { continue }
                let at = s + threshold
                if inside(pauses, at) || at >= captureEnd { continue }
                cands.append(ExpectedCue(type: .monologue, level: level,
                                         window: live ? (at - 1.5)...(at + 2.0) : (at - 0.3)...(at + 0.6),
                                         optional: length < threshold + edge,
                                         reason: "run from \(fmt(s)) s lasts \(fmt(length)) s; \(level.rawValue) at \(fmt(threshold)) s"))
            }
            prior.append(length)
            runStart = nil
        }
        let resumes = pauses.map(\.upperBound)
        let edges = mutes.flatMap { [$0.lowerBound, $0.upperBound] } + pauses.map(\.lowerBound) + resumes
        var previous: Double?
        for u in you where heard(u) {
            if runStart != nil {
                let gap = u.start - (runEnd + hang)
                let othersHeld = them.contains { $0.start >= runEnd && $0.end <= u.start && $0.end - $0.start >= l.monologueOthersFloorMs / 1000 }
                let reset = edges.contains { $0 > runEnd && $0 <= u.start }
                if gap >= l.monologueMeGapResetS || othersHeld || reset { closeRun() }
            }
            if let p = previous, resumes.contains(where: { $0 > p && $0 <= u.start }) { prior.removeAll() }
            previous = u.start
            if runStart == nil { runStart = u.start }
            runEnd = max(runEnd, u.end)
        }
        closeRun()

        // Missed question (transcript rule; needs the GPT layer's transcripts).
        let questions = them.filter { heard($0) && ScriptText.endsWithQuestion($0.line.text) }
        for (i, q) in questions.enumerated() where textOn(q.end) && !inside(mutes, q.end) && !inside(pauses, q.end) {
            let nextQ = i + 1 < questions.count ? questions[i + 1].end : Double.infinity
            guard let r = you.first(where: { heard($0) && $0.end >= q.end && !inside(mutes, $0.start) }), r.start < nextQ else { continue }
            if (mutes.map(\.lowerBound) + mutes.map(\.upperBound)).contains(where: { $0 > q.end && $0 <= r.start }) { continue }
            let othersAfter = them.filter { $0.start >= q.end && $0.end <= r.start }.reduce(0.0) { $0 + Double($1.line.words.count) / 2.6 }
            if othersAfter >= c.text.questionOthersAnsweredS { continue }
            let question = ScriptText.sentences(ScriptText.normalize(q.line.text)).last ?? ""
            let reply = ScriptText.normalize(r.line.text)
            if ScriptText.sentences(reply).first?.hasSuffix("?") == true {
                tolerated.insert(.missedQuestion)
                continue
            }
            if c.text.questionOpenInvites.contains(where: { ScriptText.contains(question, phrase: $0) }) { continue }
            if reply.unicodeScalars.first.map({ CharacterSet.decimalDigits.contains($0) }) == true
                || c.text.directAnswerOpeners.contains(where: { ScriptText.starts(reply, with: $0) }) { continue }
            let stop = Set(c.text.stopwords)
            let shared = ScriptText.content(question, stop: stop).intersection(ScriptText.content(reply, stop: stop))
            if shared.count >= c.text.questionClearMinSharedWords { continue }
            let decided = ScriptText.tokens(reply).count >= c.text.questionDecideWords
            let at = decided ? r.end : r.end + l.monologueMeGapResetS
            if inside(pauses, at) || at >= captureEnd { continue }
            cands.append(ExpectedCue(type: .missedQuestion, level: .soft,
                                     window: live ? at...(at + 6.0) : (at - 0.3)...(at + 1.0), optional: false,
                                     reason: "\(r.line.id) doesn't take up \(q.line.id)'s question (\(shared.count) shared words)"))
        }

        // Cue policy: one at a time, cooldowns, the closing-phrase quiet.
        let quiet = lines.filter { p in c.text.closingPhrases.contains { ScriptText.contains(ScriptText.normalize(p.line.text), phrase: $0) } }
            .map { $0.end...($0.end + c.text.closingQuietS) }
        var accepted: [ExpectedCue] = []
        for e in cands.sorted(by: { $0.window.lowerBound < $1.window.lowerBound }) {
            let t = e.window.lowerBound
            if inside(quiet, t) { continue }
            let blocked = accepted.contains { a in
                !a.optional && t - a.window.lowerBound < max(c.cues.globalCooldownS, a.type == e.type ? c.cues.cooldownS : 0)
            }
            if blocked { continue }
            accepted.append(e)
        }
        return (accepted, tolerated)
    }

    /// Each expected cue takes the first unused actual cue of its type (and level) inside its window.
    public static func match(expected: [ExpectedCue], tolerated: Set<CueType>, actual: [CueRecord]) -> CueMatch {
        var used = Set<Int>()
        var outcomes: [CueMatch.Outcome] = []
        for e in expected {
            let i = actual.indices.first { i in
                !used.contains(i) && actual[i].type == e.type && (e.level == nil || actual[i].level == e.level) && e.window.contains(actual[i].t)
            }
            if let i { used.insert(i) }
            outcomes.append(.init(expected: e, actual: i.map { actual[$0] }))
        }
        var falseCues: [CueRecord] = []
        var tol: [CueRecord] = []
        for (i, a) in actual.enumerated() where !used.contains(i) {
            if tolerated.contains(a.type) { tol.append(a) } else { falseCues.append(a) }
        }
        return CueMatch(outcomes: outcomes, falseCues: falseCues, tolerated: tol)
    }

    static func median(_ xs: [Double]) -> Double {
        let s = xs.sorted()
        guard !s.isEmpty else { return 0 }
        return s.count % 2 == 1 ? s[s.count / 2] : (s[s.count / 2 - 1] + s[s.count / 2]) / 2
    }

    static func fmt(_ x: Double) -> String { String(format: "%.1f", x) }
}

/// Word-level helpers for the oracle and the scores, on the script's text (Python-regex semantics
/// like the transcript rules: lower-case, `[a-z0-9']+` tokens, `[^.?!]+[.?!]*` sentences).
public enum ScriptText {
    public static func normalize(_ s: String) -> String {
        s.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
    }

    public static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        for ch in normalize(s).unicodeScalars {
            if ch == "'" || ("a"..."z").contains(ch) || ("0"..."9").contains(ch) {
                cur.unicodeScalars.append(ch)
            } else if !cur.isEmpty {
                out.append(cur)
                cur = ""
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out
    }

    public static func sentences(_ s: String) -> [String] {
        var out: [String] = []
        var cur = ""
        var tail = false
        for ch in s {
            if ch == "." || ch == "?" || ch == "!" {
                if cur.isEmpty { continue }
                cur.append(ch)
                tail = true
            } else {
                if tail {
                    out.append(cur)
                    cur = ""
                    tail = false
                }
                cur.append(ch)
            }
        }
        if !cur.isEmpty { out.append(cur) }
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    public static func endsWithQuestion(_ s: String) -> Bool {
        sentences(s).last?.hasSuffix("?") == true
    }

    static func stem(_ word: String) -> String {
        var w = word
        if w.hasSuffix("'s") { w.removeLast(2) }
        if w.count > 4 && w.hasSuffix("es") {
            let base = String(w.dropLast(2))
            if ["s", "sh", "ch", "x", "z"].contains(where: { base.hasSuffix($0) }) { return base }
        }
        if w.count > 3 && w.hasSuffix("s") && !w.hasSuffix("ss") { return String(w.dropLast()) }
        return w
    }

    public static func content(_ s: String, stop: Set<String>) -> Set<String> {
        Set(tokens(s).filter { !stop.contains($0) && $0.count > 2 && !$0.allSatisfy(\.isNumber) }.map(stem))
    }

    static func contains(_ text: String, phrase: String) -> Bool {
        let t = " " + tokens(text).joined(separator: " ") + " "
        return t.contains(" " + tokens(phrase).joined(separator: " ") + " ")
    }

    static func starts(_ text: String, with phrase: String) -> Bool {
        let t = tokens(text), p = tokens(phrase)
        return !p.isEmpty && t.count >= p.count && Array(t.prefix(p.count)) == p
    }
}
