import XCTest
@testable import MeetingCardCore

/// How the App wires saved transcripts as Obsidian notes (hostless tests can't load AppKit, so these
/// read the sources): what reaches the note, the folder's bookmark without new entitlements,
/// upkeep and quit, the Settings rows, and no network.
final class TranscriptWiringTests: XCTestCase {
    static let swiftDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    func read(_ path: String) throws -> String {
        try String(contentsOf: Self.swiftDir.appendingPathComponent(path), encoding: .utf8)
    }

    /// Cues, the session's Mute, Pause and call-app mute, and the call's app and joined title reach the note.
    func testTheControllerFeedsTheNote() throws {
        let c = try read("App/CoachController.swift")
        XCTAssertTrue(c.contains("self?.transcript.cue(cue.type)"))
        XCTAssertTrue(c.contains("self.transcript.callStarted(info: self.callInfo())"))
        XCTAssertTrue(c.contains("transcript.observe(callConditions)"))
        XCTAssertTrue(c.contains("CallConditions(youMuted: micMuted, paused: s.paused, appMuted: s.muted)"))
        XCTAssertTrue(c.contains("transcriber: config.gpt.transcribeModel"))
        let host = try read("App/Controller.swift")
        XCTAssertTrue(host.contains("coach?.joinHint(endsAt: end, title: title)"))
        XCTAssertTrue(host.contains("MainActor.assumeIsolated { coach?.willTerminate() }"), "quit finishes the note")
    }

    /// Writes run on a serial queue; recovery and retention run at launch, after a call and on a new folder.
    func testUpkeepAndQuit() throws {
        let t = try read("App/CoachTranscript.swift")
        XCTAssertTrue(t.contains("io: .serial(label:"))
        XCTAssertEqual(t.components(separatedBy: "maintain()").count - 1, 4, "the definition, init, every call's end and a new folder")
        XCTAssertTrue(t.contains("live.callEnded()\n        maintain()"), "recovery after every call, retention on or off")
        XCTAssertTrue(t.contains("{ [weak self] left in self?.unfinished = left }"))
        XCTAssertTrue(t.contains("pattern: note.fileNamePattern"), "retention looks only at names the pattern makes")
        XCTAssertTrue(t.contains("live.recorder.flush(timeout: Self.quitWait)"), "quit waits a bounded time")
    }

    /// A chosen folder is followed when renamed, and one that is gone or in the Trash takes no notes.
    func testAMissingOrTrashedFolderTakesNoNotes() throws {
        let t = try read("App/CoachTranscript.swift")
        XCTAssertTrue(t.contains("saving: savingOn && folderUsable"))
        XCTAssertTrue(t.contains("resolvedUsable = !folderIsChosen || (!Self.isInTrash(url) && live.recorder.store.isDirectory(url))"))
        XCTAssertTrue(t.contains("parts.contains(\".Trash\") || parts.contains(\".Trashes\")"))
        let sync = try XCTUnwrap(t.components(separatedBy: "func sync(keyUsable: Bool) {").dropFirst().first?.components(separatedBy: "\n    }\n").first)
        XCTAssertFalse(sync.contains("isDirectory") || sync.contains("refreshFolder"), "no disk check on every refresh")
        let rows = try read("App/CoachNoteSettings.swift")
        XCTAssertTrue(rows.contains("} else if lookedUp != t.folder.path {\n            t.refreshFolder()"),
                      "Settings looks again when it opens or the folder changes, not on every update")
        XCTAssertTrue(try read("App/CoachNoteSettings.swift").contains("folderUsable: t.folderUsable"))
    }

    /// The folder is a bookmark (security-scoped only if the app is ever sandboxed); no entitlement is added.
    func testTheFolderBookmarkNeedsNoEntitlement() throws {
        let t = try read("App/CoachTranscript.swift")
        XCTAssertTrue(t.contains("Self.isSandboxed ? [.withSecurityScope] : []"))
        XCTAssertTrue(t.contains("accessing = url.startAccessingSecurityScopedResource() ? url : nil"), "one open scope at a time")
        let project = try read("project.yml")
        XCTAssertTrue(project.contains("ENABLE_APP_SANDBOX: NO"))
        XCTAssertFalse(project.lowercased().contains("entitlements"))
    }

    /// The rows sit under the folder row, which is labelled "Save transcripts to".
    func testSettingsShowTheRows() throws {
        let w = try read("App/CoachSettingsWindow.swift")
        XCTAssertTrue(w.contains("Self.text(TranscriptCopy.saveTo, font: Theme.Settings.itemFont)"))
        XCTAssertTrue(w.contains("folderRow] + noteRows.views"))
        XCTAssertTrue(w.contains("noteRows.update(visible: window.isVisible)"))
        XCTAssertTrue(try read("App/CoachNoteSettings.swift").contains("TranscriptSettingsRows(.init("), "rows come from the snapshot-tested model")
    }

    /// No telemetry: nothing in the feature reaches the network.
    func testNoNetwork() throws {
        let kit = "Packages/ListenMoreKit/Sources/ListenMoreCore/"
        for f in ["App/CoachNoteSettings.swift", "App/CoachTranscript.swift", "Core/TranscriptCopy.swift", "Core/TranscriptSettingsRows.swift",
                  kit + "CallNote.swift", kit + "CallRecord.swift", kit + "DailyNote.swift", kit + "Transcript.swift", kit + "TranscriptFile.swift"] {
            let src = try read(f)
            for banned in ["URLSession", "URLRequest", "http://", "https://", "NSWorkspace.shared.open", "obsidian://"] {
                XCTAssertFalse(src.contains(banned), "\(f) contains \(banned)")
            }
        }
    }
}
