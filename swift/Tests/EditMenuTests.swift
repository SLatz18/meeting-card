import XCTest
@testable import MeetingCardCore

/// The accessory app's hidden Edit menu: ⌘X, ⌘C, ⌘V, ⌘A, ⌘Z (and ⇧⌘Z) reach every text field,
/// with no menu bar or Dock icon, the key fields still masked and nothing logging what's pasted.
/// Hostless tests can't load AppKit, so the App's sources are read as text; ED1 is the hand check.
final class EditMenuTests: XCTestCase {
    static let swiftDir = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()

    func read(_ path: String) throws -> String {
        try String(contentsOf: Self.swiftDir.appendingPathComponent(path), encoding: .utf8)
    }

    func appSources() throws -> [(String, String)] {
        let dir = Self.swiftDir.appendingPathComponent("App")
        return try FileManager.default.contentsOfDirectory(atPath: dir.path).filter { $0.hasSuffix(".swift") }
            .map { ($0, try read("App/" + $0)) }
    }

    /// Each standard edit command, with AppKit's own action and its usual key equivalent.
    func testEditMenuCoversTheStandardKeys() throws {
        let menu = try read("App/EditMenu.swift")
        for line in ["Command(title: CoachCopy.editUndo, action: Selector((\"undo:\")), key: \"z\")",
                     "Command(title: CoachCopy.editRedo, action: Selector((\"redo:\")), key: \"z\", shift: true)",
                     "Command(title: CoachCopy.editCut, action: #selector(NSText.cut(_:)), key: \"x\")",
                     "Command(title: CoachCopy.editCopy, action: #selector(NSText.copy(_:)), key: \"c\")",
                     "Command(title: CoachCopy.editPaste, action: #selector(NSText.paste(_:)), key: \"v\")",
                     "Command(title: CoachCopy.editSelectAll, action: #selector(NSText.selectAll(_:)), key: \"a\")"] {
            XCTAssertTrue(menu.contains(line), line)
        }
        XCTAssertTrue(menu.contains("item.keyEquivalentModifierMask = c.shift ? [.command, .shift] : [.command]"))
        XCTAssertTrue(menu.contains("NSApp.mainMenu = main"))
        XCTAssertTrue(menu.contains("action: #selector(NSApplication.terminate(_:)), keyEquivalent: MenuFooter.quitKeyEquivalent"), "Cmd-Q quits from Settings too")
        XCTAssertTrue(menu.contains("appItem.submenu = appMenu"))
        let copy = try read("App/CoachCopy.swift")
        for s in ["editMenu = \"Edit\"", "editUndo = \"Undo\"", "editRedo = \"Redo\"", "editCut = \"Cut\"", "editCopy = \"Copy\"",
                  "editPaste = \"Paste\"", "editSelectAll = \"Select All\""] {
            XCTAssertTrue(copy.contains("static let " + s), s)
        }
    }

    /// Installed once at launch for every run, while the app stays an accessory: no menu bar, no Dock icon.
    func testInstalledAtLaunchWithoutAMenuBarOrDockIcon() throws {
        let launch = try XCTUnwrap(try read("App/Controller.swift").components(separatedBy: "func applicationDidFinishLaunching").dropFirst().first?
            .components(separatedBy: "\n    }\n").first)
        XCTAssertTrue(launch.contains("EditMenu.install()"))
        XCTAssertTrue(try read("App/main.swift").contains("app.setActivationPolicy(.accessory)"))
        let plist = try XCTUnwrap(PropertyListSerialization.propertyList(from: Data(try read("App/Info.plist").utf8), format: nil) as? [String: Any])
        XCTAssertEqual(plist["LSUIElement"] as? Bool, true)
        for (name, text) in try appSources() {
            XCTAssertFalse(text.contains("setActivationPolicy(.regular)"), "\(name) would show a menu bar and Dock icon")
            if name != "EditMenu.swift" { XCTAssertFalse(text.contains("mainMenu"), "\(name) touches the main menu") }
        }
    }

    /// The items have no target: AppKit sends each action to the focused field, so the key fields
    /// (secure fields) keep masking and refuse Copy and Cut themselves. Nothing overrides an edit action.
    func testKeyFieldsStayMasked() throws {
        let menu = try read("App/EditMenu.swift")
        XCTAssertFalse(menu.contains(".target"), "actions go to the first responder")
        let settings = try read("App/CoachSettingsWindow.swift")
        XCTAssertTrue(settings.contains("private let keyField = NSSecureTextField()"))
        XCTAssertTrue(settings.contains("private let typeSafeKeyField = NSSecureTextField()"))
        for (name, text) in try appSources() {
            for bad in ["echosBullets", "override func paste", "override func copy(", "override func cut(", "NSPasteboard.general.string"] {
                XCTAssertFalse(text.contains(bad), "\(name) contains \(bad)")
            }
        }
    }

    /// Nothing logs a pasted value: the Edit menu logs and reads nothing, and no log line in the App
    /// carries a field's text.
    func testNothingLogsAPastedValue() throws {
        let menu = try read("App/EditMenu.swift")
        for bad in ["log(", "Logger", "print(", "NSLog", "NSPasteboard", "stringValue"] {
            XCTAssertFalse(menu.contains(bad), "EditMenu.swift contains \(bad)")
        }
        for (name, text) in try appSources() {
            for line in text.components(separatedBy: "\n") where line.contains("log(") || line.contains("Log.") {
                for field in ["stringValue", "keyField", "typeSafeKeyField", "youField", "themField"] {
                    XCTAssertFalse(line.contains(field), "\(name) logs a field: \(line)")
                }
            }
        }
    }
}
