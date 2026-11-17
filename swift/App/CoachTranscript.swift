import AppKit
import ListenMoreCore
import MeetingCardCore

/// Live captions and saved transcripts (both off by default; both need a key OpenAI accepts, since
/// they read the GPT cues' transcription). Takes the coach service's call and caption events into
/// `LiveTranscript` and publishes what the card shows in `feed` (a `CaptionFeedModel` for
/// `CaptionFeedView`; no window of its own), and stores four settings in UserDefaults (never call
/// data). Caption text lives in memory; with saving on, the Kit's `FileTranscriptStore` writes the
/// call's one Markdown file in the chosen folder.
@MainActor
final class CoachTranscript {
    enum Keys {
        static let captions = "coach.captions"
        static let saveTranscripts = "coach.saveTranscripts"
        static let transcriptFolder = "coach.transcriptFolder"
        static let noticeSeen = "coach.transcriptNoticeSeen"
    }

    let defaults: UserDefaults
    let live: LiveTranscript
    /// What the card's caption feed shows; the coach card hosts `CaptionFeedView(model: feed)`.
    let feed = CaptionFeedModel()
    /// The per-call cost meter's latest reading (nil until the first billed segment).
    private(set) var meter: CostReading?

    init(defaults: UserDefaults, store: TranscriptStore = FileTranscriptStore()) {
        self.defaults = defaults
        live = LiveTranscript(settings: .init(folder: FileTranscriptStore.defaultFolder()), store: store,
                              captions: CaptionBuffer(maxLines: Theme.Captions.visibleLines), labels: Self.speakerLabels)
        live.update(settings(keyUsable: false))
    }

    // MARK: settings

    var captionsOn: Bool { defaults.bool(forKey: Keys.captions) }
    var savingOn: Bool { defaults.bool(forKey: Keys.saveTranscripts) }
    var noticeSeen: Bool { defaults.bool(forKey: Keys.noticeSeen) }
    var folder: URL {
        defaults.string(forKey: Keys.transcriptFolder).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileTranscriptStore.defaultFolder()
    }

    func settings(keyUsable: Bool) -> LiveTranscript.Settings {
        .init(captions: captionsOn, saving: savingOn, folder: folder, keyUsable: keyUsable)
    }

    func setCaptions(_ on: Bool, keyUsable: Bool) {
        defaults.set(on, forKey: Keys.captions)
        sync(keyUsable: keyUsable)
    }

    func setSaving(_ on: Bool, keyUsable: Bool) {
        defaults.set(on, forKey: Keys.saveTranscripts)
        sync(keyUsable: keyUsable)
    }

    /// nil restores the default folder. The app isn't sandboxed, so a plain path is enough (no
    /// security-scoped bookmark). Takes effect for the next call's file.
    func setFolder(_ url: URL?, keyUsable: Bool) {
        if let url { defaults.set(url.path, forKey: Keys.transcriptFolder) } else { defaults.removeObject(forKey: Keys.transcriptFolder) }
        sync(keyUsable: keyUsable)
    }

    func markNoticeSeen() { defaults.set(true, forKey: Keys.noticeSeen) }

    /// Keeps the live settings in step with the stored ones and the key (each coach refresh).
    func sync(keyUsable: Bool) {
        let s = settings(keyUsable: keyUsable)
        if s != live.settings { live.update(s) }
        render()
    }

    // MARK: coach events

    func callStarted() {
        meter = nil
        live.callStarted()
        render()
    }

    func callEnded() {
        live.callEnded()
        render()
    }

    func receive(_ event: CaptionEvent) {
        live.receive(event)
        render()
    }

    func record(_ reading: CostReading) { meter = reading }

    func gptStopped(_ reason: GptStopReason) {
        guard live.inCall, live.gptStop == nil else { return }
        live.gptStopped(reason)
        render()
    }

    func rename(_ speaker: Speaker, to tag: String?) {
        live.rename(speaker, to: tag)
        render()
    }

    @discardableResult
    func deleteTranscript() -> Bool {
        defer { render() }
        return (try? live.deleteTranscript()) ?? false
    }

    var canDelete: Bool { live.recorder.lastURL != nil }

    // MARK: feed

    /// You and Them in MeetingCard's copy.
    static let speakerLabels = SpeakerLabels(defaults: [.me: CoachCopy.captionsYou, .others: CoachCopy.captionsThem])

    /// The feed for the current state. While captions show (live or stopped at the cap): the
    /// header, the lines or the placeholder (or the stopped note), and the footnote, which says a
    /// transcript is being saved only while the Save transcripts switch is on. The saving indicator
    /// shows while the file is being written, with or without captions.
    static func update(_ feed: CaptionFeedModel, from live: LiveTranscript) {
        var header: String?
        var lines: [CaptionFeedModel.Line] = []
        var note: String?
        var placeholder: String?
        var footnote: String?
        let footer = live.settings.saving ? CoachCopy.captionsNoteSaving : CoachCopy.captionsNote
        switch live.captionState {
        case .live:
            header = CoachCopy.captionsHeader
            lines = live.captions.lines.compactMap { c in
                let text = c.text
                return text.isEmpty ? nil : .init(speaker: live.labels.label(c.speaker), text: text, own: c.speaker == .me)
            }
            if lines.isEmpty { placeholder = CoachCopy.captionsEmpty }
            footnote = footer
        case .stopped(let reason):
            header = CoachCopy.captionsHeader
            switch reason {
            case .budgetCap: note = CoachCopy.captionsStopped
            case .error: note = CoachCopy.captionsStoppedError
            }
            footnote = footer
        case .off, .unavailable, .waiting: break
        }
        let saving = live.recorder.isSaving ? CoachCopy.savingNow : nil
        if feed.header != header { feed.header = header }
        if feed.lines != lines { feed.lines = lines }
        if feed.note != note { feed.note = note }
        if feed.placeholder != placeholder { feed.placeholder = placeholder }
        if feed.footnote != footnote { feed.footnote = footnote }
        if feed.savingLabel != saving { feed.savingLabel = saving }
    }

    func render() { Self.update(feed, from: live) }

    // MARK: style

    /// A CardStyle text role as a color that follows the appearance it is drawn in.
    static func color(_ role: CardStyle.Text) -> NSColor {
        switch role {
        case .primary, .secondary, .tertiary, .critical:
            return Theme.text(role, Theme.style(dark: false))
        case .accent, .warning:
            return NSColor(name: nil) { Theme.text(role, Theme.style(dark: isDark($0))) }
        }
    }

    static func color(_ token: @escaping (CardStyle) -> RGBA) -> NSColor {
        NSColor(name: nil) { Theme.ns(token(Theme.style(dark: isDark($0)))) }
    }

    nonisolated static func isDark(_ a: NSAppearance) -> Bool { a.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua }

    /// The cost meter's line for Settings.
    func costLine() -> String {
        guard let m = meter else { return CoachCopy.costNone }
        func usd(_ v: Double) -> String { String(format: "$%.3f", v) }
        let cap = m.budgetUsd.map { usd($0) } ?? "-"
        return String(format: CoachCopy.costLine, usd(m.totalUsd), cap, usd(m.transcribeUsd), usd(m.judgeUsd), usd(m.transcriptUsd))
    }
}
