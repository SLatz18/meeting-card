import AppKit
import XCTest
@testable import ListenMoreCore
@testable import ListenMoreMac

/// The real Accessibility and AppleScript backends on a CI Mac (not trusted for Accessibility, no
/// Automation consent): the Meet meeting check behaves the same in AppleScript as in Swift, and
/// nothing reads, prompts or launches without permission.
final class CallControlsMacTests: XCTestCase {
    func run(_ source: String) throws -> NSAppleEventDescriptor {
        let script = try XCTUnwrap(NSAppleScript(source: source))
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        XCTAssertNil(error, "\(error ?? [:])")
        return result
    }

    func testMeetingHandlerMatchesTheSwiftMirror() throws {
        let urls = ["https://meet.google.com/abc-defg-hij", "https://meet.google.com/abc-defg-hij?authuser=0",
                    "https://meet.google.com/abc-defg-hij/", "https://meet.google.com/ABC-DEFG-HIJ#x",
                    "https://meet.google.com/", "https://meet.google.com/landing", "https://meet.google.com/abc-defg-hijk",
                    "https://meet.google.com/ab1-defg-hij", "https://meet.google.com/abcdefghijkl", "https://example.com/abc-defg-hij"]
        for u in urls {
            let r = try run(MeetScript.handler + "\nreturn isMeeting(\"\(u)\")")
            XCTAssertEqual(r.booleanValue, MeetScript.isMeetingURL(u), u)
        }
        let n = try run(MeetScript.handler + "\nreturn countMeetings({\"\(urls[0])\", \"\(urls[4])\", \"\(urls[1])\"})")
        XCTAssertEqual(n.int32Value, 2)
    }

    /// Only when Chrome is installed but not running (as on CI): the script compiles against
    /// Chrome's dictionary and returns 0 without sending Chrome an event.
    func testChromeScriptCompilesAndNeverLaunchesChrome() throws {
        let id = "com.google.Chrome"
        guard NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) != nil else { throw XCTSkip("Chrome not installed") }
        guard NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty else { throw XCTSkip("Chrome is running") }
        let source = try XCTUnwrap(MeetTabReader.chrome(runner: OSAScriptRunner()).scripts.first)
        XCTAssertEqual(OSAScriptRunner().run(source, bundleId: id), .count(0))
        XCTAssertTrue(NSRunningApplication.runningApplications(withBundleIdentifier: id).isEmpty, "Chrome was not launched")
    }

    func testNotRunningAppIsNeverAsked() {
        let id = "com.example.notinstalled"
        XCTAssertEqual(OSAScriptRunner().permission(bundleId: id), .notRunning)
        XCTAssertEqual(MeetTabReader(bundleId: id, scripts: ["return 1"], runner: OSAScriptRunner()).read(), .noCall)
    }

    func testZoomReaderWithoutTrustReadsNothing() {
        let ax = AXZoomAccessibility()
        let o = ZoomControlsReader(ax: ax).read()
        if ax.isTrusted {
            XCTAssertNotEqual(o, .unavailable(.accessibilityDenied))
        } else {
            XCTAssertEqual(o, .unavailable(.accessibilityDenied), "untrusted: falls back to Core Audio")
        }
        XCTAssertNil(AXZoomAccessibility(bundleId: "com.example.notinstalled").menuShortcuts())
    }

    func testLiveProviderIsOffUntilEnabled() throws {
        let p = CallControlsProvider.live(config: try .builtIn())
        XCTAssertFalse(p.isEnabled)
        XCTAssertTrue(p.callStates().isEmpty)
        XCTAssertEqual(p.readers.map(\.appKey), ["us.zoom.xos", "com.google.chrome", "company.thebrowser.dia"])
    }

    /// The real window tracker reads nothing while no tracked app runs and never invents a target.
    func testCallWindowTrackerWithNoCallAppRunning() {
        let t = CallWindowTracker(lookbackS: 60)
        XCTAssertTrue(CallWindowTracker.windows(appKeys: ["com.example.notinstalled"]).isEmpty)
        t.update(session: (appKey: "com.example.notinstalled", startedAt: 0), appKeys: ["com.example.notinstalled"],
                 browserKeys: [], alwaysOnKeys: [], hints: [:])
        XCTAssertNil(t.target(appKey: "com.example.notinstalled"))
        XCTAssertNil(t.callWindowPresent(appKey: "com.example.notinstalled"))
        XCTAssertEqual(CallDisplayLocator.screen(callWindow: nil, fallback: NSRect(x: 1, y: 2, width: 3, height: 4)),
                       NSRect(x: 1, y: 2, width: 3, height: 4), "nothing identified: the card's display")
    }

    func testZoomReaderGetsTheMeetingWindowSignal() throws {
        let t = CallWindowTracker(lookbackS: 60)
        let p = CallControlsProvider.live(config: try .builtIn(), callWindows: t)
        let zoom = try XCTUnwrap(p.readers.first as? ZoomControlsReader)
        XCTAssertNotNil(zoom.callWindowPresent)
        XCTAssertNil(zoom.callWindowPresent?() ?? nil, "nothing bound yet")
    }
}
