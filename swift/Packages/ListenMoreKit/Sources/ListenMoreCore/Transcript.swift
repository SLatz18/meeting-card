import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

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
/// Every method is required: a store that, say, couldn't read back would silently lose the spool and
/// edit detection.
public protocol TranscriptStore: AnyObject {
    /// Creates `folder` (and parents) if missing.
    func prepare(folder: URL) throws
    func exists(_ url: URL) -> Bool
    /// Replaces the file's contents with `text` (atomically, for a real store).
    func write(_ text: String, to url: URL) throws
    /// Writes a new file; throws `TranscriptStoreError.exists`, writing nothing, if anything is at `url`.
    func create(_ text: String, at url: URL) throws
    func remove(_ url: URL) throws
    /// Adds `text` at the end, creating the file if missing (synced, for a real store).
    func append(_ text: String, to url: URL) throws
    /// nil when missing or unreadable (not UTF-8, for example).
    func read(_ url: URL) -> String?
    /// The file's first `bytes` bytes as text (for its properties); nil when missing.
    func head(_ url: URL, bytes: Int) -> String?
    /// The folder's entries, hidden ones included; empty when it can't be listed.
    func contents(of folder: URL) -> [URL]
    func modified(_ url: URL) -> Date?
    func isDirectory(_ url: URL) -> Bool
}

public enum TranscriptStoreError: Error, Equatable {
    /// `create` found something at the name.
    case exists
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
    /// Waits at most that long; false if work was still queued.
    let waitUpTo: (TimeInterval) -> Bool

    public static func serial(label: String = "com.listenmore.transcript") -> TranscriptIO {
        let q = DispatchQueue(label: label, qos: .utility)
        return TranscriptIO(run: { q.async(execute: $0) }, back: { DispatchQueue.main.async(execute: $0) }, wait: { q.sync {} },
                            waitUpTo: { seconds in
                                let done = DispatchSemaphore(value: 0)
                                q.async { done.signal() }
                                return done.wait(timeout: .now() + seconds) == .success
                            })
    }

    public static let inline = TranscriptIO(run: { $0() }, back: { $0() }, wait: {}, waitUpTo: { _ in true })
}

/// One call's saved transcript. Saving off (`begin(folder: nil)`): nothing is kept and nothing is
/// written. Saving on: each finished line, gap, cue and speaker tag is appended to the call's spool
/// and synced, then the whole note is rendered and replaced atomically (so a tag relabels earlier
/// lines too). Every disk access runs on the I/O queue, `begin` included. A note's first write never
/// replaces a file. The note is never written over text the recorder didn't write: if it changed on
/// disk during the call (edited in Obsidian) or can't be read, the rest goes to a new note beside
/// it; if it was removed, saving stops for the call. `end()` finishes the note, removes the spool and
/// drops the call from memory. After a crash, `TranscriptMaintenance.recover` finishes the note.
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
    /// Names this machine, boot and process in each spool, so recovery leaves a live call alone.
    public let identity: ProcessIdentity
    private let timeZone: TimeZone
    private let io: TranscriptIO
    private let newCallId: () -> String
    public private(set) var state: State = .off
    /// The current call's note, or the last call's (what Delete removes). Until the I/O queue has
    /// created it, the name it will try first.
    public private(set) var lastURL: URL?
    private var record: CallRecord?
    private var labels = SpeakerLabels()
    private var sink: NoteSink?
    /// The last call's sink, so its notes stay deletable after it ends.
    private var lastSink: NoteSink?
    /// Every note name this recorder chose, so two calls never share one before the first is on disk.
    private var reserved: Set<String> = []

    public init(store: TranscriptStore, timeZone: TimeZone = .current, wording: NoteWording = NoteWording(),
                io: TranscriptIO = .inline, identity: ProcessIdentity = .current,
                newCallId: @escaping () -> String = TranscriptRecorder.randomCallId) {
        self.store = store
        self.timeZone = timeZone
        self.wording = wording
        self.io = io
        self.identity = identity
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
        let first = NoteFileName.unclaimed(base: base, in: folder, reserved: reserved)
        reserved.insert(first.lastPathComponent)
        record = r
        let sink = NoteSink(store: store, folder: folder, base: base, note: first, callId: r.callId, reserved: reserved)
        self.sink = sink
        state = .saving(first)
        lastURL = first
        lastSink = sink
        let text = render(.inProgress)
        var spoolBegin = CallSpool.begin(r, identity: identity)
        spoolBegin.h = noteHash(text)
        let plan = NoteSink.Start(begin: spoolBegin, text: text, daily: options.dailyNote, start: start,
                                  title: info.title ?? wording.untitled, timeZone: timeZone)
        perform(sink) { $0.start(plan) }
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

    /// Waits until every queued write has run (tests).
    public func flush() {
        io.wait()
    }

    /// Waits at most `seconds` for the queued writes (app quit); false if some were still queued.
    @discardableResult
    public func flush(timeout seconds: TimeInterval) -> Bool {
        io.waitUpTo(seconds)
    }

    /// Recovery and retention for `folder`, queued behind this recorder's writes so they never race
    /// a call being saved: the current call's spool and note are left alone. `retentionDays` nil: off.
    /// The clock is read when the work runs (`now` only for tests). `done` gets, on the main queue,
    /// how many calls are still unfinished (spools recovery had to leave).
    public func maintain(folder: URL, retentionDays: Int?, pattern: String = NoteFileName.defaultPattern,
                         labels: SpeakerLabels = SpeakerLabels(), now: Date? = nil, done: ((Int) -> Void)? = nil) {
        let skip: Set<String> = record.map { [$0.callId] } ?? []
        let keep: Set<URL> = lastURL.map { [$0] } ?? []
        let store = store, wording = wording, timeZone = timeZone, identity = identity, io = io
        io.run {
            let clock = now ?? Date()
            TranscriptMaintenance.recover(folder: folder, store: store, labels: labels, wording: wording, timeZone: timeZone,
                                          now: clock, skip: skip, identity: identity)
            if let days = retentionDays {
                TranscriptMaintenance.prune(folder: folder, store: store, olderThanDays: days, pattern: pattern, now: clock, keep: keep)
            }
            let left = TranscriptMaintenance.unfinished(folder: folder, store: store, skip: skip)
            if let done { io.back { done(left) } }
        }
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
        /// The note is at another name than the recorder last heard (taken, edited or unreadable).
        case moved(URL)
        /// The note was removed during the call; saving stopped and the spool is gone.
        case vanished
        case failed
    }

    /// What `start` needs; the names and paths are worked out on the I/O queue.
    struct Start {
        var begin: CallSpool.Record
        var text: String
        var daily: DailyNoteOptions?
        var start: Date
        var title: String
        var timeZone: TimeZone
    }

    let store: TranscriptStore
    let folder: URL
    let spool: URL
    let callId: String
    /// The call's file name before any " (n)".
    let base: String
    private(set) var note: URL
    /// Every note this call wrote (Delete removes them all).
    private(set) var notes: [URL] = []
    private var lastHash: String?
    private var stopped = false
    /// Notes whose first write is confirmed in the spool.
    private var confirmed: Set<String> = []
    private var reserved: Set<String>

    init(store: TranscriptStore, folder: URL, base: String, note: URL, callId: String, reserved: Set<String>) {
        self.store = store
        self.folder = folder
        self.base = base
        self.note = note
        self.callId = callId
        self.reserved = reserved
        spool = CallSpool.url(callId: callId, in: folder)
    }

    func start(_ plan: Start) -> Outcome {
        let first = note
        do {
            try store.prepare(folder: folder)
            reserved.remove(first.lastPathComponent)
            note = NoteFileName.unique(base: base, in: folder, store: store, reserved: reserved)
            var begin = plan.begin
            begin.note = note.lastPathComponent
            let vault = ObsidianVault.root(containing: folder, store: store)
            let root = vault ?? folder
            var dailyURL: URL?
            if let d = plan.daily, let url = DailyNote.url(pattern: d.pathPattern, date: plan.start, root: root, timeZone: plan.timeZone),
               let rel = ObsidianVault.relativePath(of: url, under: root) {
                dailyURL = url
                begin.daily = rel
                begin.dailyStyle = d.style.rawValue
            }
            try store.append(begin.encoded(), to: spool)
            try createNote(plan.text)
            if let dailyURL, let d = plan.daily {
                let line = DailyNote.line(note: note, vaultRoot: vault, start: plan.start, title: plan.title, style: d.style,
                                          callId: callId, timeZone: plan.timeZone)
                _ = try? DailyNote.append(line, marker: DailyNote.marker(callId: callId), to: dailyURL, store: store)
            }
        } catch {
            return fail()
        }
        return note == first ? .ok : .moved(note)
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
        guard let lastHash else { return fail() }
        if !store.exists(note) {
            stopped = true
            removeSpool()
            return .vanished
        }
        if store.read(note).map(noteHash) == lastHash {
            do {
                try store.write(text, to: note)
            } catch {
                return fail()
            }
            self.lastHash = noteHash(text)
            return .ok
        }
        // Changed on disk, or unreadable: never written over. The rest goes beside it.
        reserved.insert(note.lastPathComponent)
        note = NoteFileName.unique(base: base, in: folder, store: store, reserved: reserved)
        _ = try? store.append(CallSpool.note(note.lastPathComponent, t: 0).encoded(), to: spool)
        do {
            try createNote(text)
        } catch {
            return fail()
        }
        return .moved(note)
    }

    /// The note's first write: never over a file, so a name taken since it was chosen moves on to
    /// the next free one (recorded in the spool first).
    private func createNote(_ text: String) throws {
        for _ in 0..<20 {
            do {
                try store.create(text, at: note)
                notes.append(note)
                reserved.insert(note.lastPathComponent)
                lastHash = noteHash(text)
                confirm()
                return
            } catch TranscriptStoreError.exists {
                reserved.insert(note.lastPathComponent)
                note = NoteFileName.unique(base: base, in: folder, store: store, reserved: reserved)
                try store.append(CallSpool.note(note.lastPathComponent, t: 0).encoded(), to: spool)
            }
        }
        throw TranscriptStoreError.exists
    }

    /// Records, once per note, that it reached disk.
    private func confirm() {
        let name = note.lastPathComponent
        guard !confirmed.contains(name) else { return }
        confirmed.insert(name)
        _ = try? store.append(CallSpool.written(name).encoded(), to: spool)
    }

    private func fail() -> Outcome {
        stopped = true
        return .failed
    }
}

// MARK: maintenance

/// Upkeep for the chosen folder: finishing notes from spools a quit left behind, and the opt-in
/// retention. Both touch only notes this app wrote (they carry `meetingcard-call`), only in the
/// chosen folder (and, for recovery, the vault's daily note), and never a note edited after its call.
public enum TranscriptMaintenance {
    /// A spool written on another device is left for that device unless untouched this long.
    public static let otherDeviceIdle: TimeInterval = 6 * 3600
    /// How long after the note's last write by MeetingCard a change still counts as that write.
    public static let writeSlack: TimeInterval = 10
    /// Retention reads at most this much of a note: its properties.
    static let propertiesBytes = 4096

    /// Finishes each call whose spool is still in `folder`: an unfinished call gets an app-quit gap at
    /// its last event and `recovered` status, and every note recovery writes gets a `recovered` time.
    /// Left alone: the calls in `skip`, a spool another running process on this device is writing
    /// (same boot, same PID and start time), and one from another device unless idle for
    /// `otherDeviceIdle`. Without a device ID on either side, a spool from another boot gets the
    /// same idle rule, since it may be another machine's. Names come from the spool only
    /// if plain (`CallSpool.replay`), and the daily note is found again through `DailyNote.url`. The
    /// note is rewritten only if it still holds what the recorder wrote; otherwise the recovered note
    /// goes beside it, and it never replaces a file. A note removed after it reached disk stays
    /// removed. Returns the notes written. Also clears temporary files a crash left behind.
    @discardableResult
    public static func recover(folder: URL, store: TranscriptStore, labels: SpeakerLabels = SpeakerLabels(),
                               wording: NoteWording = NoteWording(), timeZone: TimeZone = .current,
                               now: Date = Date(), skip: Set<String> = [], identity: ProcessIdentity = .current) -> [URL] {
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
            guard !skip.contains(replay.record.callId) else { continue }
            // Another machine, or (without a device ID on either side) another boot that could be one:
            // wait until it has been idle. Otherwise it's this machine, and only a live writer is waited for.
            let devicesKnown = replay.device != nil && identity.device != nil
            let otherMachine = devicesKnown ? replay.device != identity.device
                : replay.boot.map { b in identity.boot.map { $0 != b } ?? false } ?? false
            if otherMachine {
                guard let m = store.modified(spool), now.timeIntervalSince(m) > otherDeviceIdle else { continue }
            } else if identity.mayBeWriting(boot: replay.boot, pid: replay.pid, startTime: replay.startTime) {
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
            let noteText = CallNote.render(r, labels: replay.labels, status: status, wording: wording, timeZone: timeZone,
                                           recoveredAt: now)
            var note = folder.appendingPathComponent(replay.noteName)
            let base = String(note.deletingPathExtension().lastPathComponent)
            do {
                let onDisk = store.exists(note) ? store.read(note) : nil
                // Ours, or the empty placeholder a crash left while claiming the name (FAT, exFAT).
                if onDisk.map({ replay.hashes.contains(noteHash($0)) || ($0.isEmpty && !replay.written.contains(replay.noteName)) }) == true {
                    try store.write(noteText, to: note)
                } else if !store.exists(note) && replay.written.contains(replay.noteName) {
                    // It reached disk and is gone: the user removed it.
                    try? store.remove(spool)
                    continue
                } else {
                    var created = false
                    for _ in 0..<20 where !created {
                        if store.exists(note) { note = NoteFileName.unique(base: base, in: folder, store: store) }
                        do {
                            try store.create(noteText, at: note)
                            created = true
                        } catch TranscriptStoreError.exists {
                            continue
                        }
                    }
                    guard created else { continue }
                }
            } catch {
                continue
            }
            written.append(note)
            if let rel = replay.dailyPath, let style = replay.dailyStyle {
                let vault = ObsidianVault.root(containing: folder, store: store)
                if let daily = DailyNote.url(pattern: rel, date: r.start, root: vault ?? folder, timeZone: timeZone) {
                    let line = DailyNote.line(note: note, vaultRoot: vault, start: r.start, title: r.info.title ?? wording.untitled,
                                              style: style, callId: r.callId, timeZone: timeZone)
                    _ = try? DailyNote.append(line, marker: DailyNote.marker(callId: r.callId), to: daily, store: store)
                }
            }
            try? store.remove(spool)
        }
        return written
    }

    /// Calls whose spool is still in `folder` (other than those in `skip`): what recovery had to leave.
    public static func unfinished(folder: URL, store: TranscriptStore, skip: Set<String> = []) -> Int {
        store.contents(of: folder).filter { url in
            guard let id = CallSpool.callId(of: url), !skip.contains(id), let text = store.read(url) else { return false }
            return CallSpool.replay(text) != nil
        }.count
    }

    /// Retention: removes notes this app wrote in `folder` whose last write by MeetingCard was more
    /// than `days` days before `now` and that nobody changed since (by more than `writeSlack`). That
    /// time is `meetingcard-saved`, in seconds since 1970, so it reads the same in any time zone; a
    /// note without it (still in progress, or not finished) is never removed. Looks only at names
    /// `pattern` could have made, directly in `folder`, and reads only their properties. Returns the
    /// notes removed.
    @discardableResult
    public static func prune(folder: URL, store: TranscriptStore, olderThanDays days: Int, pattern: String = NoteFileName.defaultPattern,
                             now: Date = Date(), keep: Set<URL> = []) -> [URL] {
        guard days > 0 else { return [] }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        // A listing can name the same file by another path (macOS: /private/var for /var).
        func key(_ u: URL) -> String { u.standardizedFileURL.resolvingSymlinksInPath().path }
        let kept = Set(keep.map(key))
        var removed: [URL] = []
        for url in store.contents(of: folder) where url.pathExtension == NoteFileName.fileExtension
            && !url.lastPathComponent.hasPrefix(".") && NoteFileName.matches(url.lastPathComponent, pattern: pattern)
            && !kept.contains(key(url)) {
            guard let m = store.modified(url), m < cutoff, let text = store.head(url, bytes: propertiesBytes) else { continue }
            let props = CallNote.properties(text)
            guard props[CallNote.callProperty] != nil, let saved = props[CallNote.savedProperty].flatMap(Double.init),
                  saved.isFinite, case let lastWrite = Date(timeIntervalSince1970: saved), lastWrite < cutoff,
                  m <= lastWrite.addingTimeInterval(writeSlack) else { continue }
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
