import Foundation

/// What the coach is doing to the call's audio right now, as the transcript marks it. The host reads
/// these off its session; each change opens or closes a gap in the saved note.
public struct CallConditions: Equatable, Sendable {
    /// The coach's own Mute: no You text.
    public var youMuted: Bool
    public var paused: Bool
    /// The call app reports the user muted (capture held).
    public var appMuted: Bool
    public var transcriberRetrying: Bool
    public var callAudioReconnecting: Bool

    public init(youMuted: Bool = false, paused: Bool = false, appMuted: Bool = false,
                transcriberRetrying: Bool = false, callAudioReconnecting: Bool = false) {
        self.youMuted = youMuted
        self.paused = paused
        self.appMuted = appMuted
        self.transcriberRetrying = transcriberRetrying
        self.callAudioReconnecting = callAudioReconnecting
    }

    /// Each gap kind these conditions cover, in a fixed order, and whether it is open.
    var open: [(GapKind, Bool)] {
        [(.youMuted, youMuted), (.paused, paused), (.appMuted, appMuted),
         (.transcriberRetrying, transcriberRetrying), (.callAudioReconnecting, callAudioReconnecting)]
    }
}

/// Captions and the saved transcript for one host, driven from the main thread: call start and end
/// from the coach session, caption events from the GPT layer, the session's conditions and cues, and
/// the user's settings. Both features are off by default and need a usable key (they read the cue
/// transcription; without a key there is none). Captions live in a small in-memory buffer. With
/// saving off nothing else is kept; with saving on the `TranscriptRecorder` writes the call's note.
/// When the GPT layer stops (cost cap or error) captions stop and the note marks where text stopped;
/// the local cues are unaffected.
public final class LiveTranscript {
    public struct Settings: Equatable, Sendable {
        public var captions: Bool
        public var saving: Bool
        public var folder: URL
        public var keyUsable: Bool
        public var note: NoteOptions

        public init(captions: Bool = false, saving: Bool = false, folder: URL, keyUsable: Bool = false,
                    note: NoteOptions = NoteOptions()) {
            self.captions = captions
            self.saving = saving
            self.folder = folder
            self.keyUsable = keyUsable
            self.note = note
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
    public private(set) var labels: SpeakerLabels
    public private(set) var callStart: Date?
    public private(set) var gptStop: GptStopReason?
    /// The host's details for the current or next call (title, app, transcriber). Reset at call end.
    public private(set) var callInfo = CallInfo()
    public private(set) var conditions = CallConditions()
    private let clock: () -> Date
    /// When each speaker's unfinished turns started (turns finish in order), so a line carries its start time.
    private var turnStarts: [Speaker: [(item: String, at: TimeInterval)]] = [:]

    /// `labels`: the host's wording for You and Them (tags reset at call end, these stay).
    public init(settings: Settings, store: TranscriptStore, captions: CaptionBuffer = CaptionBuffer(),
                labels: SpeakerLabels = SpeakerLabels(), timeZone: TimeZone = .current, wording: NoteWording = NoteWording(),
                io: TranscriptIO = .inline, clock: @escaping () -> Date = Date.init) {
        self.settings = settings
        self.captions = captions
        self.labels = labels
        recorder = TranscriptRecorder(store: store, timeZone: timeZone, wording: wording, io: io)
        self.clock = clock
    }

    public var captionState: CaptionState {
        guard settings.captions else { return .off }
        guard settings.keyUsable else { return .unavailable }
        if let gptStop { return .stopped(gptStop) }
        return callStart == nil ? .waiting : .live
    }

    /// Lines the caption feed shows now (none unless captions are live).
    public var visibleLines: [CaptionLine] { captionState == .live ? captions.lines : [] }

    public var inCall: Bool { callStart != nil }

    private var wantSaving: Bool { settings.saving && settings.keyUsable }

    private var now: TimeInterval {
        callStart.map { max(0, clock().timeIntervalSince($0)) } ?? 0
    }

    // MARK: call

    public func callStarted() {
        callEnded(keepingInfo: true)
        callStart = clock()
        gptStop = nil
        beginNote()
    }

    /// Drops the captions and the speaker tags, and finishes the transcript note.
    public func callEnded() {
        callEnded(keepingInfo: false)
    }

    private func callEnded(keepingInfo: Bool) {
        let t = now
        callStart = nil
        gptStop = nil
        captions.clear()
        turnStarts.removeAll()
        labels.reset()
        recorder.end(at: t)
        if !keepingInfo { callInfo = CallInfo() }
    }

    /// The host's call details; before the call they apply when it starts, during it they update the note.
    public func setCallInfo(_ info: CallInfo) {
        callInfo = info
        recorder.setInfo(info)
    }

    public func receive(_ event: CaptionEvent) {
        guard callStart != nil, gptStop == nil, settings.keyUsable else { return }
        let t = now
        if settings.captions { captions.apply(event, at: t) }
        switch event {
        case let .partial(speaker, item, _):
            if !(turnStarts[speaker] ?? []).contains(where: { $0.item == item }) {
                turnStarts[speaker, default: []].append((item, t))
            }
        case let .final(speaker, text):
            let started = turnStarts[speaker]?.isEmpty == false ? turnStarts[speaker]?.removeFirst().at : nil
            let said = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if !said.isEmpty { recorder.add(TranscriptLine(speaker: speaker, offset: started ?? t, text: said)) }
        }
    }

    /// The session's conditions now (the host calls this on every change; repeats do nothing).
    public func observe(_ new: CallConditions) {
        let old = conditions
        conditions = new
        guard inCall, old != new else { return }
        let t = now
        for ((kind, open), (_, was)) in zip(new.open, old.open) where open != was {
            recorder.gap(kind, open: open, at: t)
        }
    }

    /// A coaching cue was shown.
    public func cue(_ type: CueType) {
        guard inCall else { return }
        recorder.cue(type.rawValue, at: now)
    }

    /// The GPT layer turned itself off: no more text this call. The note stays open until the call ends.
    public func gptStopped(_ reason: GptStopReason) {
        guard inCall, gptStop == nil else { return }
        gptStop = reason
        captions.clear()
        turnStarts.removeAll()
        recorder.gap(.transcriberStopped, open: true, at: now, detail: reason.rawValue)
    }

    // MARK: user actions

    /// Captions turned off mid-call drop what the strip held; saving turned off finishes the note;
    /// saving turned on mid-call starts the note from now (earlier lines were never kept).
    public func update(_ new: Settings) {
        let wasSaving = wantSaving
        settings = new
        if !new.captions || !new.keyUsable { captions.clear() }
        if !wantSaving && recorder.isSaving { recorder.end(at: now) }
        if wantSaving && !wasSaving, callStart != nil, gptStop == nil {
            beginNote()
        }
    }

    /// Tags a speaker for this call only (also relabels the saved note, if one is being written).
    public func rename(_ speaker: Speaker, to tag: String?) {
        guard inCall else { return }
        labels.rename(speaker, to: tag)
        recorder.relabel(labels)
    }

    @discardableResult
    public func deleteTranscript() throws -> Bool {
        try recorder.deleteCurrentOrLast()
    }

    private func beginNote() {
        guard let start = callStart else { return }
        recorder.begin(start: start, folder: wantSaving ? settings.folder : nil, labels: labels, info: callInfo, options: settings.note)
        let t = now
        for (kind, open) in conditions.open where open { recorder.gap(kind, open: true, at: t) }
    }
}
