import AppKit
import XCTest
import ListenMoreCore
@testable import ListenMoreMac

/// A host style that is deliberately unlike any real theme, to prove the Kit draws what it is given.
let testCaptionStyle = CaptionStyle(
    width: 400, radius: 20, padding: NSSize(width: 17, height: 15), lineGap: 4, speakerGap: 8,
    surface: NSColor(srgbRed: 0.2, green: 0.4, blue: 0.6, alpha: 1), textColor: .black, speakerColor: .gray,
    ownSpeakerColor: .blue, noteColor: .darkGray,
    textFont: .systemFont(ofSize: 13.5), speakerFont: .systemFont(ofSize: 14, weight: .medium), noteFont: .systemFont(ofSize: 12.5),
    indicatorHeight: 33, indicatorRadius: 9, indicatorPadding: 8, indicatorGap: 4, indicatorFont: .systemFont(ofSize: 12.5),
    hairline: .gray, hairlineWidth: 0.5, dot: .red, dotDiameter: 8, stackGap: 8, margin: 14, trailingReserve: 428)

@MainActor
final class CaptionPanelTests: XCTestCase {
    override func setUp() async throws {
        _ = NSApplication.shared
    }

    let two = CaptionContent(lines: [.init(speaker: "Them", text: "Shall we look at the timeline first?", own: false),
                                     .init(speaker: "You", text: "Yes, let us start there.", own: true)])

    func testPanelIsHiddenFromScreenShareAndNeverTakesFocus() {
        let p = CaptionPanel(style: testCaptionStyle)
        XCTAssertEqual(p.sharingType, .none, "left out of screen shares, like the glow")
        XCTAssertTrue(p.ignoresMouseEvents)
        XCTAssertFalse(p.canBecomeKey)
        XCTAssertFalse(p.canBecomeMain)
        XCTAssertTrue(p.styleMask.contains(.nonactivatingPanel))
        XCTAssertFalse(p.hasShadow)
        XCTAssertEqual(p.level, .statusBar)
        p.orderFrontRegardless()
        p.makeKey()
        XCTAssertFalse(p.isKeyWindow)
        p.orderOut(nil)
    }

    func testRendersOneRowPerLineWithTheSpeakerFirst() {
        let v = CaptionView(style: testCaptionStyle)
        v.show(two)
        XCTAssertEqual(v.stripLabels.map(\.stringValue), ["Them", "Shall we look at the timeline first?", "You", "Yes, let us start there."])
        XCTAssertEqual(v.stripLabels[3].lineBreakMode, .byTruncatingHead, "long lines keep their newest words")
        XCTAssertEqual(v.stripLabels[2].textColor, .blue, "the user's own label")
        XCTAssertEqual(v.stripLabels[0].textColor, .gray)
        XCTAssertNil(v.indicator)
        XCTAssertEqual(v.frame.width, 400)
        XCTAssertEqual(v.frame.height, CaptionView.stripHeight(testCaptionStyle, rows: 2))
        XCTAssertEqual(v.strip?.layer?.cornerRadius, 20)
        XCTAssertEqual(v.strip?.layer?.cornerCurve, .continuous)
        XCTAssertGreaterThanOrEqual(v.stripLabels[0].frame.width, CaptionView.labelWidth("Them", testCaptionStyle.speakerFont),
                                    "speaker labels never clip")
        let first = v.stripLabels[1].frame, second = v.stripLabels[3].frame
        XCTAssertGreaterThan(first.minY, second.minY, "oldest line on top")
        XCTAssertEqual(v.stripLabels[1].frame.minX, v.stripLabels[3].frame.minX, "text column aligned")
    }

    func testSavingIndicatorAloneAndAboveTheStrip() {
        let v = CaptionView(style: testCaptionStyle)
        v.show(CaptionContent(saving: "Saving transcript"))
        XCTAssertNil(v.strip)
        XCTAssertEqual(v.indicatorLabel?.stringValue, "Saving transcript")
        XCTAssertGreaterThanOrEqual(v.indicatorLabel?.frame.width ?? 0, CaptionView.labelWidth("Saving transcript", testCaptionStyle.indicatorFont))
        XCTAssertEqual(v.frame.height, 33)
        var both = two
        both.saving = "Saving transcript"
        v.show(both)
        XCTAssertNotNil(v.strip)
        let strip = CaptionView.stripHeight(testCaptionStyle, rows: 2)
        XCTAssertEqual(v.strip?.frame.minY, 0)
        XCTAssertEqual(v.indicator?.frame.minY, strip + 8, "indicator above the strip")
        XCTAssertEqual(v.frame.height, 33 + 8 + strip)
    }

    func testANoteReplacesTheLines() {
        let v = CaptionView(style: testCaptionStyle)
        v.show(CaptionContent(note: "Captions stopped"))
        XCTAssertEqual(v.stripLabels.map(\.stringValue), ["Captions stopped"])
        XCTAssertEqual(v.frame.height, CaptionView.stripHeight(testCaptionStyle, rows: 1))
    }

    func testRowsFromTheCaptionBufferUseTheCallsLabels() {
        var b = CaptionBuffer()
        b.apply(.final(.others, text: "One."), at: 1)
        b.apply(.partial(.me, item: "x", text: "two"), at: 2)
        var labels = SpeakerLabels()
        labels.rename(.others, to: "Guest")
        XCTAssertEqual(CaptionContent.rows(b.lines, labels: labels),
                       [.init(speaker: "Guest", text: "One.", own: false), .init(speaker: "You", text: "two", own: true)])
    }

    func testControllerShowsOnTheCallDisplayAndHidesWhenEmpty() {
        let main = (frame: NSRect(x: 0, y: 0, width: 1440, height: 900), visible: NSRect(x: 0, y: 0, width: 1440, height: 875))
        let side = (frame: NSRect(x: 1440, y: 0, width: 1920, height: 1080), visible: NSRect(x: 1440, y: 40, width: 1920, height: 1040))
        let c = CaptionPanelController(style: testCaptionStyle, visibleFrames: { [main, side] })
        c.screen = { side.frame }
        c.show(two)
        XCTAssertTrue(c.isVisible)
        XCTAssertEqual(c.panel.frame.minY, 40 + 14, "margin above the display's visible bottom")
        XCTAssertEqual(c.panel.frame.midX, side.visible.midX, accuracy: 1)
        c.show(CaptionContent())
        XCTAssertFalse(c.isVisible)
        c.show(two)
        c.hide()
        XCTAssertFalse(c.isVisible)
        XCTAssertEqual(c.content, CaptionContent(), "hide drops the text")
    }

    func testLayoutKeepsClearOfTheHostWindowAtTheRight() {
        let visible = NSRect(x: 0, y: 0, width: 1024, height: 740)
        let f = CaptionLayout.frame(size: NSSize(width: 400, height: 80), visible: visible, margin: 14, trailingReserve: 428)
        XCTAssertLessThanOrEqual(f.maxX, visible.maxX - 428 - 14)
        XCTAssertGreaterThanOrEqual(f.minX, 14)
        let wide = CaptionLayout.frame(size: NSSize(width: 400, height: 80), visible: NSRect(x: 0, y: 0, width: 1920, height: 1000),
                                       margin: 14, trailingReserve: 428)
        XCTAssertEqual(wide.midX, 960, accuracy: 1, "centred when there is room")
    }
}
