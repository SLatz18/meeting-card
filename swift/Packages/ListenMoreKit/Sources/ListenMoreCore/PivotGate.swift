import Foundation

/// The self-pivot gate: right after the other side shares something personal, the user answers at
/// length about themselves and asks nothing back. It only counts candidates (shadow): nothing is
/// shown and nothing is judged. `GptCore` drives it, so it exists only with a key. All of these hold
/// for a candidate (`text.pivot_*`):
/// 1. Their turn has at least `pivot_share_min_words`, a share marker ("i just", "we finally") and a
///    share word (a feeling, a life event or a personal topic), no invitation to share (`pivot_invites`,
///    `question_open_invites`) and no question at its end. An invitation the user answered with less
///    than `pivot_reply_min_words` (a backchannel) still holds for their next turn.
/// 2. The user starts within `pivot_reply_max_start_s` of their last speech and says at least
///    `pivot_reply_min_words` about themselves: first-person words make up `pivot_first_person_share`
///    of the person words (`pivot_other_person` counts you, he, she, they and the like against it),
///    and either a sentence opens with a pivot opener or there are at least
///    `pivot_first_person_min_words` of them. A reply whose first sentence leads with sympathy
///    (`pivot_sympathy`: "sorry to hear", "i hope", "congratulations") is about them.
/// 3. No question back anywhere in the reply: no "?", no sentence or clause that opens like a
///    question ("how's", "did your", "are they"), no sentence ending in a tag ("…, right"), no
///    invitation.
/// 4. The turn is over: they start talking (while the user is quiet), or the user is quiet for
///    `pivot_turn_end_gap_s`. The last transcripts of both turns get `pivot_transcript_wait_s` past
///    the turn end to arrive; a turn still missing one is dropped.
/// 5. Nothing within `pivot_rearm_s` of the last candidate's turn end, at most `pivot_max_per_call`,
///    nothing while muted. Mute and Unmute drop the turn in progress; Pause restarts the engine.
///
/// Voice activity places the turns (times are VAD onsets and offsets, and a transcript's reference
/// time is the offset its commit was made at); transcripts arrive later and decide. Segment text stays
/// in RAM, is dropped by `clear()` and is never logged. Candidates carry times only.
final class PivotGate {
    struct Candidate: Equatable, Sendable {
        /// Their last speech before the reply ended.
        var themEnd: TimeInterval
        var replyStart: TimeInterval
        /// The user's last speech in the reply ended.
        var replyEnd: TimeInterval
        /// Their onset, or the end of the user's quiet gap.
        var turnEnd: TimeInterval
        /// The turn end, or the arrival of the last transcript it waited for.
        var decidedAt: TimeInterval
    }

    struct Counters: Equatable, Sendable {
        var candidates = 0
        /// Candidates held back by the re-arm or the per-call cap.
        var rateLimited = 0
        /// Turns after a personal share dropped because a transcript missed the wait.
        var lateTranscripts = 0
    }

    private struct Line {
        let end: TimeInterval
        /// Lower-cased.
        let text: String
    }

    private struct Reply {
        let start: TimeInterval
        let themEnd: TimeInterval
        let timely: Bool
    }

    private struct Ended {
        let reply: Reply
        let replyEnd: TimeInterval
        let at: TimeInterval
    }

    /// Lines older than this are dropped, like `TextRules`' segments.
    private static let keepS = 120.0
    private let x: ListenMoreConfig.Text
    private let invites: [String]
    private let leadIns: [String]
    private let tags: [[String]]
    private let firstPerson: Set<String>
    private let otherPerson: Set<String>
    private var them: [Line] = []
    private var me: [Line] = []
    private var meActive = false
    private var othersActive = false
    private var meOnset: TimeInterval?
    private var meLastEnd: TimeInterval?
    private var othersLastEnd: TimeInterval?
    /// Speech ending at or before this belongs to a turn already decided.
    private var boundary = -Double.infinity
    private var reply: Reply?
    private var ended: Ended?
    private var muted = false
    /// They invited the user to share, and the user hasn't answered at length yet (a backchannel such
    /// as "yeah" split their turn): their next turn is still an invitation.
    private var invitePending = false
    private var lastCandidateTurnEnd: TimeInterval?
    private(set) var counters = Counters()
    private(set) var candidates: [Candidate] = []

    init(config: ListenMoreConfig) {
        x = config.text
        invites = x.pivotInvites + x.questionOpenInvites
        leadIns = x.pivotLeadIns.filter { !$0.isEmpty }
        tags = x.pivotTagQuestions.map(TextRules.tokens).filter { !$0.isEmpty }
        firstPerson = Set(x.pivotFirstPerson)
        otherPerson = Set(x.pivotOtherPerson)
    }

    // MARK: inputs

    /// One frame of one stream's voice activity at audio time `now`.
    func onVad(_ speaker: Speaker, _ vad: VadState, now: TimeInterval) -> Candidate? {
        guard !muted else { return nil }
        switch speaker {
        case .me:
            if let on = vad.onset { meOnset = on }
            if let off = vad.offset { meLastEnd = off }
            meActive = vad.active
        case .others:
            if let off = vad.offset { othersLastEnd = off }
            othersActive = vad.active
            if let on = vad.onset, let r = reply {
                if meActive {
                    reply = nil
                    boundary = r.themEnd
                } else {
                    endTurn(r, at: on)
                }
            }
        }
        openReply()
        if let r = reply, !meActive, let end = meLastEnd, Elapsed.span(end - r.start) >= 0,
           Elapsed.span(now - end) >= x.pivotTurnEndGapS {
            endTurn(r, at: now)
        }
        return decide(now: now)
    }

    /// A transcript arrived at `now`; `refT` is the speech end its commit was made at.
    func onText(_ speaker: Speaker, text: String, refT: TimeInterval, now: TimeInterval) -> Candidate? {
        guard !muted else { return nil }
        let line = Line(end: refT, text: TextRules.normalize(text))
        switch speaker {
        case .me: me.append(line)
        case .others: them.append(line)
        }
        me.removeAll { Elapsed.span(now - $0.end) > Self.keepS }
        them.removeAll { Elapsed.span(now - $0.end) > Self.keepS }
        return decide(now: now)
    }

    /// The user's mic went off (true) or came back: the turn in progress and its text are dropped, and
    /// nothing is tracked while it's off.
    func setMuted(_ muted: Bool) {
        guard muted != self.muted else { return }
        self.muted = muted
        clear()
    }

    /// Drops all text and the turn in progress. The counters and the re-arm stay.
    func clear() {
        them.removeAll()
        me.removeAll()
        meActive = false
        othersActive = false
        meOnset = nil
        meLastEnd = nil
        othersLastEnd = nil
        boundary = -Double.infinity
        reply = nil
        ended = nil
        invitePending = false
    }

    // MARK: turns

    /// The user is talking and the other side isn't, after the other side spoke: the reply starts at
    /// the user's onset, or at their speech end if the user started over it.
    private func openReply() {
        guard reply == nil, ended == nil, meActive, !othersActive, let on = meOnset,
              let themEnd = othersLastEnd, Elapsed.span(themEnd - boundary) > 0 else { return }
        let start = max(on, themEnd)
        reply = Reply(start: start, themEnd: themEnd, timely: Elapsed.span(start - themEnd) <= x.pivotReplyMaxStartS)
    }

    private func endTurn(_ r: Reply, at t: TimeInterval) {
        reply = nil
        guard r.timely, let end = meLastEnd, Elapsed.span(end - r.start) >= 0 else {
            boundary = meLastEnd.map { max($0, r.themEnd) } ?? r.themEnd
            return
        }
        ended = Ended(reply: r, replyEnd: end, at: t)
    }

    private func finish(_ e: Ended) {
        ended = nil
        boundary = e.replyEnd
        me.removeAll { Elapsed.span($0.end - boundary) <= 0 }
        them.removeAll { Elapsed.span($0.end - boundary) <= 0 }
    }

    private func decide(now: TimeInterval) -> Candidate? {
        guard let e = ended else { return nil }
        let theirs = them.filter { Elapsed.span($0.end - boundary) > 0 && Elapsed.span($0.end - e.reply.themEnd) <= 0 }
        let haveTheirs = theirs.last.map { Elapsed.span($0.end - e.reply.themEnd) >= 0 } ?? false
        let invited = invitePending || theirs.contains(where: { has($0.text, invites) })
        if haveTheirs && !invited && !shared(theirs) {
            invitePending = false
            finish(e)
            return nil
        }
        let mine = me.filter { Elapsed.span($0.end - e.reply.start) >= 0 && Elapsed.span($0.end - e.replyEnd) <= 0 }
        let haveMine = mine.last.map { Elapsed.span($0.end - e.replyEnd) >= 0 } ?? false
        guard haveTheirs && haveMine else {
            if Elapsed.span(now - e.at) > x.pivotTranscriptWaitS {
                counters.lateTranscripts += 1
                if haveTheirs { invitePending = invited }
                finish(e)
            }
            return nil
        }
        invitePending = invited && mine.reduce(0, { $0 + TextRules.tokens($1.text).count }) < x.pivotReplyMinWords
        finish(e)
        guard !invited, shared(theirs), pivots(mine) else { return nil }
        let rearmed = lastCandidateTurnEnd.map { Elapsed.span(e.at - $0) >= x.pivotRearmS } ?? true
        guard rearmed && counters.candidates < x.pivotMaxPerCall else {
            counters.rateLimited += 1
            return nil
        }
        let c = Candidate(themEnd: e.reply.themEnd, replyStart: e.reply.start, replyEnd: e.replyEnd, turnEnd: e.at, decidedAt: now)
        counters.candidates += 1
        lastCandidateTurnEnd = e.at
        candidates.append(c)
        return c
    }

    // MARK: text rules

    private func shared(_ lines: [Line]) -> Bool {
        guard lines.reduce(0, { $0 + TextRules.tokens($1.text).count }) >= x.pivotShareMinWords,
              lines.contains(where: { has($0.text, x.pivotShareMarkers) }),
              lines.contains(where: { has($0.text, x.pivotShareWords) }) else { return false }
        let last = lines.last.map(\.text) ?? ""
        let lastSentence = TextRules.sentences(last).last ?? ""
        return !asks(lastSentence) && !endsWithTag(lastSentence) && !(pieces(last).last.map(asks) ?? false)
    }

    private func pivots(_ lines: [Line]) -> Bool {
        let words = lines.flatMap { TextRules.tokens($0.text) }
        guard words.count >= x.pivotReplyMinWords,
              !lines.contains(where: { line in
                  has(line.text, invites) || pieces(line.text).contains(where: asks)
                      || TextRules.sentences(line.text).contains(where: endsWithTag)
              }),
              !has(lines.first.flatMap { TextRules.sentences($0.text).first } ?? "", x.pivotSympathy) else { return false }
        let first = words.filter(firstPerson.contains).count, other = words.filter(otherPerson.contains).count
        let aboutMe = first > 0 && Double(first) >= x.pivotFirstPersonShare * Double(first + other)
        if aboutMe && lines.contains(where: opensWithPivot) { return true }
        return aboutMe && first >= x.pivotFirstPersonMinWords
    }

    /// A sentence of the line starts with a pivot opener, after any lead-in words ("oh nice, that
    /// reminds me"). An opener inside a sentence ("she told me too") doesn't count.
    private func opensWithPivot(_ line: Line) -> Bool {
        TextRules.sentences(line.text).contains { sentence in
            let rest = strippingLeadIns(sentence)
            return x.pivotOpeners.contains { TextRules.startsWith(rest, $0) }
        }
    }

    /// Each sentence and each clause in it. Every transcript starts a sentence, so a question that
    /// follows a pause still starts one when the transcriber joined it without punctuation.
    private func pieces(_ text: String) -> [String] {
        TextRules.sentences(text).flatMap { sentence in
            sentence.split(whereSeparator: { ",;\u{2014}".contains($0) })
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        }
    }

    private func asks(_ piece: String) -> Bool {
        if piece.contains("?") { return true }
        let rest = strippingLeadIns(piece)
        return x.pivotQuestionOpeners.contains { TextRules.startsWith(rest, $0) }
    }

    /// "…, right" or "…, isn't it": a statement turned into a question at its end.
    private func endsWithTag(_ sentence: String) -> Bool {
        let words = TextRules.tokens(sentence)
        return tags.contains { words.count >= $0.count && Array(words.suffix($0.count)) == $0 }
    }

    private func strippingLeadIns(_ piece: String) -> String {
        var rest = piece
        while let lead = leadIns.first(where: { TextRules.startsWith(rest, $0) }) {
            rest = String(rest.dropFirst(lead.count)).trimmingCharacters(in: CharacterSet(charactersIn: " ,"))
        }
        return rest
    }

    private func has(_ text: String, _ phrases: [String]) -> Bool {
        phrases.contains { TextRules.phraseCount(text, $0) > 0 }
    }
}
