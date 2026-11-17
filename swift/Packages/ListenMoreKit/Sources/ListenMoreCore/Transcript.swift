import Foundation

/// One finished line of a saved transcript: who, when (seconds since the call started) and what.
public struct TranscriptLine: Equatable, Sendable {
    public var speaker: Speaker
    public var offset: TimeInterval
    public var text: String

    public init(speaker: Speaker, offset: TimeInterval, text: String) {
        self.speaker = speaker
        self.offset = offset
        self.text = text
    }
}

/// The saved transcript's Markdown: one file per call, a short header, then one line per finished
/// turn with its time since the call started and its speaker label.
public enum TranscriptFormat {
    public static let fileExtension = "md"

    /// "Call 2026-01-31 09-05-07.md" (local time; no meeting title or other call details).
    public static func fileName(start: Date, timeZone: TimeZone = .current) -> String {
        "Call \(stamp(start, "yyyy-MM-dd HH-mm-ss", timeZone)).\(fileExtension)"
    }

    /// "00:01:05"
    public static func timestamp(_ offset: TimeInterval) -> String {
        let s = max(0, Int(offset.rounded(.down)))
        return String(format: "%02d:%02d:%02d", s / 3600, s / 60 % 60, s % 60)
    }

    public static func markdown(start: Date, lines: [TranscriptLine], labels: SpeakerLabels,
                                timeZone: TimeZone = .current) -> String {
        var out = """
        # Call transcript

        - Started: \(stamp(start, "yyyy-MM-dd HH:mm:ss xxx", timeZone))
        - Speakers: \(labels.label(.me)) (microphone), \(labels.label(.others)) (call audio)

        """
        for line in lines {
            out += "\n**[\(timestamp(line.offset))] \(labels.label(line.speaker)):** \(oneLine(line.text))\n"
        }
        return out
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
}

/// Where saved transcripts go. `FileTranscriptStore` is the only implementation that touches disk.
public protocol TranscriptStore: AnyObject {
    /// Creates `folder` (and parents) if missing.
    func prepare(folder: URL) throws
    func exists(_ url: URL) -> Bool
    /// Replaces the file's contents with `text`.
    func write(_ text: String, to url: URL) throws
    func remove(_ url: URL) throws
}

/// One call's saved transcript. Saving off (`begin(folder: nil)`): nothing is kept and nothing is
/// written. Saving on: finished lines are kept for the call and the whole file is rewritten after
/// each one (so a speaker tag relabels earlier lines too); `end()` drops them from memory.
public final class TranscriptRecorder {
    public enum State: Equatable, Sendable {
        case off
        /// Writing the call's file.
        case saving(URL)
        /// The call's file was written; the call is over or saving stopped.
        case saved(URL)
        case deleted
        /// A write failed; saving stopped for this call.
        case failed
    }

    public let store: TranscriptStore
    private let timeZone: TimeZone
    public private(set) var state: State = .off
    /// The most recent transcript file this recorder wrote (current call or the one before).
    public private(set) var lastURL: URL?
    private var start: Date?
    private var lines: [TranscriptLine] = []
    private var labels = SpeakerLabels()

    public init(store: TranscriptStore, timeZone: TimeZone = .current) {
        self.store = store
        self.timeZone = timeZone
    }

    public var isSaving: Bool {
        if case .saving = state { return true }
        return false
    }

    public var keptLineCount: Int { lines.count }

    /// A call started. `folder` nil = saving off.
    public func begin(start: Date, folder: URL?, labels: SpeakerLabels) {
        end()
        state = .off
        guard let folder else { return }
        self.start = start
        self.labels = labels
        do {
            try store.prepare(folder: folder)
            let url = uniqueURL(in: folder, start: start)
            try store.write(render(), to: url)
            state = .saving(url)
            lastURL = url
        } catch {
            fail()
        }
    }

    public func add(_ line: TranscriptLine) {
        guard isSaving else { return }
        lines.append(line)
        flush()
    }

    public func relabel(_ labels: SpeakerLabels) {
        guard isSaving else { return }
        self.labels = labels
        flush()
    }

    /// Writes the last lines (if saving) and forgets the call.
    public func end() {
        if case .saving(let url) = state { state = .saved(url) }
        if state == .failed || state == .deleted { state = .off }
        lines.removeAll()
        start = nil
        labels.reset()
    }

    /// Deletes the current call's file, or else the last one written. Deleting during a call stops
    /// saving for the rest of it. Returns false when there is nothing to delete.
    @discardableResult
    public func deleteCurrentOrLast() throws -> Bool {
        guard let url = lastURL else { return false }
        let during = isSaving
        if store.exists(url) { try store.remove(url) }
        lastURL = nil
        lines.removeAll()
        state = during ? .deleted : .off
        return true
    }

    private func flush() {
        guard case .saving(let url) = state else { return }
        do {
            try store.write(render(), to: url)
        } catch {
            fail()
        }
    }

    private func fail() {
        state = .failed
        lines.removeAll()
    }

    private func render() -> String {
        TranscriptFormat.markdown(start: start ?? Date(), lines: lines, labels: labels, timeZone: timeZone)
    }

    private func uniqueURL(in folder: URL, start: Date) -> URL {
        let name = TranscriptFormat.fileName(start: start, timeZone: timeZone)
        var url = folder.appendingPathComponent(name)
        var n = 2
        while store.exists(url) {
            let base = (name as NSString).deletingPathExtension
            url = folder.appendingPathComponent("\(base) (\(n)).\(TranscriptFormat.fileExtension)")
            n += 1
        }
        return url
    }
}
