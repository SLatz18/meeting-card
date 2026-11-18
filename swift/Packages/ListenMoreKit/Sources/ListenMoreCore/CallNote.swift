import Foundation

/// The saved note's user-facing words. Every default is a placeholder pending copy review; a host
/// can pass its own.
public struct NoteWording: Equatable, Sendable {
    public var summaryHeading = "Summary"
    public var summaryPlaceholder = "_Summary placeholder: add yours after the call._"
    public var cuesHeading = "Coaching cues"
    public var noCues = "_No coaching cues this call._"
    public var transcriptHeading = "Transcript"
    public var noLines = "_Nothing was transcribed._"
    /// The title (and file name part) when the call has none.
    public var untitled = "Call"
    public var cueNames: [String: String] = [
        CueType.interrupt.rawValue: "Interruption",
        CueType.talkOver.rawValue: "Talking over",
        CueType.aggressive.rawValue: "Sharp tone",
        CueType.notListening.rawValue: "Not listening",
        CueType.missedQuestion.rawValue: "Missed question",
        CueType.monologue.rawValue: "Long monologue",
        CueType.talkShare.rawValue: "Talk share",
    ]
    public var gaps: [GapKind: String] = [
        .youMuted: "Coach mic off: no You text",
        .paused: "Coach paused: nothing transcribed",
        .appMuted: "Muted in the call app: nothing transcribed",
        .transcriberStopped: "Transcription stopped",
        .transcriberRetrying: "Transcription reconnecting",
        .callAudioReconnecting: "Call audio reconnecting",
        .appQuit: "The app quit during the call; this transcript was recovered and ends here",
    ]
    /// Gap details by `TranscriptGap.detail`.
    public var gapDetails: [String: String] = [
        GptStopReason.budgetCap.rawValue: "cost cap reached",
        GptStopReason.error.rawValue: "transcriber error",
    ]

    public init() {}

    func cueName(_ type: String) -> String { cueNames[type] ?? type }

    func gapText(_ g: TranscriptGap) -> String {
        let base = gaps[g.kind] ?? g.kind.rawValue
        guard let d = g.detail else { return base }
        return "\(base) (\(gapDetails[d] ?? d))"
    }
}

/// Where a note is in its life, as its `transcript-status` property shows.
public enum NoteStatus: String, Sendable {
    case inProgress = "in-progress"
    case complete
    case recovered
}

// MARK: file names

/// The note's file name from the user's pattern, made safe for Obsidian and every common file system.
public enum NoteFileName {
    /// `{date}` 2026-01-31, `{time}` 0905, `{title}` the call's title (or `NoteWording.untitled`),
    /// `{app}` the call app.
    public static let defaultPattern = "{date} {time} {title}"
    /// Characters, before the extension and any " (n)" suffix.
    public static let maxLength = 120
    public static let fileExtension = "md"
    /// Not allowed in file names on macOS, Windows or Android, or meaningful in Obsidian links.
    static let unsafe: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|", "#", "^", "[", "]", "%", "\u{0}"]
    static let reserved: Set<String> = Set(["CON", "PRN", "AUX", "NUL"] + (1...9).flatMap { ["COM\($0)", "LPT\($0)"] })

    public static func base(pattern: String, start: Date, info: CallInfo, wording: NoteWording = NoteWording(),
                            timeZone: TimeZone = .current) -> String {
        let title = sanitize(info.title ?? "")
        let values = ["{date}": TranscriptFormat.stamp(start, "yyyy-MM-dd", timeZone),
                      "{time}": TranscriptFormat.stamp(start, "HHmm", timeZone),
                      "{title}": title.isEmpty ? wording.untitled : title,
                      "{app}": sanitize(info.app ?? "")]
        func fill(_ p: String) -> String {
            values.reduce(p) { $0.replacingOccurrences(of: $1.key, with: $1.value) }
        }
        let name = sanitize(fill(pattern))
        if !name.isEmpty { return name }
        return sanitize(fill(defaultPattern))
    }

    /// Unsafe characters and control characters become spaces, whitespace runs collapse, leading and
    /// trailing dots and spaces go (a leading dot hides a file), and the result is cut to `maxLength`
    /// characters. A reserved Windows device name gets a trailing underscore.
    public static func sanitize(_ s: String) -> String {
        var out = ""
        for ch in s.precomposedStringWithCanonicalMapping {
            let control = ch.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) }
            out.append(control || unsafe.contains(ch) ? " " : ch)
        }
        out = out.split(whereSeparator: \.isWhitespace).joined(separator: " ")
        out = trimDotsAndSpaces(out)
        if out.count > maxLength { out = trimDotsAndSpaces(String(out.prefix(maxLength))) }
        let stem = out.split(separator: ".", maxSplits: 1).first.map { String($0).uppercased() } ?? ""
        if reserved.contains(stem) { out += "_" }
        return out
    }

    static func trimDotsAndSpaces(_ s: String) -> String {
        s.trimmingCharacters(in: CharacterSet(charactersIn: ". ").union(.whitespaces))
    }

    /// `<base>.md` in `folder`, or `<base> (2).md`, `(3)`… when the name is taken. Names compare
    /// case-insensitively (APFS's default), against the folder's files and `reserved`.
    public static func unique(base: String, in folder: URL, store: TranscriptStore, reserved: Set<String> = []) -> URL {
        let taken = Set(store.contents(of: folder).map { $0.lastPathComponent.lowercased() }).union(reserved.map { $0.lowercased() })
        var n = 1
        while true {
            let name = n == 1 ? "\(base).\(fileExtension)" : "\(base) (\(n)).\(fileExtension)"
            let url = folder.appendingPathComponent(name)
            if !taken.contains(name.lowercased()) && !store.exists(url) { return url }
            n += 1
        }
    }
}

// MARK: vault

public enum ObsidianVault {
    /// The vault that holds `folder`: the folder itself or its nearest parent with an `.obsidian` folder.
    public static func root(containing folder: URL, store: TranscriptStore) -> URL? {
        var path = folder.standardizedFileURL.path
        while true {
            let dir = URL(fileURLWithPath: path, isDirectory: true)
            if store.isDirectory(dir.appendingPathComponent(".obsidian", isDirectory: true)) { return dir }
            let parent = (path as NSString).deletingLastPathComponent
            if parent == path || parent.isEmpty { return nil }
            path = parent
        }
    }

    /// `url`'s path under `root`, without the `.md` extension, for a wikilink; nil if it isn't under `root`.
    public static func linkPath(of url: URL, under root: URL) -> String? {
        let base = root.standardizedFileURL.path
        let full = url.standardizedFileURL.path
        let prefix = base.hasSuffix("/") ? base : base + "/"
        guard full.hasPrefix(prefix) else { return nil }
        let rel = String(full.dropFirst(prefix.count))
        return rel.hasSuffix(".\(NoteFileName.fileExtension)") ? String(rel.dropLast(NoteFileName.fileExtension.count + 1)) : rel
    }
}

// MARK: the note

/// The call's Obsidian note: YAML properties, then the summary placeholder, the coaching cues (each
/// linked to the transcript line it fell in, through the line's block ID), then the transcript with
/// its gaps. Plain Markdown: any editor can read it and Obsidian needs no plugin.
public enum CallNote {
    public static let callProperty = "meetingcard-call"
    public static let statusProperty = "transcript-status"
    public static let defaultTag = "meeting/transcript"

    public static func render(_ r: CallRecord, labels: SpeakerLabels, status: NoteStatus,
                              wording: NoteWording = NoteWording(), timeZone: TimeZone = .current) -> String {
        let lines = r.lines.enumerated().sorted { a, b in
            a.element.offset == b.element.offset ? a.offset < b.offset : a.element.offset < b.element.offset
        }
        var out = frontmatter(r, labels: labels, status: status, timeZone: timeZone)
        out += "\n## \(wording.summaryHeading)\n\n\(wording.summaryPlaceholder)\n"
        out += "\n## \(wording.cuesHeading)\n\n"
        if r.cues.isEmpty { out += "\(wording.noCues)\n" }
        for cue in r.cues.sorted(by: { $0.offset < $1.offset }) {
            let stamp = TranscriptFormat.timestamp(cue.offset)
            if let line = lines.last(where: { $0.element.offset <= cue.offset }) ?? lines.first {
                out += "- [[#^\(blockId(line.offset))|\(stamp)]] \(wording.cueName(cue.type))\n"
            } else {
                out += "- \(stamp) \(wording.cueName(cue.type))\n"
            }
        }
        out += "\n## \(wording.transcriptHeading)\n"
        enum Item { case line(Int, TranscriptLine), gap(TranscriptGap) }
        // At the same second a gap comes before a line; otherwise each keeps its order.
        var items: [(TimeInterval, Int, Item)] = r.gaps.enumerated().map { ($0.element.start, $0.offset, .gap($0.element)) }
        items += lines.enumerated().map { ($0.element.element.offset, r.gaps.count + $0.offset, .line($0.element.offset, $0.element.element)) }
        items.sort { $0.0 == $1.0 ? $0.1 < $1.1 : $0.0 < $1.0 }
        if items.isEmpty { out += "\n\(wording.noLines)\n" }
        for (_, _, item) in items {
            switch item {
            case let .line(i, l):
                out += "\n**[\(TranscriptFormat.timestamp(l.offset))] \(escape(label(l, labels))):** \(escape(TranscriptFormat.oneLine(l.text))) ^\(blockId(i))\n"
            case let .gap(g):
                let range = TranscriptFormat.timestamp(g.start) + "–" + (g.end.map(TranscriptFormat.timestamp) ?? "")
                out += "\n*[\(range)] \(wording.gapText(g)).*\n"
            }
        }
        return out
    }

    /// The line's block ID, by arrival order (stable while the note is rewritten).
    public static func blockId(_ index: Int) -> String { "l\(index + 1)" }

    static func label(_ l: TranscriptLine, _ labels: SpeakerLabels) -> String {
        let base = labels.label(l.speaker)
        guard l.speaker == .others, let n = l.themIndex else { return base }
        return "\(base) \(n)"
    }

    static func frontmatter(_ r: CallRecord, labels: SpeakerLabels, status: NoteStatus, timeZone: TimeZone) -> String {
        var speakers: [String] = []
        for l in r.lines {
            let s = label(l, labels)
            if !speakers.contains(s) { speakers.append(s) }
        }
        if speakers.isEmpty { speakers = [labels.label(.me), labels.label(.others)] }
        var out = "---\n"
        out += "date: \(TranscriptFormat.stamp(r.start, "yyyy-MM-dd", timeZone))\n"
        out += "start: \(TranscriptFormat.stamp(r.start, "yyyy-MM-dd'T'HH:mm:ss", timeZone))\n"
        if let end = r.end {
            out += "end: \(TranscriptFormat.stamp(r.start.addingTimeInterval(end), "yyyy-MM-dd'T'HH:mm:ss", timeZone))\n"
            out += "duration: \(yaml(TranscriptFormat.timestamp(end)))\n"
        }
        if let app = r.info.app, !app.isEmpty { out += "meeting-app: \(yaml(app))\n" }
        if let title = r.info.title, !title.isEmpty { out += "title: \(yaml(title))\n" }
        if !r.info.participants.isEmpty { out += list("participants", r.info.participants) }
        out += list("speakers", speakers)
        out += list("tags", r.tags.compactMap(tag))
        if let model = r.info.transcriber, !model.isEmpty { out += "transcriber: \(yaml(model))\n" }
        out += "coach-cues: \(r.cues.count)\n"
        out += "\(statusProperty): \(status.rawValue)\n"
        out += "\(callProperty): \(yaml(r.callId))\n"
        out += "---\n"
        return out
    }

    static func list(_ key: String, _ items: [String]) -> String {
        guard !items.isEmpty else { return "\(key): []\n" }
        return "\(key):\n" + items.map { "  - \(yaml($0))\n" }.joined()
    }

    /// A double-quoted YAML scalar: safe for any text (quotes, colons, leading dashes, newlines).
    static func yaml(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if CharacterSet.controlCharacters.contains(u) {
                    out += String(format: "\\u%04X", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        return out + "\""
    }

    /// An Obsidian tag: no leading #, spaces become dashes, only letters, digits, _, - and /; not all
    /// digits. nil when nothing is left.
    public static func tag(_ raw: String) -> String? {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("#") { s.removeFirst() }
        let kept = s.unicodeScalars.compactMap { u -> String? in
            if CharacterSet.whitespaces.contains(u) { return "-" }
            if CharacterSet.alphanumerics.contains(u) || u == "_" || u == "-" || u == "/" { return String(u) }
            return nil
        }.joined()
        let t = kept.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !t.isEmpty, t.contains(where: { !$0.isNumber }) else { return nil }
        return t
    }

    /// Tags from a comma- or space-separated setting.
    public static func tags(fromSetting s: String) -> [String] {
        var out: [String] = []
        for part in s.split(whereSeparator: { $0 == "," || $0.isWhitespace }) {
            if let t = tag(String(part)), !out.contains(t) { out.append(t) }
        }
        return out
    }

    /// Transcript text never becomes Obsidian syntax: no tags, links, embeds, comments, block IDs,
    /// math, highlights, HTML or emphasis.
    static func escape(_ s: String) -> String {
        let special: Set<Character> = ["\\", "`", "*", "_", "[", "]", "#", "^", "%", "<", ">", "=", "~", "|", "$"]
        var out = ""
        for ch in s {
            if special.contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// The note's YAML properties as raw strings (top-level `key: value` lines only).
    public static func properties(_ text: String) -> [String: String] {
        guard text.hasPrefix("---\n") else { return [:] }
        var out: [String: String] = [:]
        for line in text.dropFirst(4).split(separator: "\n", omittingEmptySubsequences: false) {
            if line == "---" { break }
            guard !line.hasPrefix(" "), let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon])
            var value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if value.hasPrefix("\""), value.hasSuffix("\""), value.count >= 2 { value = String(value.dropFirst().dropLast()) }
            out[key] = value
        }
        return out
    }
}
