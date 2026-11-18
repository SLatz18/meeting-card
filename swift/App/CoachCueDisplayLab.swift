#if MEETINGCARD_TEST_ID
import AppKit
import MeetingCardCore
import SwiftUI

/// Test build only: `scripts/build.sh --test-id` defines MEETINGCARD_TEST_ID, the shipping build
/// compiles none of this (nor the Core prototype it shows). The coach menu's Cue Display
/// Prototype… opens the lab (`CueDisplayLabView`): the coaching-display options side by side on
/// recorded and synthetic cue timelines, so they can be compared without a call. It plays back
/// fixed timelines only: no audio, no session, and it keeps nothing.
@MainActor
final class CoachCueDisplayLab: NSObject, NSWindowDelegate {
    static let shared = CoachCueDisplayLab()

    private var panel: NSPanel?

    func menuItem() -> NSMenuItem {
        let m = NSMenuItem(title: CueDisplayCopy.Lab.menuItem, action: #selector(show(_:)), keyEquivalent: "")
        m.target = self
        return m
    }

    @objc func show(_ sender: Any?) {
        let p = panel ?? makePanel()
        panel = p
        NSApp.activate()
        p.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let host = NSHostingView(rootView: CueDisplayLabView())
        let p = NSPanel(contentRect: NSRect(origin: .zero, size: host.fittingSize),
                        styleMask: [.titled, .closable, .resizable, .utilityWindow], backing: .buffered, defer: false)
        p.title = CueDisplayCopy.Lab.title
        p.isReleasedWhenClosed = false
        p.hidesOnDeactivate = false
        p.delegate = self
        p.contentView = host
        p.center()
        return p
    }
}
#endif
