import Foundation
import ListenMoreCore

/// Word error rate: (substitutions + deletions + insertions) / reference words, on normalized tokens.
public struct WordErrors: Sendable, Codable, Equatable {
    public var substitutions = 0
    public var deletions = 0
    public var insertions = 0
    public var referenceWords = 0

    public init(substitutions: Int = 0, deletions: Int = 0, insertions: Int = 0, referenceWords: Int = 0) {
        self.substitutions = substitutions
        self.deletions = deletions
        self.insertions = insertions
        self.referenceWords = referenceWords
    }

    public var errors: Int { substitutions + deletions + insertions }
    /// nil when there is nothing to compare (no reference and no hypothesis words).
    public var rate: Double? {
        if referenceWords == 0 { return errors == 0 ? nil : 1 }
        return Double(errors) / Double(referenceWords)
    }

    public static func + (a: WordErrors, b: WordErrors) -> WordErrors {
        WordErrors(substitutions: a.substitutions + b.substitutions, deletions: a.deletions + b.deletions,
                   insertions: a.insertions + b.insertions, referenceWords: a.referenceWords + b.referenceWords)
    }

    public static func compute(reference: [String], hypothesis: [String]) -> WordErrors {
        let n = reference.count, m = hypothesis.count
        // (cost, subs, dels, ins) per cell; ties prefer substitutions, then deletions.
        var prev = (0...m).map { (cost: $0, s: 0, d: 0, i: $0) }
        for r in 1...max(n, 1) where n > 0 {
            var cur = [(cost: Int, s: Int, d: Int, i: Int)](repeating: (0, 0, 0, 0), count: m + 1)
            cur[0] = (r, 0, r, 0)
            for h in stride(from: 1, through: m, by: 1) {
                let same = reference[r - 1] == hypothesis[h - 1]
                let diag = prev[h - 1]
                let sub = (cost: diag.cost + (same ? 0 : 1), s: diag.s + (same ? 0 : 1), d: diag.d, i: diag.i)
                let del = (cost: prev[h].cost + 1, s: prev[h].s, d: prev[h].d + 1, i: prev[h].i)
                let ins = (cost: cur[h - 1].cost + 1, s: cur[h - 1].s, d: cur[h - 1].d, i: cur[h - 1].i + 1)
                var best = sub
                if del.cost < best.cost { best = del }
                if ins.cost < best.cost { best = ins }
                cur[h] = best
            }
            prev = cur
        }
        let last = prev[m]
        return WordErrors(substitutions: last.s, deletions: last.d, insertions: last.i, referenceWords: n)
    }
}

public struct StreamTranscription: Sendable, Codable {
    public var errors: WordErrors
    /// Speech end to final caption, per line, in seconds.
    public var latencies: [Double]
    public var linesExpected: Int
    public var linesCaptioned: Int

    public var medianLatency: Double? { Self.percentile(latencies, 0.5) }
    public var maxLatency: Double? { latencies.max() }

    static func percentile(_ xs: [Double], _ p: Double) -> Double? {
        let s = xs.sorted()
        guard !s.isEmpty else { return nil }
        return s[min(s.count - 1, Int((Double(s.count - 1) * p).rounded()))]
    }
}

public enum MultiThem: String, Sendable, Codable {
    /// Each remote voice got its own label.
    case supported
    /// Every remote voice is labelled Them: the engine attributes by stream (no diarization).
    case mergedAsThem = "merged as Them"
    /// A remote voice's line was labelled You.
    case wrong
    case notExercised = "not exercised"
}

public struct SpeakerScore: Sendable, Codable {
    public var correct: Int
    public var total: Int
    public var unmatched: Int
    /// Segments whose transcript never became a caption (the GPT layer drops You text while muted and
    /// everything after the cost cap): only their stream could be checked.
    public var uncaptioned = 0
    /// Each segment attributed wrongly: when, which socket, its first words and the line it holds.
    public var mismatches: [String] = []
    public var multiThem: MultiThem
    public var accuracy: Double? { total == 0 ? nil : Double(correct) / Double(total) }
}

public enum Scoring {
    /// A line reaches transcription when its audio was captured with the GPT layer on: not paused, not
    /// spoken by You while muted, a key present, and, if the layer stopped (cost cap), committed
    /// before it stopped.
    public static func transcribedLines(_ r: RunRecord, keyless: Bool) -> [PlacedLine] {
        guard !keyless else { return [] }
        let mutes = r.appliedWindows(.mute, .unmute)
        let pauses = r.appliedWindows(.pause, .resume)
        let stop = r.sessionStops.first ?? .infinity
        let hang = Double(r.config.vad.hangoverMs) / 1000
        return r.timeline.lines.filter { p in
            let overlaps = { (w: ClosedRange<Double>) in p.start < w.upperBound && p.end > w.lowerBound }
            if pauses.contains(where: overlaps) { return false }
            if p.line.voice == .you && mutes.contains(where: overlaps) { return false }
            if p.end + hang >= stop { return false }
            if let g = r.gptStop?.t {
                return r.sockets.commits.contains { $0.stream == p.line.voice.stream && $0.t >= p.end - 0.1 && $0.t <= g }
            }
            return true
        }
    }

    /// The caption carries most of the line's words, wherever and whenever it appeared.
    static func carries(_ caption: CaptionRecord, _ line: Line) -> Bool {
        let ref = Set(ScriptText.tokens(line.text))
        guard !ref.isEmpty else { return false }
        return Double(ref.intersection(ScriptText.tokens(caption.text)).count) / Double(ref.count) >= 0.6
    }

    /// The script line a transcribed segment holds: among lines whose span contains the segment's
    /// speech end (its commit less the VAD hangover, with 0.3 s / 0.6 s of VAD slack), the one holding
    /// the largest share of the segment's words; ties go to the line ending nearest that point. nil
    /// under half. Uses audio timing, not the stream, so audio on the wrong transcriber shows as wrong.
    public static func line(for seg: TranscribedSegment, lines: [PlacedLine], hangover: Double) -> PlacedLine? {
        let words = Set(ScriptText.tokens(seg.text))
        guard !words.isEmpty else { return nil }
        let end = seg.committedAt - hangover
        var best: (line: PlacedLine, score: Double)?
        for p in lines where p.start - 0.3 <= end && end <= p.end + 0.6 {
            let score = Double(Set(ScriptText.tokens(p.line.text)).intersection(words).count) / Double(words.count)
            if let b = best, score < b.score || (score == b.score && abs(end - p.end) >= abs(end - b.line.end)) { continue }
            best = (p, score)
        }
        guard let b = best, b.score >= 0.5 else { return nil }
        return b.line
    }

    static func hangover(_ r: RunRecord) -> Double { Double(r.config.vad.hangoverMs) / 1000 }

    /// Lines whose audio could reach a transcriber at all: not spoken wholly inside a Pause, and for
    /// You not wholly inside a Mute. A segment can only hold one of these, whatever its socket.
    static func reachableLines(_ r: RunRecord) -> [PlacedLine] {
        let mutes = r.appliedWindows(.mute, .unmute)
        let pauses = r.appliedWindows(.pause, .resume)
        let inside = { (p: PlacedLine, w: ClosedRange<Double>) in p.start >= w.lowerBound && p.end <= w.upperBound }
        return r.timeline.lines.filter { p in
            !pauses.contains { inside(p, $0) } && !(p.line.voice == .you && mutes.contains { inside(p, $0) })
        }
    }

    public static func transcription(_ r: RunRecord, keyless: Bool) -> [Speaker: StreamTranscription] {
        let expected = transcribedLines(r, keyless: keyless)
        let finals = r.captions.filter { $0.isFinal && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        let segments = r.sockets.segments.filter { !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        let hang = hangover(r)
        var out: [Speaker: StreamTranscription] = [:]
        for speaker in Speaker.allCases {
            let refLines = expected.filter { $0.line.voice.speaker == speaker }
            let hyp = finals.filter { $0.speaker == speaker }
            let errors = WordErrors.compute(reference: refLines.flatMap { ScriptText.tokens($0.line.text) },
                                            hypothesis: hyp.flatMap { ScriptText.tokens($0.text) })
            let mine = segments.filter { $0.stream == (speaker == .me ? .mic : .call) }
            let latencies = mine.map { $0.transcribedAt - ($0.committedAt - hang) }
            let captioned = Set(mine.compactMap { line(for: $0, lines: refLines, hangover: hang)?.line.id })
            out[speaker] = StreamTranscription(errors: errors, latencies: latencies,
                                               linesExpected: refLines.count, linesCaptioned: captioned.count)
        }
        return out
    }

    /// The label the caption feed should show for `speaker` at scenario time `t`: You, or Them until a
    /// speaker tag was applied (then the tag).
    static func expectedLabel(_ speaker: Speaker, at t: Double, in r: RunRecord) -> String {
        guard speaker == .others else { return SpeakerLabels.defaultLabels[.me] ?? "You" }
        let renames = Array(zip(r.applied.filter { $0.kind == .renameThem }, r.scenario.controls.filter { $0.kind == .renameThem }))
        let tag = renames.last { $0.0.t <= t }?.1.tag
        return tag ?? SpeakerLabels.defaultLabels[.others] ?? "Them"
    }

    /// A segment is attributed correctly when it reached the right stream's transcriber, the caption
    /// that carried its text has the right speaker, and the caption feed labelled that line right.
    public static func speakers(_ r: RunRecord) -> SpeakerScore {
        let hang = hangover(r)
        var correct = 0, total = 0, unmatched = 0, uncaptioned = 0
        var themBSpeakers: [Speaker] = []
        let finals = r.captions.filter { $0.isFinal && !$0.text.trimmingCharacters(in: .whitespaces).isEmpty }
        var used = Set<Int>()
        func norm(_ s: String) -> String { ScriptText.tokens(s).joined(separator: " ") }
        var mismatches: [String] = []
        let reachable = reachableLines(r)
        for seg in r.sockets.segments where !seg.text.trimmingCharacters(in: .whitespaces).isEmpty {
            guard let p = line(for: seg, lines: reachable, hangover: hang) else {
                unmatched += 1
                continue
            }
            total += 1
            let expected = p.line.voice.speaker
            let stream: Speaker = seg.stream == .mic ? .me : .others
            var ok = stream == expected
            let text = norm(seg.text)
            if let i = finals.indices.first(where: { !used.contains($0) && norm(finals[$0].text) == text
                && finals[$0].t >= seg.transcribedAt - 0.05 && finals[$0].t <= seg.transcribedAt + 3 }) {
                used.insert(i)
                let c = finals[i]
                ok = ok && c.speaker == expected
                if let view = r.captionViews.first(where: { abs($0.t - c.t) < 1e-9 }),
                   let row = view.rows.last(where: { norm($0.text).contains(text) }) {
                    ok = ok && row.label == expectedLabel(expected, at: c.t, in: r)
                }
                if p.line.voice == .themB { themBSpeakers.append(c.speaker) }
            } else {
                uncaptioned += 1
                if p.line.voice == .themB { themBSpeakers.append(stream) }
            }
            if ok {
                correct += 1
            } else {
                let words = ScriptText.tokens(seg.text).prefix(6).joined(separator: " ")
                mismatches.append(String(format: "%@ segment ending %.1f s (\"%@…\") holds %@ (%@)", seg.stream == .mic ? "mic" : "call",
                                         seg.committedAt - hang, words, p.line.id, p.line.voice.rawValue))
            }
        }
        let multi: MultiThem
        if !r.timeline.lines.contains(where: { $0.line.voice == .themB }) || themBSpeakers.isEmpty {
            multi = .notExercised
        } else if themBSpeakers.contains(.me) {
            multi = .wrong
        } else {
            // Speaker has two cases, so both remote voices share Them's label.
            multi = .mergedAsThem
        }
        return SpeakerScore(correct: correct, total: total, unmatched: unmatched, uncaptioned: uncaptioned, mismatches: mismatches,
                            multiThem: multi)
    }
}
