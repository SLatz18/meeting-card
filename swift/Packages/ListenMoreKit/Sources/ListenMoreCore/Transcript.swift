import Foundation

/// One finished line of a saved transcript: who, when (seconds since the call started, at the start
/// of the turn) and what. `themIndex` numbers voices within Them (Them 1, Them 2) when the
/// transcription can tell them apart; nil is plain Them.
public struct TranscriptLine: Equatable, Sendable {
    public var speaker: Speaker
    public var offset: TimeInterval
    public var text: String
    public var themIndex: Int?

    public init(speaker: Speaker, offset: TimeInterval, text: String, themIndex: Int? = nil) {
        self.speaker = speaker
        self.offset = offset
        self.text = text
        self.themIndex = themIndex
    }
}

public enum TranscriptFormat {
    /// "00:01:05"
    public static func timestamp(_ offset: TimeInterval) -> String {
        let s = max(0, Int(offset.rounded(.down)))
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }

    static func oneLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }

    static func stamp(_ d: Date, _ format: String, _ tz: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = tz
        f.dateFormat = format
        return f.string(from: d)
    }

    static func parse(_ s: String, _ format: String, _ tz: TimeZone) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = tz
        f.dateFormat = format
        return f.date(from: s)
    }
}

/// Where saved transcripts go. `FileTranscriptStore` is the only implementation that touches disk.
/// The defaults let a store that only replaces whole files conform (a host's in-memory preview
/// store, or a wrapper that counts writes); without `read` such a store keeps only the spool's
/// latest record and the recorder can't see edits, so a store that keeps real files implements all.
public protocol TranscriptStore: AnyObject {
    /// Creates `folder` (and parents) if missing.
    func prepare(folder: URL) throws
    func exists(_ url: URL) -> Bool
    /// Replaces the file's contents with `text` (atomically, for a real store).
    func write(_ text: String, to url: URL) throws
    func remove(_ url: URL) throws
    /// Adds `text` at the end, creating the file if missing (synced, for a real store).
    func append(_ text: String, to url: URL) throws
    /// nil when missing or unreadable.
    func read(_ url: URL) -> String?
    /// The folder's entries, hidden ones included; empty when it can't be listed.
    func contents(of folder: URL) -> [URL]
    func modified(_ url: URL) -> Date?
    func isDirectory(_ url: URL) -> Bool
}

public extension TranscriptStore {
    func append(_ text: String, to url: URL) throws { try write((read(url) ?? "") + text, to: url) }
    func read(_ url: URL) -> String? { nil }
    func contents(of folder: URL) -> [URL] { [] }
    func modified(_ url: URL) -> Date? { nil }
    func isDirectory(_ url: URL) -> Bool { false }
}

/// The note's options: the file name pattern, tags and the optional daily-note line.
public struct NoteOptions: Equatable, Sendable {
    public var fileNamePattern: String
    public var tags: [String]
    /// nil: off.
    public var dailyNote: DailyNoteOptions?

    public init(fileNamePattern: String = NoteFileName.defaultPattern, tags: [String] = [CallNote.defaultTag],
                dailyNote: DailyNoteOptions? = nil) {
        self.fileNamePattern = fileNamePattern
        self.tags = tags
        self.dailyNote = dailyNote
    }
}

/// Where the recorder's disk work runs. `serial` keeps file syncs off the caller's thread and runs
/// them strictly in order, then reports back on the main queue; `inline` runs everything at once
/// (tests and previews).
public struct TranscriptIO: @unchecked Sendable {
    let run: (@escaping () -> Void) -> Void
    let back: (@escaping () -> Void) -> Void
    let wait: () -> Void

    public static func serial(label: String = "com.listenmore.transcript") -> TranscriptIO {
        let q = DispatchQueue(label: label, qos: .utility)
        return TranscriptIO(run: { q.async(execute: $0) }, back: { DispatchQueue.main.async(execute: $0) }, wait: { q.sync {} })
    }

    public static let inline = TranscriptIO(run: { $0() }, back: { $0() }, wait: {})
}

/// One call's saved transcript. Saving off (`begin(folder: nil)`): nothing is kept and nothing is
/// written. Saving on: each finished line, gap, cue and speaker tag is appended to the call's spool
/// and synced, then the whole note is rendered and replaced atomically (so a tag relabels earlier
/// lines too). The note is never written over text the recorder didn't write: if it changed on disk
/// during the call (edited in Obsidian), the rest goes to a new note beside it; if it was removed,
/// saving stops for the call. `end()` finishes the note, removes the spool and drops the call from
/// memory. After a crash, `TranscriptMaintenance.recover` finishes the note from the spool.
public final class TranscriptRecorder {
    public enum State: Equatable, Sendable {
        case off
        /// Writing the call's note.
        case saving(URL)
        /// The call's note was written; the call is over or saving stopped.
        case saved(URL)
        case deleted
        /// A write failed; saving stopped for this call.
        case failed
    }

    public let store: TranscriptStore
    public let wording: NoteWording
    private let timeZone: TimeZone
    private let io: TranscriptIO
    private let newCallId: () -> String
    public private(set) var state: State = .off
    /// The current call's note, or the last call's (what Delete removes).
    public private(set) var lastURL: URL?
    private var record: CallRecord?
    private var labels = SpeakerLabels()
    private var sink: NoteSink?
    /// The last call's sink, so its notes stay deletable after it ends.
    private var lastSink: NoteSink?
    /// Every note name this recorder chose, so two calls never share one before the first is on disk.
    private var reserved: Set<String> = []

    public init(store: TranscriptStore, timeZone: TimeZone = .current, wording: NoteWording = NoteWording(),
                io: TranscriptIO = .inline, newCallId: @escaping () -> String = TranscriptRecorder.randomCallId) {
        self.store = store
        self.timeZone = timeZone
        self.wording = wording
        self.io = io
        self.newCallId = newCallId
    }

    public static func randomCallId() -> String {
        "c" + UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased().prefix(16)
    }

    public var isSaving: Bool {
        if case .saving = state { return true }
        return false
    }

    public var keptLineCount: Int { record?.lines.count ?? 0 }
    /// The call being saved (nil when not saving).
    public var current: CallRecord? { isSaving ? record : nil }

    /// A call started. `folder` nil = saving off.
    public func begin(start: Date, folder: URL?, labels: SpeakerLabels, info: CallInfo = CallInfo(),
                      options: NoteOptions = NoteOptions()) {
        end()
        state = .off
        guard let folder else { return }
        let r = CallRecord(callId: newCallId(), start: start, info: info, tags: options.tags)
        self.labels = labels
        let base = NoteFileName.base(pattern: options.fileNamePattern, start: start, info: info, wording: wording, timeZone: timeZone)
        let url = NoteFileName.unique(base: base, in: folder, store: store, reserved: reserved)
        reserved.insert(url.lastPathComponent)
        var daily: (url: URL, line: String)?
        if let d = options.dailyNote {
            let vault = ObsidianVault.root(containing: folder, store: store)
            if let dailyURL = DailyNote.url(pattern: d.pathPattern, date: start, root: vault ?? folder, timeZone: timeZone) {
                let line = DailyNote.line(note: url, vaultRoot: vault, start: start, title: info.title ?? wording.untitled,
                                          style: d.style, callId: r.callId, timeZone: timeZone)
                daily = (dailyURL, line)
            }
        }
        record = r
        let sink = NoteSink(store: store, folder: folder, note: url, callId: r.callId, reserved: reserved)
        self.sink = sink
        state = .saving(url)
        lastURL = url
        lastSink = sink
        let text = render(.inProgress)
        var spoolBegin = CallSpool.begin(r, note: url.lastPathComponent, daily: daily.map { ($0.url.path, $0.line) })
        spoolBegin.h = noteHash(text)
        let first = spoolBegin
        let dailyAppend = daily.map { ($0.url, $0.line, DailyNote.marker(callId: r.callId)) }
        perform(sink) { $0.start(first, text: text, daily: dailyAppend) }
    }

    public func add(_ line: TranscriptLine) {
        guard isSaving else { return }
        record?.lines.append(line)
        commit(CallSpool.line(line))
    }

    /// The host's call details changed (for example the title arrived after the call started).
    public func setInfo(_ info: CallInfo) {
        guard isSaving, let r = record, r.info != info else { return }
        record?.info = info
        commit(CallSpool.info(info, t: r.lastOffset))
    }

    public func relabel(_ labels: SpeakerLabels) {
        guard isSaving, let r = record else { return }
        let old = self.labels
        self.labels = labels
        for s in Speaker.allCases where old.label(s) != labels.label(s) {
            let tag = labels.label(s) == labels.defaults[s] ? nil : labels.label(s)
            commit(CallSpool.label(s, tag: tag, t: r.lastOffset))
        }
    }

    /// Opens or closes a gap of `kind` at `t` (seconds since the call started).
    public func gap(_ kind: GapKind, open: Bool, at t: TimeInterval, detail: String? = nil) {
        guard isSaving, let r = record, r.isOpen(kind) != open else { return }
        if open { record?.openGap(kind, at: t, detail: detail) } else { record?.closeGap(kind, at: t) }
        commit(CallSpool.gap(kind, open: open, t: t, detail: detail))
    }

    public func cue(_ type: String, at t: TimeInterval) {
        guard isSaving else { return }
        let c = CueMark(type: type, offset: t)
        record?.cues.append(c)
        commit(CallSpool.cue(c))
    }

    /// Finishes the note (if saving) at `t` (default: the last thing that happened) and forgets the call.
    public func end(at t: TimeInterval? = nil) {
        if case .saving(let url) = state, var r = record, let sink {
            let at = max(t ?? r.lastOffset, r.lastOffset)
            r.closeAllGaps(at: at)
            r.end = at
            record = r
            var last = CallSpool.end(t: at)
            let text = render(.complete)
            last.h = noteHash(text)
            state = .saved(url)
            perform(sink) { $0.finish(last, text: text) }
        }
        if state == .failed || state == .deleted { state = .off }
        record = nil
        sink = nil
        labels.reset()
    }

    /// Deletes the current call's notes and spool, or else the last call's. Deleting during a call
    /// stops saving for the rest of it. Returns false when there is nothing to delete. Waits for the
    /// call's queued writes, so nothing is written after it returns.
    @discardableResult
    public func deleteCurrentOrLast() throws -> Bool {
        guard lastURL != nil, let target = lastSink else { return false }
        let during = isSaving
        lastURL = nil
        lastSink = nil
        record = nil
        if during { sink = nil }
        state = during ? .deleted : .off
        var failure: Error?
        io.run { failure = target.delete() }
        io.wait()
        if let failure { throw failure }
        return true
    }

    /// Waits until every queued write has run (app quit, tests).
    public func flush() {
        io.wait()
    }

    // MARK: private

    private func render(_ status: NoteStatus) -> String {
        guard let r = record else { return "" }
        return CallNote.render(r, labels: labels, status: status, wording: wording, timeZone: timeZone)
    }

    private func commit(_ rec: CallSpool.Record) {
        guard let sink else { return }
        var rec = rec
        let text = render(.inProgress)
        rec.h = noteHash(text)
        perform(sink) { $0.record(rec, text: text) }
    }

    private func perform(_ sink: NoteSink, _ work: @escaping (NoteSink) -> NoteSink.Outcome) {
        let io = io
        io.run { [weak self] in
            let outcome = work(sink)
            guard outcome != .ok else { return }
            io.back { self?.handle(outcome, from: sink) }
        }
    }

    private func handle(_ outcome: NoteSink.Outcome, from sink: NoteSink) {
        guard sink === lastSink else { return }
        switch outcome {
        case .ok:
            break
        case .moved(let url):
            reserved.insert(url.lastPathComponent)
            lastURL = url
            if isSaving { state = .saving(url) } else if case .saved = state { state = .saved(url) }
        case .vanished:
            if isSaving {
                state = .deleted
                record = nil
                self.sink = nil
            }
            lastURL = nil
            lastSink = nil
        case .failed:
            if isSaving {
                state = .failed
                record = nil
                self.sink = nil
            }
        }
    }
}

/// One call's files, touched only on the recorder's I/O queue: the spool, the note (and any note
/// started beside it after an edit), and the daily-note line.
final class NoteSink: @unchecked Sendable {
    enum Outcome: Equatable {
        case ok
        /// The note changed on disk; writing continues in this new note beside it.
        case moved(URL)
        /// The note was removed during the call; saving stopped and the spool is gone.
        case vanished
        case failed
    }

    let store: TranscriptStore
    let folder: URL
    let spool: URL
    let callId: String
    private(set) var note: URL
    /// Every note this call wrote (Delete removes them all).
    private(set) var notes: [URL]
    private var lastHash: String?
    private var stopped = false
    private var reserved: Set<String>

    init(store: TranscriptStore, folder: URL, note: URL, callId: String, reserved: Set<String>) {
        self.store = store
        self.folder = folder
        self.note = note
        self.callId = callId
        self.reserved = reserved
        notes = [note]
        spool = CallSpool.url(callId: callId, in: folder)
    }

    func start(_ begin: CallSpool.Record, text: String, daily: (url: URL, line: String, marker: String)?) -> Outcome {
        do {
            try store.prepare(folder: folder)
            try store.append(begin.encoded(), to: spool)
            try store.write(text, to: note)
            lastHash = noteHash(text)
        } catch {
            return fail()
        }
        if let daily { _ = try? DailyNote.append(daily.line, marker: daily.marker, to: daily.url, store: store) }
        return .ok
    }

    func record(_ rec: CallSpool.Record, text: String) -> Outcome {
        guard !stopped else { return .ok }
        do {
            try store.append(rec.encoded(), to: spool)
        } catch {
            return fail()
        }
        return writeNote(text)
    }

    func finish(_ end: CallSpool.Record, text: String) -> Outcome {
        guard !stopped else { return .ok }
        do {
            try store.append(end.encoded(), to: spool)
        } catch {
            return fail()
        }
        let outcome = writeNote(text)
        stopped = true
        if outcome != .failed { removeSpool() }
        return outcome
    }

    /// Removes the call's notes and spool. The daily note keeps its line (append only).
    func delete() -> Error? {
        stopped = true
        var failure: Error?
        for url in notes where store.exists(url) {
            do { try store.remove(url) } catch { failure = failure ?? error }
        }
        removeSpool()
        return failure
    }

    private func removeSpool() {
        if store.exists(spool) { try? store.remove(spool) }
    }

    private func writeNote(_ text: String) -> Outcome {
        var outcome = Outcome.ok
        if let lastHash {
            if !store.exists(note) {
                stopped = true
                removeSpool()
                return .vanished
            }
            if let onDisk = store.read(note), noteHash(onDisk) != lastHash {
                let base = String(note.deletingPathExtension().lastPathComponent)
                note = NoteFileName.unique(base: base, in: folder, store: store, reserved: reserved)
                reserved.insert(note.lastPathComponent)
                notes.append(note)
                _ = try? store.append(CallSpool.note(note.lastPathComponent, t: 0).encoded(), to: spool)
                outcome = .moved(note)
            }
        }
        do {
            try store.write(text, to: note)
            lastHash = noteHash(text)
        } catch {
            return fail()
        }
        return outcome
    }

    private func fail() -> Outcome {
        stopped = true
        return .failed
    }
}

// MARK: maintenance

/// Launch-time upkeep for the chosen folder: finishing notes from spools a quit left behind, and the
/// opt-in retention. Both touch only notes this app wrote (they carry `meetingcard-call`), only in
/// the chosen folder, and never a note edited since it was written.
public enum TranscriptMaintenance {
    /// Finishes each call whose spool is still in `folder`: an unfinished call gets an app-quit gap at
    /// its last event and `recovered` status. The note is rewritten only if it still holds what the
    /// recorder wrote; otherwise the recovered note goes beside it. A note removed during the call
    /// stays removed. Returns the notes written. Also clears temporary files a crash left behind.
    @discardableResult
    public static func recover(folder: URL, store: TranscriptStore, labels: SpeakerLabels = SpeakerLabels(),
                               wording: NoteWording = NoteWording(), timeZone: TimeZone = .current,
                               now: Date = Date()) -> [URL] {
        for url in store.contents(of: folder) where url.lastPathComponent.hasPrefix(".")
            && url.lastPathComponent.hasSuffix(FileTranscriptStore.tempSuffix) {
            if let m = store.modified(url), now.timeIntervalSince(m) < 3600 { continue }
            try? store.remove(url)
        }
        var written: [URL] = []
        for spool in store.contents(of: folder) where CallSpool.isSpool(spool) {
            guard let text = store.read(spool) else { continue }
            guard let replay = CallSpool.replay(text, labels: labels) else {
                if let m = store.modified(spool), now.timeIntervalSince(m) > 86_400 { try? store.remove(spool) }
                continue
            }
            var r = replay.record
            let status: NoteStatus
            if replay.ended {
                status = .complete
            } else {
                let t = r.lastOffset
                r.closeAllGaps(at: t)
                r.openGap(.appQuit, at: t)
                r.closeAllGaps(at: t)
                r.end = t
                status = .recovered
            }
            let noteText = CallNote.render(r, labels: replay.labels, status: status, wording: wording, timeZone: timeZone)
            var note = folder.appendingPathComponent(replay.noteName)
            if store.exists(note) {
                let ours = store.read(note).map { replay.hashes.contains(noteHash($0)) } ?? false
                if !ours {
                    note = NoteFileName.unique(base: String(note.deletingPathExtension().lastPathComponent), in: folder, store: store)
                }
            } else if replay.hashes.count > 1 {
                // A record after `begin` means the first note was written; it is gone, so the user removed it.
                try? store.remove(spool)
                continue
            }
            do {
                try store.write(noteText, to: note)
            } catch {
                continue
            }
            written.append(note)
            if let path = replay.dailyPath, let line = replay.dailyLine {
                _ = try? DailyNote.append(line, marker: DailyNote.marker(callId: r.callId), to: URL(fileURLWithPath: path), store: store)
            }
            try? store.remove(spool)
        }
        return written
    }

    /// Retention: removes notes this app wrote in `folder` whose call started more than `days` days
    /// before `now` and that haven't changed since then. Never looks in subfolders. Returns the notes removed.
    @discardableResult
    public static func prune(folder: URL, store: TranscriptStore, olderThanDays days: Int, now: Date = Date(),
                             timeZone: TimeZone = .current, keep: Set<URL> = []) -> [URL] {
        guard days > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        var removed: [URL] = []
        for url in store.contents(of: folder) where url.pathExtension == NoteFileName.fileExtension && !keep.contains(url) {
            guard let m = store.modified(url), m < cutoff, let text = store.read(url) else { continue }
            let props = CallNote.properties(text)
            guard props[CallNote.callProperty] != nil, let s = props["start"],
                  let start = TranscriptFormat.parse(s, "yyyy-MM-dd'T'HH:mm:ss", timeZone), start < cutoff else { continue }
            do {
                try store.remove(url)
                removed.append(url)
            } catch {
                continue
            }
        }
        return removed
    }
}
