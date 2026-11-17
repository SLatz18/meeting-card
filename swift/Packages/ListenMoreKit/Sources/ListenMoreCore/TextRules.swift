import Foundation

/// Port of `listen_more/text_rules.py`: deterministic rules on the live transcript (question pending
/// and heat) plus the transcript checks the local layer and the engine ask for (a question right before
/// a cut-in, a how/why question before a long run, a round-robin handoff, number read-back during fast
/// switches, a closing phrase near the end of the call).
///
/// Segment text stays in RAM, is dropped by `clear()`, and is never logged. Candidates carry only a
/// type, times and a level.
public final class TextRules: LocalTextContext {
    struct Segment {
        let id: Int
        let speaker: Speaker
        /// Lower-cased.
        let text: String
        /// Audio time the speech ended (the VAD offset the transcript was committed at).
        let end: TimeInterval
        let words: [String]

        /// Spoken length estimate (~2.6 words/s).
        var estS: Double { Double(words.count) / 2.6 }
    }

    enum OpenKind { case invite, personal, aboutThem }

    final class Pending {
        let t: TimeInterval
        let content: Set<String>
        let openKind: OpenKind?
        let personal: Bool
        var replyContent: Set<String> = []
        var replyWords = 0
        var replyStarted = false
        var inTurn = false
        var turnLastEnd = 0.0
        var userTurns = 0
        var userVoicedS = 0.0
        var othersAfterS = 0.0
        var othersAnsweredAt: TimeInterval?
        var counter = false
        var softFired = false
        var strongFired = false

        init(t: TimeInterval, content: Set<String>, openKind: OpenKind?, personal: Bool) {
            self.t = t
            self.content = content
            self.openKind = openKind
            self.personal = personal
        }
    }

    public struct Outcomes: Equatable, Sendable {
        public var questionCleared = 0
        public var questionOthersAnswered = 0
        public var questionTimedOut = 0
    }

    private let x: ListenMoreConfig.Text
    private let monoGap: Double
    private let questionLookback: Double
    private let readbackMaxTurn: Double
    private let participants: Int
    private let meetingOffsetS: Double
    private let names: Set<String>
    private let stop: Set<String>
    private let numbers: Set<String>
    private let confirm: Set<String>
    private let prosodyOn: Bool
    private let riseDb: Double
    private let risePct: Double
    private var segments: [Segment] = []
    private var nextId = 0
    var pending: Pending?
    private var commitText = ""
    private var heatItems: [(t: TimeInterval, points: Int, structural: Int, strong: Int)] = []
    private var heatShownThisTurn = false
    private var prosody: [(t: TimeInterval, db: Double, pct: Double)] = []
    private var closingT: TimeInterval?
    private var userQuietSince = 0.0
    public private(set) var outcomes = Outcomes()
    /// The user's mic is off (`setMicMuted`): no question waits on an answer they can't give.
    public private(set) var micMuted = false

    public init(config: ListenMoreConfig, participants: Int = 2, meetingOffsetS: Double = 0) {
        x = config.text
        monoGap = config.local.monologueMeGapResetS
        questionLookback = config.local.cutInQuestionLookbackS
        readbackMaxTurn = config.local.talkOverReadbackMaxTurnS
        self.participants = participants
        self.meetingOffsetS = meetingOffsetS
        names = Set(x.userNames.map { $0.lowercased() })
        stop = Set(x.stopwords)
        numbers = Set(x.numberWords)
        confirm = Set(x.confirmWords)
        prosodyOn = config.local.prosodyEnabled
        risePct = x.heatProsodyMinRisePct
        riseDb = 20 * log10(1 + risePct / 100)
    }

    // MARK: inputs

    public func onLocal(_ ev: LocalEvent) {
        guard ev.kind == .prosody, let p = ev.prosody, p.baselineReady else { return }
        prosody.append((ev.onset, p.loudnessJumpDb, p.rateJumpPct))
    }

    /// The user's mic went off (true) or came back. Either way a pending question is dropped, and
    /// while it's off the other side's questions don't open one, so neither the gap nor the user's
    /// first words back ("sorry, I was on mute") read as a missed answer.
    public func setMicMuted(_ muted: Bool) {
        guard muted != micMuted else { return }
        micMuted = muted
        pending = nil
    }

    /// The rules run sentence by sentence, so a question or a contradiction is judged where it sits in
    /// the commit; an apology or a personal topic anywhere in the commit still vetoes heat for all of it.
    public func onSegment(_ speaker: Speaker, text: String, refT: TimeInterval, now: TimeInterval) -> [CueSuggestion] {
        let low = Self.normalize(text).trimmingCharacters(in: .whitespacesAndNewlines)
        commitText = low
        var out: [CueSuggestion] = []
        for sent in Self.sentences(low) {
            out += piece(speaker, sent, refT, now)
        }
        return out
    }

    private func piece(_ speaker: Speaker, _ low: String, _ refT: TimeInterval, _ now: TimeInterval) -> [CueSuggestion] {
        let seg = Segment(id: nextId, speaker: speaker, text: low, end: refT >= 0 ? refT : now, words: Self.tokens(low))
        nextId += 1
        segments.append(seg)
        while let first = segments.first, now - first.end > 120 { segments.removeFirst() }
        if x.closingPhrases.contains(where: { Self.phraseCount(low, $0) > 0 }) { closingT = seg.end }
        if speaker == .others {
            heatShownThisTurn = false
            return othersSegment(seg, now)
        }
        return userSegmentQuestion(seg, now) + heat(seg, now)
    }

    /// The policy showed a cue. Heat shows once per user turn; a held heat cue is retried.
    public func shown(_ type: CueType) {
        if type == .aggressive { heatShownThisTurn = true }
    }

    public func onTick(now: TimeInterval, userActive: Bool, frameS: Double) -> [CueSuggestion] {
        if userActive { userQuietSince = now }
        guard let q = pending else { return [] }
        var out: [CueSuggestion] = []
        if userActive && now > q.t { q.userVoicedS += frameS }
        if let answered = q.othersAnsweredAt, now - answered >= x.questionTimeoutAfterOthersS {
            outcomes.questionOthersAnswered += 1
            pending = nil
            return out
        }
        if q.inTurn && !userActive && now - userQuietSince >= monoGap {
            out += endUserTurn(q, now)
            if pending == nil { return out }
        }
        if q.replyStarted && !q.strongFired && q.userVoicedS >= x.questionEscalateUserS {
            q.strongFired = true
            q.softFired = true
            out.append(CueSuggestion(type: .missedQuestion, t: now, onset: q.turnLastEnd, source: .text, level: .strong))
        }
        return out
    }

    // MARK: question pending

    private func content(_ words: [String]) -> Set<String> {
        Set(words.filter { !stop.contains($0) && !Self.isDigits($0) && $0.count > 2 }.map(Self.stem))
    }

    private func othersSegment(_ seg: Segment, _ now: TimeInterval) -> [CueSuggestion] {
        var out: [CueSuggestion] = []
        var q = pending
        if let p = q, p.inTurn {
            out += endUserTurn(p, now)
            q = pending
        }
        let sents = Self.sentences(seg.text)
        if !micMuted, let question = sents.last, question.hasSuffix("?") {
            let named = !names.isDisjoint(with: seg.words)
            if named || participants == 2 {
                let (kind, personal) = openKind(question)
                pending = Pending(t: seg.end, content: content(Self.tokens(question)), openKind: kind, personal: personal)
                return out
            }
        }
        if let q, !q.replyStarted {
            q.othersAfterS += seg.estS
            if q.othersAnsweredAt == nil && q.othersAfterS >= x.questionOthersAnsweredS { q.othersAnsweredAt = now }
        }
        return out
    }

    private func isPersonal(_ text: String) -> Bool {
        x.heatPersonal.contains { Self.phraseCount(text, $0) > 0 }
    }

    /// Open questions ask the user to share, not for a fact: an invitation, a small-talk check-in on a
    /// personal topic, or a question about their own plans. Their answer need not repeat the question's words.
    private func openKind(_ question: String) -> (OpenKind?, Bool) {
        let personal = isPersonal(question)
        if x.questionOpenInvites.contains(where: { Self.phraseCount(question, $0) > 0 }) { return (.invite, personal) }
        if personal && x.questionCheckInOpeners.contains(where: { Self.startsWith(question, $0) }) { return (.personal, personal) }
        if x.questionAboutHimOpeners.contains(where: { Self.startsWith(question, $0) }) { return (.aboutThem, personal) }
        return (nil, personal)
    }

    /// The user's opening sentence takes up an open question: any reply to an invitation, the same
    /// personal topic, or enough content words from the question.
    private func onTopic(_ q: Pending, _ sent: String) -> Bool {
        if q.openKind == .invite { return true }
        if q.personal && isPersonal(sent) { return true }
        return q.content.intersection(content(Self.tokens(sent))).count >= x.questionOpenMinSharedWords
    }

    private func userSegmentQuestion(_ seg: Segment, _ now: TimeInterval) -> [CueSuggestion] {
        guard let q = pending, seg.end >= q.t else { return [] }
        if !q.inTurn {
            q.inTurn = true
            q.userTurns += 1
        }
        q.turnLastEnd = seg.end
        if !q.replyStarted {
            q.replyStarted = true
            let first = Self.sentences(seg.text).first ?? ""
            if first.hasSuffix("?") {
                q.counter = true
            } else if seg.text.unicodeScalars.first.map(Self.isDecimal) == true || x.directAnswerOpeners.contains(where: { Self.startsWith(seg.text, $0) }) {
                return clear()
            } else if q.openKind != nil && onTopic(q, first) {
                return clear()
            }
        }
        q.replyContent.formUnion(content(seg.words))
        if q.content.intersection(q.replyContent).count >= x.questionClearMinSharedWords { return clear() }
        q.replyWords += seg.words.count
        if !q.softFired && q.replyWords >= x.questionDecideWords {
            q.softFired = true
            return [CueSuggestion(type: .missedQuestion, t: now, onset: seg.end, source: .text, level: .soft)]
        }
        return []
    }

    private func clear() -> [CueSuggestion] {
        outcomes.questionCleared += 1
        pending = nil
        return []
    }

    private func endUserTurn(_ q: Pending, _ now: TimeInterval) -> [CueSuggestion] {
        q.inTurn = false
        var out: [CueSuggestion] = []
        if !q.softFired {
            q.softFired = true
            out.append(CueSuggestion(type: .missedQuestion, t: now, onset: q.turnLastEnd, source: .text, level: .soft))
        }
        if q.userTurns >= x.questionTimeoutUserTurns {
            outcomes.questionTimedOut += 1
            pending = nil
        }
        return out
    }

    // MARK: heat

    private func clauses(_ text: String) -> [Set<String>] {
        text.unicodeScalars.split(omittingEmptySubsequences: false) { ",;.?!".unicodeScalars.contains($0) }.compactMap { part in
            let words = Set(Self.tokens(String(String.UnicodeScalarView(part))).filter { !stop.contains($0) }.map(Self.stem))
            return words.count >= x.heatRepeatMinWords ? words : nil
        }
    }

    private func repeats(_ mine: [Set<String>], _ earlier: [Set<String>]) -> Bool {
        var pool = earlier
        for clause in mine {
            for other in pool {
                let shared = clause.intersection(other).count
                if shared >= x.heatRepeatMinWords && Double(shared) >= x.heatRepeatOverlap * Double(min(clause.count, other.count)) {
                    return true
                }
            }
            pool.append(clause)
        }
        return false
    }

    private func count(_ text: String, _ phrases: [String]) -> Int {
        phrases.reduce(0) { $0 + Self.phraseCount(text, $1) }
    }

    private func heat(_ seg: Segment, _ now: TimeInterval) -> [CueSuggestion] {
        if heatShownThisTurn || now + meetingOffsetS < x.heatSuppressFirstS { return [] }
        if count(commitText, x.heatApology) > 0 { return [] }
        let lastOther = segments.last { $0.speaker == .others && seg.end - $0.end < 30 }
        if count(commitText, x.heatPersonal) > 0 || lastOther.map({ count($0.text, x.heatPersonal) > 0 }) == true { return [] }
        let absolutes = count(seg.text, x.heatAbsolutes)
        let frustration = count(seg.text, x.heatFrustration)
        let profanity = count(seg.text, x.heatProfanity)
        var structural = 0
        let sents = Self.sentences(seg.text)
        if sents.contains(where: { s in x.heatContradictionOpeners.contains { Self.startsWith(s, $0) } }) { structural += 1 }
        let earlier = segments.filter { $0.id != seg.id && $0.speaker == .me && seg.end - $0.end <= x.heatRepeatWindowS }
            .flatMap { clauses($0.text) }
        if repeats(clauses(seg.text), earlier) { structural += 2 }
        let points = absolutes + frustration + 2 * profanity + structural
        if points > 0 { heatItems.append((seg.end, points, structural, frustration + profanity)) }
        let w = x.heatWindowS
        while let first = heatItems.first, now - first.t > 2 * w { heatItems.removeFirst() }
        let cur = heatItems.filter { now - $0.t < w }
        let prev = heatItems.filter { w <= now - $0.t && now - $0.t < 2 * w }
        let score = cur.reduce(0) { $0 + $1.points }, prevScore = prev.reduce(0) { $0 + $1.points }
        let spike = heatItems.filter { now - $0.t < x.heatSpikeWindowS }.reduce(0) { $0 + $1.strong } >= x.heatSpikeWords
        let fire = score >= x.heatFireScore || (score >= x.heatSustainScore && prevScore >= x.heatSustainScore) || spike
        guard fire else { return [] }
        let lexiconOnly = (cur + prev).reduce(0) { $0 + $1.structural } == 0
        if lexiconOnly && prosodyOn && !prosodyRise(since: now - 2 * w) { return [] }
        return [CueSuggestion(type: .aggressive, t: now, onset: seg.end, source: .text)]
    }

    private func prosodyRise(since: TimeInterval) -> Bool {
        while let first = prosody.first, first.t < since - 60 { prosody.removeFirst() }
        return prosody.contains { $0.t >= since && ($0.db >= riseDb || $0.pct >= risePct) }
    }

    // MARK: queries

    /// The other side asked a question ending shortly before (or just after) `t`.
    public func questionNear(_ t: TimeInterval) -> Bool {
        segments.contains { s in
            s.speaker == .others && t - questionLookback <= s.end && s.end <= t + 2 && Self.sentences(s.text).last?.hasSuffix("?") == true
        }
    }

    public func othersTextSince(_ t: TimeInterval) -> Bool {
        segments.contains { $0.speaker == .others && $0.end >= t }
    }

    /// In a group call, someone just handed the user the floor with a round-robin phrase.
    public func updateTurnBefore(_ t: TimeInterval) -> Bool {
        guard participants >= x.updateMinParticipants else { return false }
        let lb = x.updateHandoffLookbackS
        return segments.contains { s in
            s.speaker == .others && t - lb <= s.end && s.end <= t + 2 && x.updateHandoffPhrases.contains { Self.phraseCount(s.text, $0) > 0 }
        }
    }

    /// Did their speech that ended at `othersEnd` stop mid-thought (a conjunction or a comma-style pause as
    /// the last token)? nil until that transcript has arrived.
    public func trailingUnfinished(_ othersEnd: TimeInterval) -> Bool? {
        guard let seg = segments.last(where: { $0.speaker == .others && abs($0.end - othersEnd) <= 0.5 }) else { return nil }
        let last = seg.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if [",", ";", "-", "\u{2014}", "\u{2026}", "..."].contains(where: { last.hasSuffix($0) }) { return true }
        guard let word = Self.tokens(last).last else { return false }
        return x.cutInTrailingWords.contains(word)
    }

    public func howWhyBefore(_ t: TimeInterval) -> Bool {
        let lb = x.howWhyLookbackS
        for s in segments where s.speaker == .others && t - lb <= s.end && s.end <= t + 0.5 {
            for sent in Self.sentences(s.text) {
                if sent.hasSuffix("?"), let first = Self.tokens(sent).first, x.howWhyWords.contains(first) { return true }
            }
        }
        return false
    }

    public func readback(from t0: TimeInterval, now: TimeInterval) -> Bool {
        let segs = segments.filter { $0.end >= t0 - 1 }
        guard segs.count >= 2 else { return false }
        if segs.contains(where: { $0.estS >= readbackMaxTurn }) { return false }
        let numeric = segs.filter { $0.text.unicodeScalars.contains(where: Self.isDecimal) || !numbers.isDisjoint(with: $0.words) }.count
        let short = segs.filter { $0.words.count <= 8 || !confirm.isDisjoint(with: $0.words) }.count
        return numeric >= 2 && short * 2 >= segs.count
    }

    public func closingActive(now: TimeInterval) -> Bool {
        closingT.map { now - $0 <= x.closingQuietS } ?? false
    }

    public func clear() {
        commitText = ""
        segments.removeAll()
        pending = nil
        heatItems.removeAll()
    }

    // MARK: text helpers (Python `re` semantics on lower-cased text)

    static func normalize(_ text: String) -> String {
        text.lowercased().replacingOccurrences(of: "\u{2019}", with: "'")
    }

    private static func isWordScalar(_ u: Unicode.Scalar) -> Bool {
        u == "'" || ("a"..."z").contains(u) || ("0"..."9").contains(u)
    }

    /// `[a-z0-9']+` over the lower-cased text.
    static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var cur = String.UnicodeScalarView()
        for u in normalize(text).unicodeScalars {
            if isWordScalar(u) {
                cur.append(u)
            } else if !cur.isEmpty {
                out.append(String(cur))
                cur = String.UnicodeScalarView()
            }
        }
        if !cur.isEmpty { out.append(String(cur)) }
        return out
    }

    /// `[^.?!]+[.?!]*`, stripped, empty pieces dropped.
    static func sentences(_ text: String) -> [String] {
        var out: [String] = []
        var cur = String.UnicodeScalarView()
        var inTail = false
        for u in text.unicodeScalars {
            if u == "." || u == "?" || u == "!" {
                if cur.isEmpty { continue }
                cur.append(u)
                inTail = true
            } else {
                if inTail {
                    out.append(String(cur))
                    cur = String.UnicodeScalarView()
                    inTail = false
                }
                cur.append(u)
            }
        }
        if !cur.isEmpty { out.append(String(cur)) }
        return out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    /// Python `\d`: any Unicode decimal digit.
    static func isDecimal(_ u: Unicode.Scalar) -> Bool {
        u.properties.generalCategory == .decimalNumber
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

    private static func isDigits(_ w: String) -> Bool {
        !w.isEmpty && w.unicodeScalars.allSatisfy(isDecimal)
    }

    private static let phraseCache = PhraseCache()

    /// Non-overlapping occurrences of `phrase` not touching a word character on either side.
    static func phraseCount(_ text: String, _ phrase: String) -> Int {
        guard let re = phraseCache.regex(phrase, anchored: false) else { return 0 }
        return re.numberOfMatches(in: text, range: NSRange(text.startIndex..., in: text))
    }

    /// `phrase` at the start of `text`, not followed by a word character.
    static func startsWith(_ text: String, _ phrase: String) -> Bool {
        guard let re = phraseCache.regex(phrase, anchored: true) else { return false }
        return re.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }
}

private final class PhraseCache: @unchecked Sendable {
    private let lock = NSLock()
    private var cache: [String: NSRegularExpression] = [:]

    func regex(_ phrase: String, anchored: Bool) -> NSRegularExpression? {
        let key = (anchored ? "^" : "~") + phrase
        lock.lock()
        defer { lock.unlock() }
        if let re = cache[key] { return re }
        let body = NSRegularExpression.escapedPattern(for: phrase)
        let pattern = anchored ? "^" + body + "(?![a-z0-9'])" : "(?<![a-z0-9'])" + body + "(?![a-z0-9'])"
        let re = try? NSRegularExpression(pattern: pattern)
        cache[key] = re
        return re
    }
}
