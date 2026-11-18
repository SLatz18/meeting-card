import Foundation

/// Why a saved transcript has no text for a stretch of the call.
public enum GapKind: String, CaseIterable, Sendable {
    /// The coach's own Mute: the user's mic is off, so there is no You text (Them goes on).
    case youMuted = "you-muted"
    /// The user paused the coach: nothing is captured.
    case paused
    /// The call app reports the user muted: the coach holds all capture, like a pause.
    case appMuted = "app-muted"
    /// The transcriber stopped for the rest of the call (an error or the cost cap).
    case transcriberStopped = "transcriber-stopped"
    /// The transcriber is retrying after an error; text resumes when it reconnects.
    case transcriberRetrying = "transcriber-retrying"
    /// Call audio capture is restarting (the capture fallback, or the call app's audio came back).
    case callAudioReconnecting = "call-audio-reconnecting"
    /// Recovered after the app quit mid-call: the transcript ends here.
    case appQuit = "app-quit"
}

public struct TranscriptGap: Equatable, Sendable {
    public var kind: GapKind
    public var start: TimeInterval
    /// nil while the gap is open.
    public var end: TimeInterval?
    /// A short machine reason (for example a `GptStopReason` raw value), shown through `NoteWording`.
    public var detail: String?

    public init(kind: GapKind, start: TimeInterval, end: TimeInterval? = nil, detail: String? = nil) {
        self.kind = kind
        self.start = start
        self.end = end
        self.detail = detail
    }
}

/// A coaching cue shown during the call, at its time since the call started.
public struct CueMark: Equatable, Sendable {
    public var type: String
    public var offset: TimeInterval

    public init(type: String, offset: TimeInterval) {
        self.type = type
        self.offset = offset
    }
}

/// What the host knows about the call, for the note's file name and properties. Every field is optional.
public struct CallInfo: Equatable, Sendable {
    public var title: String?
    /// The call app's display name.
    public var app: String?
    public var participants: [String]
    /// The transcription model's name.
    public var transcriber: String?

    public init(title: String? = nil, app: String? = nil, participants: [String] = [], transcriber: String? = nil) {
        self.title = title
        self.app = app
        self.participants = participants
        self.transcriber = transcriber
    }
}

/// One call as the saved note shows it: the host's call details, finished lines, gaps and cues. Built
/// live by `TranscriptRecorder`, or replayed from the call's spool after the app quit mid-call.
public struct CallRecord: Equatable, Sendable {
    public var callId: String
    public var start: Date
    public var info: CallInfo
    public var tags: [String]
    public var lines: [TranscriptLine] = []
    public var gaps: [TranscriptGap] = []
    public var cues: [CueMark] = []
    /// Seconds since the start; set when the call ended (or was recovered).
    public var end: TimeInterval?

    public init(callId: String, start: Date, info: CallInfo = CallInfo(), tags: [String] = []) {
        self.callId = callId
        self.start = start
        self.info = info
        self.tags = tags
    }

    /// The latest time anything happened.
    public var lastOffset: TimeInterval {
        ([0] + lines.map(\.offset) + cues.map(\.offset) + gaps.flatMap { [$0.start, $0.end ?? $0.start] }).max() ?? 0
    }

    public func isOpen(_ kind: GapKind) -> Bool {
        gaps.contains { $0.kind == kind && $0.end == nil }
    }

    /// Opens a gap unless one of that kind is already open.
    public mutating func openGap(_ kind: GapKind, at t: TimeInterval, detail: String? = nil) {
        guard !isOpen(kind) else { return }
        gaps.append(TranscriptGap(kind: kind, start: max(0, t), detail: detail))
    }

    public mutating func closeGap(_ kind: GapKind, at t: TimeInterval) {
        guard let i = gaps.lastIndex(where: { $0.kind == kind && $0.end == nil }) else { return }
        gaps[i].end = max(gaps[i].start, t)
    }

    public mutating func closeAllGaps(at t: TimeInterval) {
        for i in gaps.indices where gaps[i].end == nil { gaps[i].end = max(gaps[i].start, t) }
    }
}

// MARK: spool

/// The call's spool: one JSON object per line, appended and synced as each thing happens, so a call
/// survives the app quitting mid-call. It is a hidden file in the chosen folder (Obsidian and Finder
/// skip dot files) and is removed once the call's note is final. A torn last line (a crash
/// mid-append) is skipped.
public enum CallSpool {
    static let prefix = ".meetingcard-"
    public static let fileExtension = "spool"
    static let version = 1

    public static func url(callId: String, in folder: URL) -> URL {
        folder.appendingPathComponent("\(prefix)\(callId).\(fileExtension)")
    }

    public static func isSpool(_ url: URL) -> Bool {
        url.lastPathComponent.hasPrefix(prefix) && url.pathExtension == fileExtension
    }

    struct Record: Codable, Equatable {
        /// `written`: the note named in it reached disk once (so if it is missing later, the user removed it).
        enum Kind: String, Codable { case begin, info, line, gap, cue, label, note, written, end }
        var k: Kind
        /// Seconds since the call started.
        var t: Double?
        /// Hash of the note text written right after this record (see `TranscriptRecorder`).
        var h: String?
        // begin
        var v: Int?
        var id: String?
        var start: Double?
        var tags: [String]?
        /// The daily note's path relative to the vault (or the folder), checked again at recovery.
        var daily: String?
        var dailyStyle: String?
        /// The device and process writing the spool, so recovery leaves a live call alone.
        var dev: String?
        var pid: Int32?
        // begin, note and written: the note's file name in the folder
        var note: String?
        // info
        var title: String?
        var app: String?
        var participants: [String]?
        var transcriber: String?
        // line and label: speaker, Them index, text or tag
        var s: String?
        var n: Int?
        var x: String?
        // gap: kind, opened or closed, detail
        var g: String?
        var on: Bool?
        var r: String?
        // cue
        var c: String?

        init(_ k: Kind, t: Double? = nil) {
            self.k = k
            self.t = t
        }

        func encoded() -> String {
            let e = JSONEncoder()
            e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
            return ((try? e.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "{}") + "\n"
        }
    }

    static func begin(_ r: CallRecord, device: String, pid: Int32) -> Record {
        var b = Record(.begin, t: 0)
        b.v = version
        b.id = r.callId
        b.start = r.start.timeIntervalSince1970
        b.tags = r.tags
        b.dev = device
        b.pid = pid
        b.title = r.info.title
        b.app = r.info.app
        b.participants = r.info.participants
        b.transcriber = r.info.transcriber
        return b
    }

    static func info(_ i: CallInfo, t: Double) -> Record {
        var r = Record(.info, t: t)
        r.title = i.title
        r.app = i.app
        r.participants = i.participants
        r.transcriber = i.transcriber
        return r
    }

    static func line(_ l: TranscriptLine) -> Record {
        var r = Record(.line, t: l.offset)
        r.s = l.speaker.rawValue
        r.n = l.themIndex
        r.x = l.text
        return r
    }

    static func gap(_ kind: GapKind, open: Bool, t: Double, detail: String?) -> Record {
        var r = Record(.gap, t: t)
        r.g = kind.rawValue
        r.on = open
        r.r = detail
        return r
    }

    static func cue(_ c: CueMark) -> Record {
        var r = Record(.cue, t: c.offset)
        r.c = c.type
        return r
    }

    static func label(_ speaker: Speaker, tag: String?, t: Double) -> Record {
        var r = Record(.label, t: t)
        r.s = speaker.rawValue
        r.x = tag
        return r
    }

    static func note(_ name: String, t: Double) -> Record {
        var r = Record(.note, t: t)
        r.note = name
        return r
    }

    static func written(_ name: String) -> Record {
        var r = Record(.written)
        r.note = name
        return r
    }

    static func end(t: Double) -> Record {
        Record(.end, t: t)
    }

    /// What a spool holds, replayed.
    public struct Replay: Equatable, Sendable {
        public var record: CallRecord
        public var labels: SpeakerLabels
        /// The note's current file name in the call's folder.
        public var noteName: String
        /// Every note text hash the recorder wrote, oldest first.
        public var hashes: [String]
        /// Notes known to have reached disk.
        public var written: Set<String> = []
        public var ended: Bool
        /// Relative to the vault (or the folder); unchecked until `DailyNote.url` resolves it.
        public var dailyPath: String?
        public var dailyStyle: DailyNoteOptions.Style?
        public var device: String?
        public var pid: Int32?
    }

    /// A call ID safe in a file name and a marker: 1–64 letters, digits, `-` or `_`.
    public static func isValidCallId(_ s: String) -> Bool {
        !s.isEmpty && s.utf8.count <= 64 && s.unicodeScalars.allSatisfy {
            ($0.isASCII && CharacterSet.alphanumerics.contains($0)) || $0 == "-" || $0 == "_"
        }
    }

    /// nil when there is no readable `begin` record (nothing to recover). A spool can come from
    /// anywhere (a synced or copied folder), so the call ID and every note name must be plain
    /// (`isValidCallId`, `NoteFileName.isPlainNoteName`); a begin record that isn't is no call, and a
    /// note record that isn't is skipped.
    public static func replay(_ text: String, labels defaults: SpeakerLabels = SpeakerLabels()) -> Replay? {
        let d = JSONDecoder()
        var out: Replay?
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let rec = try? d.decode(Record.self, from: Data(raw.utf8)) else { continue }
            if rec.k == .begin {
                guard out == nil, let id = rec.id, isValidCallId(id), let start = rec.start, start.isFinite,
                      let note = rec.note, NoteFileName.isPlainNoteName(note) else { continue }
                let info = CallInfo(title: rec.title, app: rec.app, participants: rec.participants ?? [], transcriber: rec.transcriber)
                out = Replay(record: CallRecord(callId: id, start: Date(timeIntervalSince1970: start), info: info, tags: rec.tags ?? []),
                             labels: defaults, noteName: note, hashes: [], ended: false,
                             dailyPath: rec.daily, dailyStyle: rec.dailyStyle.flatMap(DailyNoteOptions.Style.init(rawValue:)),
                             device: rec.dev, pid: rec.pid)
                if let h = rec.h { out?.hashes.append(h) }
                continue
            }
            guard var r = out else { continue }
            let t = max(0, rec.t ?? r.record.lastOffset)
            switch rec.k {
            case .begin: break
            case .info:
                r.record.info = CallInfo(title: rec.title, app: rec.app, participants: rec.participants ?? [], transcriber: rec.transcriber)
            case .line:
                if let s = rec.s.flatMap(Speaker.init(rawValue:)), let x = rec.x {
                    r.record.lines.append(TranscriptLine(speaker: s, offset: t, text: x, themIndex: rec.n))
                }
            case .gap:
                if let kind = rec.g.flatMap(GapKind.init(rawValue:)) {
                    if rec.on == true { r.record.openGap(kind, at: t, detail: rec.r) } else { r.record.closeGap(kind, at: t) }
                }
            case .cue:
                if let c = rec.c { r.record.cues.append(CueMark(type: c, offset: t)) }
            case .label:
                if let s = rec.s.flatMap(Speaker.init(rawValue:)) { r.labels.rename(s, to: rec.x) }
            case .note:
                if let n = rec.note, NoteFileName.isPlainNoteName(n) { r.noteName = n }
            case .written:
                if let n = rec.note { r.written.insert(n) }
            case .end:
                r.ended = true
                r.record.end = t
            }
            if let h = rec.h { r.hashes.append(h) }
            out = r
        }
        return out
    }
}

/// FNV-1a, 64 bit: tells whether a note still holds exactly what the recorder wrote. Not a security hash.
public func noteHash(_ text: String) -> String {
    var h: UInt64 = 0xcbf2_9ce4_8422_2325
    for b in text.utf8 {
        h ^= UInt64(b)
        h = h &* 0x0000_0100_0000_01b3
    }
    let hex = String(h, radix: 16)
    return String(repeating: "0", count: 16 - hex.count) + hex
}
