import AppKit
import SwiftUI
import XCTest
@testable import MeetingCardCore

/// Snapshot tests for the coaching-display prototype: each option on the coach card and the pill,
/// light and dark, the glyph-state hover detail, a burst and the recorded run before pacing as
/// strips over time, and the glyph vocabulary. The PNGs go to build/cue-display/ (gitignored); CI
/// uploads them as the `cue-display-snapshots` artifact, and docs/coaching-display/ keeps copies.
@MainActor
final class CueDisplaySnapshotTests: XCTestCase {
    static let outDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("build/cue-display", isDirectory: true)
    static let scale: CGFloat = 2
    /// The busy call at the talk-over: a cue in its hold, three caption rows.
    static let busy = CueTimeline.harnessBusy
    static let atCue: TimeInterval = 30.5
    /// After the hold, while the talk-over lingers.
    static let lingering: TimeInterval = 33

    func write(_ img: CGImage, _ name: String) {
        try? FileManager.default.createDirectory(at: Self.outDir, withIntermediateDirectories: true)
        let url = Self.outDir.appendingPathComponent("\(name).png") as CFURL
        guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }

    func pixels(_ img: CGImage, crop: CGRect? = nil) -> [UInt8] {
        let src = crop.flatMap { img.cropping(to: $0) } ?? img
        var px = [UInt8](repeating: 0, count: src.width * src.height * 4)
        guard let ctx = CGContext(data: &px, width: src.width, height: src.height, bitsPerComponent: 8, bytesPerRow: src.width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.draw(src, in: CGRect(x: 0, y: 0, width: src.width, height: src.height))
        return px
    }

    func tag(_ dark: Bool) -> String { dark ? "dark" : "light" }

    var padding: Double { Theme.CueDisplay.snapshotPadding }

    /// Each option on the card at the busy call's talk-over, light and dark: the card's size on the
    /// backdrop, something drawn, and different per appearance.
    func testCardForEachOptionInLightAndDark() throws {
        for option in CueDisplayOption.allCases {
            var shots: [Bool: CGImage] = [:]
            for dark in [false, true] {
                let img = try XCTUnwrap(CueDisplaySnapshot.image(option, Self.busy, at: Self.atCue, mode: .card, dark: dark, scale: Self.scale))
                XCTAssertEqual(img.width, Int((Theme.CoachCard.width + 2 * padding) * Double(Self.scale)), "\(option)")
                XCTAssertEqual(img.height, Int((Theme.CoachCard.height + 2 * padding) * Double(Self.scale)), "\(option)")
                write(img, "card-\(option.rawValue)-\(tag(dark))")
                shots[dark] = img
            }
            XCTAssertNotEqual(pixels(try XCTUnwrap(shots[false])), pixels(try XCTUnwrap(shots[true])), "\(option) follows the appearance")
        }
    }

    /// Each option on the pill, light and dark. The glyph-state pill never widens; the others widen
    /// for the words like the shipped pill.
    func testPillForEachOptionInLightAndDark() throws {
        var widths: [CueDisplayOption: Int] = [:]
        for option in CueDisplayOption.allCases {
            for dark in [false, true] {
                let img = try XCTUnwrap(CueDisplaySnapshot.image(option, Self.busy, at: Self.atCue, mode: .pill, dark: dark, scale: Self.scale))
                XCTAssertEqual(img.height, Int((Theme.CoachPill.height + 2 * padding) * Double(Self.scale)), "\(option)")
                write(img, "pill-\(option.rawValue)-\(tag(dark))")
                widths[option] = img.width
            }
        }
        let rest = try XCTUnwrap(CueDisplaySnapshot.image(.glyphState, Self.busy, at: 1, mode: .pill, dark: false, scale: Self.scale))
        XCTAssertEqual(widths[.glyphState], rest.width, "the glyph-state pill keeps its width through a cue")
        XCTAssertEqual(rest.width, Int((Theme.CoachPill.width + 2 * padding) * Double(Self.scale)))
        XCTAssertGreaterThan(try XCTUnwrap(widths[.rotatingLine]), rest.width, "the shipped pill widens for the words")
        XCTAssertEqual(widths[.rotatingLine], widths[.captionAnchored], "no captions in the pill: caption-anchored is the rotating line there")
    }

    /// Glyph state's detail, shown on hover: the words and how long ago on the card's status line,
    /// and a tooltip under the pill.
    func testGlyphStateHoverDetail() throws {
        for dark in [false, true] {
            let card = try XCTUnwrap(CueDisplaySnapshot.image(.glyphState, Self.busy, at: Self.lingering, mode: .card, hover: true, dark: dark,
                                                              scale: Self.scale))
            let plain = try XCTUnwrap(CueDisplaySnapshot.image(.glyphState, Self.busy, at: Self.lingering, mode: .card, dark: dark, scale: Self.scale))
            XCTAssertNotEqual(pixels(card), pixels(plain), "hover shows the detail")
            write(card, "card-glyph-state-hover-\(tag(dark))")
            write(plain, "card-glyph-state-lingering-\(tag(dark))")
            let pill = try XCTUnwrap(CueDisplaySnapshot.image(.glyphState, Self.busy, at: Self.lingering, mode: .pill, hover: true, dark: dark,
                                                              scale: Self.scale))
            XCTAssertGreaterThan(pill.height, Int((Theme.CoachPill.height + 2 * padding) * Double(Self.scale)), "the tooltip under the pill")
            write(pill, "pill-glyph-state-hover-\(tag(dark))")
        }
    }

    /// Caption-anchored marks the row that triggered the cue; the rotating line's captions are the
    /// plain feed. Only the captions area differs between the two.
    func testCaptionAnchoredMarksTheRow() throws {
        let k = Theme.CoachCard.self
        let s = Double(Self.scale)
        let area = k.captions
        let captions = CGRect(x: (padding + area.x - Theme.CueDisplay.markGutter) * s, y: (padding + k.height - area.maxY) * s,
                              width: (area.width + Theme.CueDisplay.markGutter) * s, height: area.height * s)
        let status = CGRect(x: (padding + k.statusRow.x) * s, y: (padding + k.height - k.statusRow.maxY) * s,
                            width: k.statusRow.width * s, height: k.statusRow.height * s)
        for t in [8.5, Self.atCue] {
            let line = try XCTUnwrap(CueDisplaySnapshot.image(.rotatingLine, Self.busy, at: t, mode: .card, dark: false, scale: Self.scale))
            let anchored = try XCTUnwrap(CueDisplaySnapshot.image(.captionAnchored, Self.busy, at: t, mode: .card, dark: false, scale: Self.scale))
            XCTAssertNotEqual(pixels(line, crop: captions), pixels(anchored, crop: captions), "t=\(t): the mark")
            XCTAssertEqual(pixels(line, crop: status), pixels(anchored, crop: status), "t=\(t): the same status line")
        }
        // No cue lingering: the same rows as the plain feed.
        let line = try XCTUnwrap(CueDisplaySnapshot.image(.rotatingLine, Self.busy, at: 5, mode: .card, dark: false, scale: Self.scale))
        let anchored = try XCTUnwrap(CueDisplaySnapshot.image(.captionAnchored, Self.busy, at: 5, mode: .card, dark: false, scale: Self.scale))
        XCTAssertEqual(pixels(line), pixels(anchored))
    }

    /// A burst (five cues in 6 s) as a strip over time, for each option on the card and the pill,
    /// light and dark; and the recorded busy call before pacing.
    func testBurstAndBeforePacingStrips() throws {
        let burst = CueTimeline.syntheticBurst
        let raw = CueTimeline.harnessBusyBeforePacing
        for option in CueDisplayOption.allCases {
            for dark in [false, true] {
                let card = try XCTUnwrap(CueDisplaySnapshot.strip(option, burst, moments: burst.moments, mode: .card, dark: dark, scale: Self.scale))
                XCTAssertGreaterThan(card.width, Int(Double(burst.moments.count) * Theme.CoachCard.width * Double(Self.scale)))
                write(card, "burst-card-\(option.rawValue)-\(tag(dark))")
                let pill = try XCTUnwrap(CueDisplaySnapshot.strip(option, burst, moments: burst.moments, mode: .pill, dark: dark, scale: Self.scale))
                write(pill, "burst-pill-\(option.rawValue)-\(tag(dark))")
                let before = try XCTUnwrap(CueDisplaySnapshot.strip(option, raw, moments: raw.moments, mode: .card, dark: dark, scale: Self.scale))
                write(before, "before-pacing-card-\(option.rawValue)-\(tag(dark))")
            }
        }
        // Mid-burst nothing new shows: the card at 16 s looks the same on the rotating line as at rest.
        let mid = try XCTUnwrap(CueDisplaySnapshot.image(.rotatingLine, burst, at: 16, mode: .card, dark: false, scale: Self.scale))
        let k = Theme.CoachCard.self, s = Double(Self.scale)
        let status = CGRect(x: (padding + k.statusRow.x) * s, y: (padding + k.height - k.statusRow.maxY) * s,
                            width: k.statusRow.width * s, height: k.statusRow.height * s)
        let rest = try XCTUnwrap(CueDisplaySnapshot.image(.rotatingLine, burst, at: 1, mode: .card, dark: false, scale: Self.scale))
        XCTAssertEqual(pixels(mid, crop: status), pixels(rest, crop: status), "the status line rests while cues wait")
    }

    /// The glyph-state vocabulary, light and dark; every glyph is a real SF Symbol on this macOS.
    func testGlyphVocabulary() throws {
        for kind in CoachNudge.Kind.allCases {
            XCTAssertNotNil(NSImage(systemSymbolName: Theme.CueDisplay.glyph(kind), accessibilityDescription: nil), kind.rawValue)
        }
        for dark in [false, true] {
            write(try XCTUnwrap(CueDisplaySnapshot.glyphs(dark: dark, scale: Self.scale)), "glyphs-\(tag(dark))")
        }
    }

    /// The lab renders (the test build's window content).
    func testLabRenders() throws {
        let renderer = ImageRenderer(content: CueDisplayLabView().frame(width: Theme.CoachPill.maxWidth * 2))
        XCTAssertNotNil(renderer.cgImage)
    }
}
