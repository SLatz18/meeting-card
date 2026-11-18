import AppKit
import ListenMoreCore
import MeetingCardCore

/// Live captions and saved transcripts (both off by default; both need a key OpenAI accepts, since
/// they read the GPT cues' transcription). Takes the coach service's call, caption, cue and
/// condition events into `LiveTranscript` and publishes what the card shows in `feed` (a
/// `CaptionFeedModel` for `CaptionFeedView`; no window of its own), and stores its settings in
/// UserDefaults (never call data; the note options are `CoachNoteSettings`). Caption text lives in
/// memory; with saving on, the Kit's `FileTranscriptStore` writes the call's Obsidian-ready note in
/// the chosen folder, on a serial queue off the main thread.
@MainActor
final class CoachTranscript {
    enum Keys {
        static let captions = "coach.captions"
        static let saveTranscripts = "coach.saveTranscripts"
        static let transcriptFolder = "coach.transcriptFolder"
        static let transcriptFolderBookmark = "coach.transcriptFolderBookmark"
        static let noticeSeen = "coach.transcriptNoticeSeen"
    }

    let defaults: UserDefaults
    let live: LiveTranscript
    let note: CoachNoteSettings
    /// What the card's caption feed shows; the coach card hosts `CaptionFeedView(model: feed)`.
    let feed = CaptionFeedModel()
    /// The per-call cost meter's latest reading (nil until the first billed segment).
    private(set) var meter: CostReading?
    private var resolvedFolder: URL?

    init(defaults: UserDefaults, store: TranscriptStore = FileTranscriptStore()) {
        self.defaults = defaults
        note = CoachNoteSettings(defaults: defaults)
        live = LiveTranscript(settings: .init(folder: Self.defaultFolder), store: store,
                              captions: CaptionBuffer(maxLines: Theme.Captions.visibleLines), labels: Self.speakerLabels,
                              io: .serial(label: AppIdentity.current.scoped("transcript")))
        live.update(settings(keyUsable: false))
        maintain()
    }

    // MARK: settings

    var captionsOn: Bool { defaults.bool(forKey: Keys.captions) }
    var savingOn: Bool { defaults.bool(forKey: Keys.saveTranscripts) }
    var noticeSeen: Bool { defaults.bool(forKey: Keys.noticeSeen) }
    /// This identity's default transcripts folder, so a `--test-id` build saves apart from the shipping app.
    static var defaultFolder: URL { AppPaths.transcripts(for: .current) }

    /// The app isn't sandboxed, so this needs no entitlement: a sandboxed build would need
    /// `com.apple.security.files.user-selected.read-write` and `com.apple.security.files.bookmarks.app-scope`.
    static var isSandboxed: Bool { ProcessInfo.processInfo.environment["APP_SANDBOX_CONTAINER_ID"] != nil }

    /// The chosen folder, through its bookmark (so it follows a rename or move), else its stored
    /// path, else the default. Resolved once and kept until the user picks another.
    var folder: URL {
        if let resolvedFolder { return resolvedFolder }
        let url = resolveBookmark()
            ?? defaults.string(forKey: Keys.transcriptFolder).map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? Self.defaultFolder
        resolvedFolder = url
        return url
    }

    private func resolveBookmark() -> URL? {
        guard let data = defaults.data(forKey: Keys.transcriptFolderBookmark) else { return nil }
        var stale = false
        let scoped = Self.isSandboxed
        guard let url = try? URL(resolvingBookmarkData: data, options: scoped ? [.withSecurityScope] : [],
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else { return nil }
        if scoped { _ = url.startAccessingSecurityScopedResource() }
        if stale { storeBookmark(url) }
        return url
    }

    private func storeBookmark(_ url: URL) {
        let options: URL.BookmarkCreationOptions = Self.isSandboxed ? [.withSecurityScope] : []
        if let data = try? url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil) {
            defaults.set(data, forKey: Keys.transcriptFolderBookmark)
        } else {
            defaults.removeObject(forKey: Keys.transcriptFolderBookmark)
        }
        defaults.set(url.path, forKey: Keys.transcriptFolder)
    }

    /// The Obsidian vault the folder is in (its name), if any.
    func vaultName() -> String? {
        ObsidianVault.root(containing: folder, store: live.recorder.store)?.lastPathComponent
    }

    func settings(keyUsable: Bool) -> LiveTranscript.Settings {
        .init(captions: captionsOn, saving: savingOn, folder: folder, keyUsable: keyUsable, note: note.options)
    }

    func setCaptions(_ on: Bool, keyUsable: Bool) {
        defaults.set(on, forKey: Keys.captions)
        sync(keyUsable: keyUsable)
    }

    func setSaving(_ on: Bool, keyUsable: Bool) {
        defaults.set(on, forKey: Keys.saveTranscripts)
        sync(keyUsable: keyUsable)
    }

    /// nil restores the default folder. Kept as a bookmark plus its path. Takes effect for the next
    /// call's note; notes already saved stay where they are.
    func setFolder(_ url: URL?, keyUsable: Bool) {
        if let url {
            storeBookmark(url)
        } else {
            defaults.removeObject(forKey: Keys.transcriptFolder)
            defaults.removeObject(forKey: Keys.transcriptFolderBookmark)
        }
        resolvedFolder = nil
        sync(keyUsable: keyUsable)
        maintain()
    }

    func markNoticeSeen() { defaults.set(true, forKey: Keys.noticeSeen) }

    /// Keeps the live settings in step with the stored ones and the key (each coach refresh).
    func sync(keyUsable: Bool) {
        let s = settings(keyUsable: keyUsable)
        if s != live.settings { live.update(s) }
        render()
    }

    /// Recovery (notes of calls the app quit during) and the opt-in retention, in the folder, queued
    /// behind the recorder's writes so they never touch the call being saved.
    func maintain() {
        live.recorder.maintain(folder: folder, retentionDays: note.retentionDays, labels: Self.speakerLabels)
    }

    /// App quit: finishes the call's note now, then waits for the writes.
    func finishForQuit() {
        live.callEnded()
        live.recorder.flush()
    }

    // MARK: coach events

    func callStarted(info: CallInfo = CallInfo()) {
        meter = nil
        live.setCallInfo(info)
        live.callStarted()
        render()
    }

    func callEnded() {
        live.callEnded()
        if note.retentionDays != nil { maintain() }
        render()
    }

    /// The host's call details changed (the call app or the joined event's title arrived). A title
    /// or app the call already has stays, so a call that runs past its event keeps its title.
    func setCallInfo(_ info: CallInfo) {
        var merged = info
        merged.title = info.title ?? live.callInfo.title
        merged.app = info.app ?? live.callInfo.app
        if merged != live.callInfo { live.setCallInfo(merged) }
    }

    /// The session's Mute, Pause and call-app mute, marked as gaps in the saved note.
    func observe(_ conditions: CallConditions) { live.observe(conditions) }

    func cue(_ type: CueType) { live.cue(type) }

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
