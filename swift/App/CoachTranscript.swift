import AppKit
import ListenMoreCore
import ListenMoreMac
import MeetingCardCore

/// Live captions and saved transcripts (both off by default; both need a key OpenAI accepts, since
/// they read the GPT cues' transcription). Takes the coach service's call and caption events into
/// `LiveTranscript`, shows the caption strip and the saving indicator on the call's display, and
/// stores four settings in UserDefaults (never call data). Caption text lives in memory; with saving
/// on, the Kit's `FileTranscriptStore` writes the call's one Markdown file in the chosen folder.
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
    /// The call's display (CoachService.callScreen, via CallDisplayLocator).
    var screen: () -> NSRect? = { nil }
    /// The per-call cost meter's latest reading (nil until the first billed segment).
    private(set) var meter: CostReading?
    private var panel: CaptionPanelController?

    init(defaults: UserDefaults, store: TranscriptStore = FileTranscriptStore()) {
        self.defaults = defaults
        live = LiveTranscript(settings: .init(folder: FileTranscriptStore.defaultFolder()), store: store,
                              captions: CaptionBuffer(maxLines: Theme.Captions.visibleLines))
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

    // MARK: strip

    var content: CaptionContent { Self.content(live) }

    static func content(_ live: LiveTranscript) -> CaptionContent {
        var c = CaptionContent()
        switch live.captionState {
        case .live: c.lines = CaptionContent.rows(live.captions.lines, labels: live.labels)
        case .stopped(let reason):
            switch reason {
            case .budgetCap: c.note = CoachCopy.captionsStopped
            case .error: c.note = CoachCopy.captionsStoppedError
            }
        case .off, .unavailable, .waiting: break
        }
        if live.recorder.isSaving { c.saving = CoachCopy.savingNow }
        return c
    }

    func render() {
        let c = content
        guard !c.isEmpty else {
            panel?.hide()
            return
        }
        let p = panel ?? CaptionPanelController(style: Self.captionStyle())
        panel = p
        p.screen = screen
        p.show(c)
    }

    var stripVisible: Bool { panel?.isVisible ?? false }

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

    /// The Kit's caption style from MeetingCard's card tokens (Theme.Captions).
    static func captionStyle() -> CaptionStyle {
        let c = Theme.Captions.self
        return CaptionStyle(
            width: Theme.cg(c.width), radius: Theme.cg(c.radius), padding: NSSize(width: c.padding.h, height: c.padding.v),
            lineGap: Theme.cg(c.lineGap), speakerGap: Theme.cg(c.speakerGap),
            surface: color(c.surface(style:)), textColor: color(c.text), speakerColor: color(c.speaker),
            ownSpeakerColor: color(c.ownSpeaker), noteColor: color(c.note),
            textFont: Theme.font(c.textFont), speakerFont: Theme.font(c.speakerFont), noteFont: Theme.font(c.noteFont),
            indicatorHeight: Theme.cg(c.indicatorHeight), indicatorRadius: Theme.cg(c.indicatorRadius),
            indicatorPadding: Theme.cg(c.indicatorPadding), indicatorFont: Theme.font(c.indicatorFont),
            hairline: color(c.hairline(style:)), hairlineWidth: Theme.cg(c.hairlineWidth),
            dot: color(c.dot(style:)), dotDiameter: Theme.cg(c.dotDiameter),
            stackGap: Theme.cg(c.stackGap), margin: Theme.cg(c.margin), trailingReserve: Theme.cg(c.trailingReserve))
    }

    /// The cost meter's line for Settings.
    func costLine() -> String {
        guard let m = meter else { return CoachCopy.costNone }
        func usd(_ v: Double) -> String { String(format: "$%.3f", v) }
        let cap = m.budgetUsd.map { usd($0) } ?? "-"
        return String(format: CoachCopy.costLine, usd(m.totalUsd), cap, usd(m.transcribeUsd), usd(m.judgeUsd), usd(m.transcriptUsd))
    }
}
