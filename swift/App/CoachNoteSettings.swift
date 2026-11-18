import AppKit
import ListenMoreCore
import MeetingCardCore

/// The saved notes' options, stored in UserDefaults (settings only, never call data): the file name
/// pattern, tags, the daily-note line (off by default) and retention (off by default). The folder
/// itself is `CoachTranscript`'s.
@MainActor
final class CoachNoteSettings {
    enum Keys {
        static let fileName = "coach.transcriptFileName"
        static let tags = "coach.transcriptTags"
        static let dailyNote = "coach.transcriptDailyNote"
        static let dailyNotePath = "coach.transcriptDailyNotePath"
        static let dailyNoteEmbed = "coach.transcriptDailyNoteEmbed"
        static let retentionDays = "coach.transcriptRetentionDays"
    }

    let defaults: UserDefaults

    init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    private func text(_ key: String) -> String? {
        defaults.string(forKey: key).flatMap { $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 }
    }

    var fileNamePattern: String { text(Keys.fileName) ?? NoteFileName.defaultPattern }
    /// The raw setting; cleared by the user, it means no tags.
    var tags: String { defaults.string(forKey: Keys.tags) ?? CallNote.defaultTag }
    var dailyNoteOn: Bool { defaults.bool(forKey: Keys.dailyNote) }
    var dailyNotePath: String { text(Keys.dailyNotePath) ?? DailyNoteOptions.defaultPattern }
    var dailyNoteEmbed: Bool { defaults.bool(forKey: Keys.dailyNoteEmbed) }
    /// nil: keep forever (the default).
    var retentionDays: Int? {
        let d = defaults.integer(forKey: Keys.retentionDays)
        return d > 0 ? d : nil
    }

    var options: NoteOptions {
        NoteOptions(fileNamePattern: fileNamePattern, tags: CallNote.tags(fromSetting: tags),
                    dailyNote: dailyNoteOn ? DailyNoteOptions(pathPattern: dailyNotePath, style: dailyNoteEmbed ? .embed : .link) : nil)
    }

    func setFileNamePattern(_ s: String) { defaults.set(s, forKey: Keys.fileName) }
    func setTags(_ s: String) { defaults.set(s, forKey: Keys.tags) }
    func setDailyNote(_ on: Bool) { defaults.set(on, forKey: Keys.dailyNote) }
    func setDailyNotePath(_ s: String) { defaults.set(s, forKey: Keys.dailyNotePath) }
    func setDailyNoteEmbed(_ on: Bool) { defaults.set(on, forKey: Keys.dailyNoteEmbed) }

    func setRetentionDays(_ days: Int?) {
        if let days, days > 0 { defaults.set(days, forKey: Keys.retentionDays) } else { defaults.removeObject(forKey: Keys.retentionDays) }
    }
}

/// The Settings rows for saved notes, under the folder row of the Captions and transcript group:
/// the vault status, file name pattern, tags, the daily-note line and its path, and retention. What
/// each row shows comes from `TranscriptSettingsRows` (snapshot-tested in MeetingCardCore).
@MainActor
final class CoachNoteSettingsRows: NSObject {
    private let coach: CoachController
    private let vaultNote = CoachSettingsWindow.text("", font: Theme.Settings.helperFont, color: CoachSettingsWindow.color(.secondary))
    private let fileNameField = NSTextField()
    private let tagsField = NSTextField()
    private let dailyNoteSwitch = NSSwitch()
    private let dailyNotePathField = NSTextField()
    private let stylePopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private let retentionPopup = NSPopUpButton(frame: .zero, pullsDown: false)
    private var dailyNotePathRow = NSStackView()
    private var dailyNoteStyleRow = NSStackView()
    private var lastVault: String?
    /// The rows, in order; the window re-adds them whenever it rebuilds its groups.
    private(set) var views: [NSView] = []

    init(coach: CoachController) {
        self.coach = coach
        super.init()
        views = makeViews()
    }

    private func helper(_ s: String) -> NSTextField {
        CoachSettingsWindow.text(s, font: Theme.Settings.helperFont, color: CoachSettingsWindow.color(.secondary))
    }

    private func label(_ s: String) -> NSTextField {
        CoachSettingsWindow.text(s, font: Theme.Settings.itemFont)
    }

    private func field(_ f: NSTextField, _ name: String, _ action: Selector) {
        f.font = Theme.font(Theme.Settings.itemFont)
        f.target = self
        f.action = action
        f.cell?.sendsActionOnEndEditing = true
        f.setAccessibilityLabel(name)
        f.translatesAutoresizingMaskIntoConstraints = false
        f.widthAnchor.constraint(equalToConstant: CoachSettingsWindow.innerWidth / 2).isActive = true
    }

    private func makeViews() -> [NSView] {
        field(fileNameField, TranscriptCopy.fileNameLabel, #selector(fileNameEdited(_:)))
        field(tagsField, TranscriptCopy.tagsLabel, #selector(tagsEdited(_:)))
        field(dailyNotePathField, TranscriptCopy.dailyNotePathLabel, #selector(dailyNotePathEdited(_:)))
        dailyNoteSwitch.target = self
        dailyNoteSwitch.action = #selector(dailyNoteToggled(_:))
        dailyNoteSwitch.setAccessibilityLabel(TranscriptCopy.dailyNoteToggle)
        stylePopup.addItems(withTitles: [TranscriptCopy.dailyNoteLink, TranscriptCopy.dailyNoteEmbed])
        stylePopup.font = Theme.font(Theme.Settings.itemFont)
        stylePopup.target = self
        stylePopup.action = #selector(stylePicked(_:))
        stylePopup.setAccessibilityLabel(TranscriptCopy.dailyNoteStyleLabel)
        retentionPopup.addItems(withTitles: TranscriptSettingsRows.retentionChoices.map(TranscriptCopy.retention))
        retentionPopup.font = Theme.font(Theme.Settings.itemFont)
        retentionPopup.target = self
        retentionPopup.action = #selector(retentionPicked(_:))
        retentionPopup.setAccessibilityLabel(TranscriptCopy.retentionLabel)

        dailyNotePathRow = CoachSettingsWindow.row(label(TranscriptCopy.dailyNotePathLabel), dailyNotePathField)
        dailyNoteStyleRow = CoachSettingsWindow.row(label(TranscriptCopy.dailyNoteStyleLabel), stylePopup)
        return [
            vaultNote,
            CoachSettingsWindow.row(label(TranscriptCopy.fileNameLabel), fileNameField),
            helper(TranscriptCopy.fileNameHelp),
            CoachSettingsWindow.row(label(TranscriptCopy.tagsLabel), tagsField),
            helper(TranscriptCopy.tagsHelp),
            CoachSettingsWindow.row(label(TranscriptCopy.dailyNoteToggle), dailyNoteSwitch),
            helper(TranscriptCopy.dailyNoteHelp),
            dailyNotePathRow,
            dailyNoteStyleRow,
            CoachSettingsWindow.row(label(TranscriptCopy.retentionLabel), retentionPopup),
            helper(TranscriptCopy.retentionHelp),
        ]
    }

    /// Shows the stored settings. The vault is looked up only while the window is visible; a field
    /// being edited keeps what the user is typing.
    func update(visible: Bool) {
        let t = coach.transcript
        if visible { lastVault = t.vaultName() }
        let n = t.note
        let rows = TranscriptSettingsRows(.init(folderPath: (t.folder.path as NSString).abbreviatingWithTildeInPath, vaultName: lastVault,
                                                keyUsable: coach.transcriptKeyUsable, fileNamePattern: n.fileNamePattern,
                                                tags: n.tags, dailyNoteOn: n.dailyNoteOn, dailyNotePath: n.dailyNotePath,
                                                dailyNoteEmbed: n.dailyNoteEmbed, retentionDays: n.retentionDays,
                                                canDelete: t.canDelete), chooseFolder: CoachCopy.chooseFolder)
        for r in rows.rows {
            switch r.control {
            case let .note(s) where r.id == "vault":
                vaultNote.stringValue = s
            case let .field(_, value):
                let f = ["fileName": fileNameField, "tags": tagsField, "dailyNotePath": dailyNotePathField][r.id]
                if let f {
                    if f.currentEditor() == nil { f.stringValue = value }
                    f.isEnabled = r.enabled
                }
                if r.id == "dailyNotePath" { dailyNotePathRow.isHidden = r.hidden }
            case let .toggle(_, on):
                dailyNoteSwitch.state = on ? .on : .off
                dailyNoteSwitch.isEnabled = r.enabled
            case let .choice(_, _, selected):
                let popup = r.id == "dailyNoteStyle" ? stylePopup : retentionPopup
                popup.selectItem(at: selected)
                popup.isEnabled = r.enabled
                if r.id == "dailyNoteStyle" { dailyNoteStyleRow.isHidden = r.hidden }
            case .folder, .note, .button:
                break
            }
        }
    }

    private func changed() {
        coach.transcript.sync(keyUsable: coach.transcriptKeyUsable)
        coach.settingsWindow?.update()
    }

    @objc private func fileNameEdited(_ sender: NSTextField) {
        coach.transcript.note.setFileNamePattern(sender.stringValue)
        changed()
    }

    @objc private func tagsEdited(_ sender: NSTextField) {
        coach.transcript.note.setTags(sender.stringValue)
        changed()
    }

    @objc private func dailyNoteToggled(_ sender: NSSwitch) {
        coach.transcript.note.setDailyNote(sender.state == .on)
        changed()
    }

    @objc private func dailyNotePathEdited(_ sender: NSTextField) {
        coach.transcript.note.setDailyNotePath(sender.stringValue)
        changed()
    }

    @objc private func stylePicked(_ sender: NSPopUpButton) {
        coach.transcript.note.setDailyNoteEmbed(sender.indexOfSelectedItem == 1)
        changed()
    }

    @objc private func retentionPicked(_ sender: NSPopUpButton) {
        let all = TranscriptSettingsRows.retentionChoices
        guard all.indices.contains(sender.indexOfSelectedItem) else { return }
        coach.transcript.note.setRetentionDays(all[sender.indexOfSelectedItem])
        coach.transcript.maintain()
        changed()
    }
}
