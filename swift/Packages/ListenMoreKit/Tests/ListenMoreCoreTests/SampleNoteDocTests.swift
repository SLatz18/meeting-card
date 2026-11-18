import XCTest
@testable import ListenMoreCore

/// The sample note in the docs is exactly what the renderer writes for a synthetic call, so the docs
/// can't drift from the code. `LM_WRITE_SAMPLE=1 swift test --filter SampleNoteDocTests` rewrites it.
final class SampleNoteDocTests: XCTestCase {
    static let repoURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    static let sampleName = "2026-01-31 0905 Synthetic planning call.md"
    static let sampleURL = repoURL.appendingPathComponent("docs/samples/\(sampleName)")
    static let docURL = repoURL.appendingPathComponent("docs/TRANSCRIPTS_OBSIDIAN.md")

    /// A made-up call: no real people, meetings or companies.
    static func sample() -> String {
        var r = CallRecord(callId: "c0123456789abcdef", start: TranscriptFixture.start,
                           info: CallInfo(title: "Synthetic planning call", app: "Zoom", transcriber: "gpt-live-transcribe"),
                           tags: [CallNote.defaultTag])
        func line(_ t: TimeInterval, _ s: Speaker, _ x: String) { r.lines.append(TranscriptLine(speaker: s, offset: t, text: x)) }
        line(4, .others, "Thanks for joining. Shall we start with the release timeline?")
        line(9, .me, "Yes. The first draft is ready for review.")
        line(15, .others, "Great. What is the biggest open risk?")
        line(17, .me, "Before you go on, I think it is the test plan.")
        r.cues.append(CueMark(type: CueType.interrupt.rawValue, offset: 18))
        r.openGap(.youMuted, at: 30)
        line(35, .others, "Then let's give the test plan another week.")
        r.closeGap(.youMuted, at: 52)
        r.openGap(.paused, at: 65)
        r.closeGap(.paused, at: 100)
        line(125, .others, "Does Friday work for the review?")
        line(129, .me, "The draft also needs new screenshots.")
        r.cues.append(CueMark(type: CueType.missedQuestion.rawValue, offset: 132))
        line(150, .others, "Okay. Talk soon.")
        r.end = 161
        return CallNote.render(r, labels: SpeakerLabels(), status: .complete, timeZone: TranscriptFixture.utc)
    }

    func testTheSampleNoteMatchesTheRenderer() throws {
        let text = Self.sample()
        if ProcessInfo.processInfo.environment["LM_WRITE_SAMPLE"] == "1" {
            try FileManager.default.createDirectory(at: Self.sampleURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: Self.sampleURL, atomically: true, encoding: .utf8)
        }
        XCTAssertEqual(try String(contentsOf: Self.sampleURL, encoding: .utf8), text, "regenerate with LM_WRITE_SAMPLE=1")
        let doc = try String(contentsOf: Self.docURL, encoding: .utf8)
        XCTAssertTrue(doc.contains("```markdown\n" + text + "```\n"), "the doc shows the sample note verbatim")
        XCTAssertTrue(doc.contains("docs/samples/\(Self.sampleName)") || doc.contains("samples/\(Self.sampleName.replacingOccurrences(of: " ", with: "%20"))"))
    }
}
