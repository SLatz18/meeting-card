import SwiftUI
import XCTest
@testable import MeetingCardCore

/// The caption feed renders at the card's width in light and dark, from CardStyle only, with no
/// window. The PNGs go to build/caption-feed/ (gitignored) for review.
@MainActor
final class CaptionFeedViewTests: XCTestCase {
    static let outDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("build/caption-feed", isDirectory: true)

    /// Synthetic, content-free lines.
    static func demo(saving: Bool = true) -> CaptionFeedModel {
        CaptionFeedModel(header: "Live captions", lines: [
            .init(speaker: "Them", text: "Shall we start with the timeline for the next release?", own: false),
            .init(speaker: "You", text: "Yes, the first draft is ready for review.", own: true),
            .init(speaker: "Them", text: "Great, let's go through it section by", own: false),
        ], footnote: saving ? "Saving a transcript for this call." : "Kept in memory only. Not saved.",
           savingLabel: saving ? "Saving transcript" : nil)
    }

    func write(_ img: CGImage, _ name: String) {
        try? FileManager.default.createDirectory(at: Self.outDir, withIntermediateDirectories: true)
        let url = Self.outDir.appendingPathComponent(name) as CFURL
        guard let dest = CGImageDestinationCreateWithURL(url, "public.png" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, img, nil)
        CGImageDestinationFinalize(dest)
    }

    func pixels(_ img: CGImage) -> [UInt8] {
        var px = [UInt8](repeating: 0, count: img.width * img.height * 4)
        guard let ctx = CGContext(data: &px, width: img.width, height: img.height, bitsPerComponent: 8, bytesPerRow: img.width * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return [] }
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
        return px
    }

    func testRendersAtCardWidthInLightAndDark() throws {
        let scale: CGFloat = 2
        var shots: [Bool: CGImage] = [:]
        for dark in [false, true] {
            let img = try XCTUnwrap(CaptionFeedSnapshot.image(Self.demo(), dark: dark, scale: scale), "dark=\(dark)")
            XCTAssertEqual(img.width, Int(Theme.Captions.cardWidth * Double(scale)), "the card's width")
            XCTAssertGreaterThan(img.height, Int(Theme.Captions.indicatorHeight * Double(scale)), "indicator plus lines")
            let px = pixels(img)
            let first = Array(px[0..<4])
            XCTAssertTrue(stride(from: 0, to: px.count, by: 4).contains { i in (0..<3).contains { abs(Int(px[i + $0]) - Int(first[$0])) > 40 } },
                          "text drawn on the surface (dark=\(dark))")
            let s = Theme.style(dark: dark).surface
            XCTAssertEqual(Double(first[0]) / 255, s.r, accuracy: 0.02, "the card's surface behind the feed")
            write(img, "caption-feed-\(dark ? "dark" : "light").png")
            shots[dark] = img
        }
        XCTAssertNotEqual(pixels(try XCTUnwrap(shots[false])), pixels(try XCTUnwrap(shots[true])), "follows the appearance")
    }

    func testMoreLinesAreTallerAndTheIndicatorIsOptional() throws {
        let one = CaptionFeedModel(lines: [.init(speaker: "You", text: "Hello.", own: true)])
        let three = Self.demo(saving: false)
        let withIndicator = Self.demo(saving: true)
        let h1 = try XCTUnwrap(CaptionFeedSnapshot.image(one, dark: false, scale: 1)).height
        let h3 = try XCTUnwrap(CaptionFeedSnapshot.image(three, dark: false, scale: 1)).height
        let hi = try XCTUnwrap(CaptionFeedSnapshot.image(withIndicator, dark: false, scale: 1)).height
        XCTAssertGreaterThan(h3, h1)
        XCTAssertGreaterThan(hi, h3)
        let saving = try XCTUnwrap(CaptionFeedSnapshot.image(CaptionFeedModel(savingLabel: "Saving transcript"), dark: true, scale: 2))
        write(saving, "caption-feed-saving-dark.png")
    }

    func testHeaderPlaceholderAndFootnoteEachAddARow() throws {
        func height(_ m: CaptionFeedModel) throws -> Int { try XCTUnwrap(CaptionFeedSnapshot.image(m, dark: false, scale: 1)).height }
        let empty = CaptionFeedModel(placeholder: "Captions will show here once someone talks.")
        let withHeader = CaptionFeedModel(header: "Live captions", placeholder: empty.placeholder)
        let full = CaptionFeedModel(header: "Live captions", placeholder: empty.placeholder, footnote: "Kept in memory only. Not saved.")
        XCTAssertGreaterThan(try height(withHeader), try height(empty))
        XCTAssertGreaterThan(try height(full), try height(withHeader))
        let stopped = CaptionFeedModel(header: "Live captions", note: "Captions stopped", placeholder: "unused")
        XCTAssertEqual(try height(stopped), try height(withHeader), "the note takes the placeholder's row")
        for dark in [false, true] {
            write(try XCTUnwrap(CaptionFeedSnapshot.image(full, dark: dark, scale: 2)), "caption-feed-empty-\(dark ? "dark" : "light").png")
        }
    }

    /// The coach card's captions area: exactly its size, light and dark, with the footnote on the
    /// last row and at most `cardRows` rows.
    func testCardLayoutFillsTheCoachCardCaptionsArea() throws {
        let area = Theme.Captions.cardArea
        var shots: [Bool: CGImage] = [:]
        for dark in [false, true] {
            let img = try XCTUnwrap(CaptionFeedSnapshot.cardImage(Self.demo(), dark: dark, scale: 2))
            XCTAssertEqual(img.width, Int(area.width * 2))
            XCTAssertEqual(img.height, Int(area.height * 2), "fits the card's three caption lines")
            write(img, "caption-feed-card-\(dark ? "dark" : "light").png")
            shots[dark] = img
        }
        XCTAssertNotEqual(pixels(try XCTUnwrap(shots[false])), pixels(try XCTUnwrap(shots[true])))
        XCTAssertEqual(Theme.Captions.cardRows, 3)
        let empty = CaptionFeedModel(placeholder: "Captions will show here once someone talks.", footnote: "Kept in memory only. Not saved.")
        let img = try XCTUnwrap(CaptionFeedSnapshot.cardImage(empty, dark: false, scale: 1))
        XCTAssertEqual(img.height, Int(area.height))
    }

    func testModelClearsAndReportsEmpty() {
        let m = Self.demo()
        XCTAssertFalse(m.isEmpty)
        m.clear()
        XCTAssertTrue(m.isEmpty)
        m.note = "Captions stopped"
        XCTAssertFalse(m.isEmpty)
    }

    /// No literal sizes, radii or colors: everything comes from Theme.Captions / CardStyle.
    func testFeedViewHasNoOneOffValues() throws {
        let src = try String(contentsOf: URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Core/CaptionFeedView.swift"), encoding: .utf8)
        let re = try NSRegularExpression(pattern: #"(\b(size|spacing|width|height|cornerRadius|lineWidth|opacity): ?[0-9])|(padding\([^)]*, ?[0-9])"#)
        XCTAssertNil(re.firstMatch(in: src, range: NSRange(src.startIndex..., in: src)), "a literal size")
        for bad in ["Color.red", "Color.blue", "Color.gray", "Color.black", "Color.white", "Color(red:", "Color(white:",
                    ".padding(1", ".padding(2", ".padding(8", "NSWindow", "NSPanel", "NSHostingView", "srgbRed:"] {
            XCTAssertFalse(src.contains(bad), bad)
        }
    }
}
