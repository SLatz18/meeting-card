import Foundation

/// Live transcription text for a host's captions and saved transcript, from the GPT layer's
/// realtime sessions. Content: RAM only, never logged.
public enum CaptionEvent: Equatable, Sendable {
    /// More text of the turn `item` that is still being transcribed.
    case partial(Speaker, item: String, text: String)
    /// The final text of this item, or the speaker's oldest pending turn on the legacy path.
    case final(Speaker, text: String, item: String? = nil)
    case speakerEmbedding(Speaker, SpeakerEmbedding)
}

/// Display labels for the two streams: "You" (the mic) and "Them" (call audio), or the host's own
/// wording for them. The user can tag either for the current call; tags are dropped with `reset()`
/// at call end, the host's defaults stay.
public struct SpeakerLabels: Equatable, Sendable {
    public static let defaultLabels: [Speaker: String] = [.me: "You", .others: "Them"]
    public static let maxLength = 32

    public let defaults: [Speaker: String]
    private var tags: [Speaker: String] = [:]
    private var profileNames: [Speaker: String] = [:]

    public init(defaults: [Speaker: String] = SpeakerLabels.defaultLabels) {
        self.defaults = defaults
    }

    public func label(_ speaker: Speaker) -> String {
        tags[speaker] ?? profileNames[speaker] ?? defaultLabel(speaker)
    }

    public func defaultLabel(_ speaker: Speaker) -> String {
        if case .other(let number) = speaker { return "Speaker \(number)" }
        return defaults[speaker] ?? Self.defaultLabels[speaker] ?? speaker.rawValue
    }

    mutating func setProfileNames(_ names: [Speaker: String]) {
        profileNames = names
    }

    public var isTagged: Bool { !tags.isEmpty }

    /// A blank or nil tag restores the default. Whitespace runs collapse to one space, control
    /// characters are dropped, and the tag is cut to `maxLength` characters.
    public mutating func rename(_ speaker: Speaker, to tag: String?) {
        let clean = Self.clean(tag ?? "")
        let base: String?
        if case .other = speaker { base = defaultLabel(speaker) } else { base = defaults[speaker] }
        tags[speaker] = clean.isEmpty || clean == base ? nil : clean
    }

    public mutating func reset() {
        tags.removeAll()
        profileNames.removeAll()
    }

    static func clean(_ s: String) -> String {
        let kept = s.unicodeScalars.map { CharacterSet.controlCharacters.contains($0) ? " " : String($0) }.joined()
        let words = kept.split(whereSeparator: \.isWhitespace)
        return String(words.joined(separator: " ").prefix(maxLength))
    }
}

/// One caption line: one speaker's recent words.
public struct CaptionLine: Equatable, Sendable {
    public var speaker: Speaker
    /// Final text so far.
    public var settled: String
    /// Turns still being transcribed, oldest first, with their partial text.
    public var pending: [(item: String, text: String)]
    /// Seconds (host clock) of the last change, for merging.
    public var updatedAt: TimeInterval

    public var text: String {
        ([settled] + pending.map(\.text)).map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }.joined(separator: " ")
    }

    public var isFinal: Bool { pending.isEmpty }

    public static func == (a: CaptionLine, b: CaptionLine) -> Bool {
        a.speaker == b.speaker && a.settled == b.settled && a.updatedAt == b.updatedAt
            && a.pending.map(\.item) == b.pending.map(\.item) && a.pending.map(\.text) == b.pending.map(\.text)
    }
}

/// The caption feed's lines. Bounded: at most `maxLines` lines are kept (oldest dropped) and a line
/// stops taking merges once it reaches `maxLineChars`. Consecutive turns by the same speaker within
/// `mergeGapS` share a line. RAM only.
public struct CaptionBuffer: Equatable, Sendable {
    public let maxLines: Int
    public let maxLineChars: Int
    public let mergeGapS: Double
    public private(set) var lines: [CaptionLine] = []

    public init(maxLines: Int = 3, maxLineChars: Int = 160, mergeGapS: Double = 4) {
        self.maxLines = max(1, maxLines)
        self.maxLineChars = maxLineChars
        self.mergeGapS = mergeGapS
    }

    public mutating func apply(_ event: CaptionEvent, at t: TimeInterval) {
        switch event {
        case let .partial(speaker, item, text):
            if let i = lines.lastIndex(where: { $0.speaker == speaker && $0.pending.contains { $0.item == item } }),
               let j = lines[i].pending.firstIndex(where: { $0.item == item }) {
                lines[i].pending[j].text += text
                lines[i].updatedAt = t
            } else {
                let i = lineToJoin(speaker, at: t)
                lines[i].pending.append((item, text))
                lines[i].updatedAt = t
            }
        case let .final(speaker, text, item):
            let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let i = lines.firstIndex(where: { line in
                line.speaker == speaker && line.pending.contains { item == nil || $0.item == item }
            }), let j = lines[i].pending.firstIndex(where: { item == nil || $0.item == item }) {
                lines[i].pending.remove(at: j)
                if !said.isEmpty { lines[i].settled = Self.join(lines[i].settled, said) }
                lines[i].updatedAt = t
                if lines[i].text.isEmpty { lines.remove(at: i) }
            } else if !said.isEmpty {
                let i = lineToJoin(speaker, at: t)
                lines[i].settled = Self.join(lines[i].settled, said)
                lines[i].updatedAt = t
            }
        case .speakerEmbedding:
            break
        }
        if lines.count > maxLines { lines.removeFirst(lines.count - maxLines) }
    }

    public mutating func clear() {
        lines.removeAll()
    }

    /// The last line when it is the same speaker's, recent and short enough; else a new line.
    private mutating func lineToJoin(_ speaker: Speaker, at t: TimeInterval) -> Int {
        if let last = lines.last, last.speaker == speaker, t - last.updatedAt <= mergeGapS, last.text.count < maxLineChars {
            return lines.count - 1
        }
        lines.append(CaptionLine(speaker: speaker, settled: "", pending: [], updatedAt: t))
        return lines.count - 1
    }

    static func join(_ a: String, _ b: String) -> String {
        a.isEmpty ? b : a + " " + b
    }
}
