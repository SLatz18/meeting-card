import Foundation

/// What the Settings group shows for saved transcripts as Obsidian notes, as plain values, so a
/// hostless test can snapshot it. The App draws one control per row (`CoachNoteSettingsRows`).
public struct TranscriptSettingsRows: Equatable {
    public struct Input: Equatable {
        public var folderPath: String
        /// The vault folder's name when the folder is in one.
        public var vaultName: String?
        public var keyUsable: Bool
        public var fileNamePattern: String
        public var tags: String
        public var dailyNoteOn: Bool
        public var dailyNotePath: String
        public var dailyNoteEmbed: Bool
        public var retentionDays: Int?
        public var canDelete: Bool

        public init(folderPath: String, vaultName: String? = nil, keyUsable: Bool, fileNamePattern: String, tags: String,
                    dailyNoteOn: Bool = false, dailyNotePath: String, dailyNoteEmbed: Bool = false, retentionDays: Int? = nil,
                    canDelete: Bool = false) {
            self.folderPath = folderPath
            self.vaultName = vaultName
            self.keyUsable = keyUsable
            self.fileNamePattern = fileNamePattern
            self.tags = tags
            self.dailyNoteOn = dailyNoteOn
            self.dailyNotePath = dailyNotePath
            self.dailyNoteEmbed = dailyNoteEmbed
            self.retentionDays = retentionDays
            self.canDelete = canDelete
        }
    }

    public enum Control: Equatable {
        case folder(path: String, button: String)
        case note(String)
        case field(label: String, value: String)
        case toggle(label: String, on: Bool)
        case choice(label: String, choices: [String], selected: Int)
        case button(String)
    }

    public struct Row: Equatable {
        public var id: String
        public var control: Control
        public var enabled: Bool
        public var hidden: Bool
    }

    /// The retention choices, in menu order; nil is Forever (the default).
    public static let retentionChoices: [Int?] = [nil, 7, 30, 90, 365]

    public let rows: [Row]

    public init(_ i: Input, chooseFolder: String) {
        let on = i.keyUsable
        let styles = [TranscriptCopy.dailyNoteLink, TranscriptCopy.dailyNoteEmbed]
        let retention = Self.retentionChoices.firstIndex { $0 == i.retentionDays } ?? 0
        rows = [
            Row(id: "folder", control: .folder(path: i.folderPath, button: chooseFolder), enabled: on, hidden: false),
            Row(id: "vault", control: .note(TranscriptCopy.vaultStatus(i.vaultName)), enabled: true, hidden: false),
            Row(id: "fileName", control: .field(label: TranscriptCopy.fileNameLabel, value: i.fileNamePattern), enabled: on, hidden: false),
            Row(id: "fileNameHelp", control: .note(TranscriptCopy.fileNameHelp), enabled: true, hidden: false),
            Row(id: "tags", control: .field(label: TranscriptCopy.tagsLabel, value: i.tags), enabled: on, hidden: false),
            Row(id: "tagsHelp", control: .note(TranscriptCopy.tagsHelp), enabled: true, hidden: false),
            Row(id: "dailyNote", control: .toggle(label: TranscriptCopy.dailyNoteToggle, on: i.dailyNoteOn), enabled: on, hidden: false),
            Row(id: "dailyNoteHelp", control: .note(TranscriptCopy.dailyNoteHelp), enabled: true, hidden: false),
            Row(id: "dailyNotePath", control: .field(label: TranscriptCopy.dailyNotePathLabel, value: i.dailyNotePath),
                enabled: on, hidden: !i.dailyNoteOn),
            Row(id: "dailyNoteStyle", control: .choice(label: TranscriptCopy.dailyNoteStyleLabel, choices: styles,
                                                       selected: i.dailyNoteEmbed ? 1 : 0),
                enabled: on, hidden: !i.dailyNoteOn),
            Row(id: "retention", control: .choice(label: TranscriptCopy.retentionLabel,
                                                  choices: Self.retentionChoices.map(TranscriptCopy.retention), selected: retention),
                enabled: on, hidden: false),
            Row(id: "retentionHelp", control: .note(TranscriptCopy.retentionHelp), enabled: true, hidden: false),
            Row(id: "delete", control: .button(TranscriptCopy.deleteThisCall), enabled: true, hidden: !i.canDelete),
        ]
    }

    public func row(_ id: String) -> Row? { rows.first { $0.id == id } }

    /// One line per visible row, for snapshot tests: `[id] text` with `(off)` for a disabled control.
    public var snapshot: String {
        rows.filter { !$0.hidden }.map { r in
            let text: String
            switch r.control {
            case let .folder(path, button): text = "\(TranscriptCopy.saveTo): \(path) [\(button)]"
            case let .note(s): text = s
            case let .field(label, value): text = "\(label): [\(value)]"
            case let .toggle(label, on): text = "\(label): \(on ? "on" : "off")"
            case let .choice(label, choices, selected): text = "\(label): <\(choices[selected])> of \(choices.joined(separator: " | "))"
            case let .button(title): text = "[\(title)]"
            }
            return "[\(r.id)] \(text)\(r.enabled ? "" : " (off)")"
        }.joined(separator: "\n")
    }
}
