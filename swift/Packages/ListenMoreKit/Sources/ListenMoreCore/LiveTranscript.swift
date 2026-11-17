import Foundation

/// Captions and the saved transcript for one host, driven from the main thread: call start and end
/// from the coach session, caption events from the GPT layer, and the user's settings. Both
/// features are off by default and need a usable key (they read the cue transcription; without a
/// key there is none). Captions live in a small in-memory buffer. With saving off nothing else is
/// kept; with saving on the `TranscriptRecorder` writes the call's one file. When the GPT layer stops
/// (cost cap or error) captions stop and saving finishes; the local cues are unaffected.
public final class LiveTranscript {
    public struct Settings: Equatable, Sendable {
        public var captions: Bool
        public var saving: Bool
        public var folder: URL
        public var keyUsable: Bool

        public init(captions: Bool = false, saving: Bool = false, folder: URL, keyUsable: Bool = false) {
            self.captions = captions
            self.saving = saving
            self.folder = folder
            self.keyUsable = keyUsable
        }
    }

    public enum CaptionState: Equatable, Sendable {
        case off
        /// Turned on, but there is no usable key.
        case unavailable
        /// On, no call yet.
        case waiting
        case live
        /// The GPT layer stopped for this call (cost cap or error).
        case stopped(GptStopReason)
    }

    public var settings: Settings
    public let recorder: TranscriptRecorder
    public private(set) var captions: CaptionBuffer
    public private(set) var labels = SpeakerLabels()
    public private(set) var callStart: Date?
    public private(set) var gptStop: GptStopReason?
    private let clock: () -> Date

    public init(settings: Settings, store: TranscriptStore, captions: CaptionBuffer = CaptionBuffer(),
                timeZone: TimeZone = .current, clock: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.captions = captions
        recorder = TranscriptRecorder(store: store, timeZone: timeZone)
        self.clock = clock
    }

    public var captionState: CaptionState {
        guard settings.captions else { return .off }
        guard settings.keyUsable else { return .unavailable }
        if let gptStop { return .stopped(gptStop) }
        return callStart == nil ? .waiting : .live
    }

    /// Lines the caption strip shows now (none unless captions are live).
    public var visibleLines: [CaptionLine] { captionState == .live ? captions.lines : [] }

    public var inCall: Bool { callStart != nil }

    // MARK: call

    public func callStarted() {
        callEnded()
        let now = clock()
        callStart = now
        gptStop = nil
        recorder.begin(start: now, folder: settings.saving && settings.keyUsable ? settings.folder : nil, labels: labels)
    }

    /// Drops the captions and the speaker tags, and finishes the transcript file.
    public func callEnded() {
        callStart = nil
        captions.clear()
        labels.reset()
        recorder.end()
    }

    public func receive(_ event: CaptionEvent) {
        guard let start = callStart, gptStop == nil, settings.keyUsable else { return }
        let offset = clock().timeIntervalSince(start)
        if settings.captions { captions.apply(event, at: offset) }
        if case let .final(speaker, text) = event {
            let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !said.isEmpty { recorder.add(TranscriptLine(speaker: speaker, offset: offset, text: said)) }
        }
    }

    /// The GPT layer turned itself off: no more text this call.
    public func gptStopped(_ reason: GptStopReason) {
        guard inCall, gptStop == nil else { return }
        gptStop = reason
        captions.clear()
        recorder.end()
    }

    // MARK: user actions

    /// Captions turned off mid-call drop what the strip held; saving turned off finishes the file;
    /// saving turned on mid-call starts the file from now (earlier lines were never kept).
    public func update(_ new: Settings) {
        let old = settings
        settings = new
        if !new.captions || !new.keyUsable { captions.clear() }
        let wantSaving = new.saving && new.keyUsable
        if !wantSaving && recorder.isSaving { recorder.end() }
        let wasSaving = old.saving && old.keyUsable
        if wantSaving && !wasSaving, let start = callStart, gptStop == nil {
            recorder.begin(start: start, folder: new.folder, labels: labels)
        }
    }

    /// Tags a speaker for this call only (also relabels the saved file, if one is being written).
    public func rename(_ speaker: Speaker, to tag: String?) {
        guard inCall else { return }
        labels.rename(speaker, to: tag)
        recorder.relabel(labels)
    }

    @discardableResult
    public func deleteTranscript() throws -> Bool {
        try recorder.deleteCurrentOrLast()
    }
}
