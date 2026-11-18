import AppKit
import MeetingCardCore

/// MeetingCard is an accessory app (LSUIElement, `.accessory`): it never shows a menu bar or a Dock
/// icon, and without a main menu AppKit has nowhere to route ⌘X, ⌘C, ⌘V, ⌘A and ⌘Z, so they never
/// reach a text field. This main menu is never drawn; its Edit items carry the standard key
/// equivalents and send AppKit's own actions to the first responder (no target), so each field
/// handles them itself: a secure field keeps masking, accepts Paste and still refuses Cut and Copy.
enum EditMenu {
    struct Command {
        let title: String
        let action: Selector
        let key: String
        var shift = false
    }

    static let commands: [Command] = [
        Command(title: CoachCopy.editUndo, action: Selector(("undo:")), key: "z"),
        Command(title: CoachCopy.editRedo, action: Selector(("redo:")), key: "z", shift: true),
        Command(title: CoachCopy.editCut, action: #selector(NSText.cut(_:)), key: "x"),
        Command(title: CoachCopy.editCopy, action: #selector(NSText.copy(_:)), key: "c"),
        Command(title: CoachCopy.editPaste, action: #selector(NSText.paste(_:)), key: "v"),
        Command(title: CoachCopy.editSelectAll, action: #selector(NSText.selectAll(_:)), key: "a"),
    ]

    static func install() {
        let edit = NSMenu(title: CoachCopy.editMenu)
        for c in commands {
            let item = NSMenuItem(title: c.title, action: c.action, keyEquivalent: c.key)
            item.keyEquivalentModifierMask = c.shift ? [.command, .shift] : [.command]
            edit.addItem(item)
        }
        let editItem = NSMenuItem(title: CoachCopy.editMenu, action: nil, keyEquivalent: "")
        editItem.submenu = edit
        // The first item is the application menu slot; Edit follows it.
        // ⌘Q quits from the Settings window too (the status menu's Quit only answers while it is open). No target: terminate: reaches NSApplication through the responder chain.
        let appMenu = NSMenu()
        let quit = NSMenuItem(title: CoachCopy.menuQuit, action: #selector(NSApplication.terminate(_:)), keyEquivalent: MenuFooter.quitKeyEquivalent)
        quit.keyEquivalentModifierMask = [.command]
        appMenu.addItem(quit)
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        let main = NSMenu()
        main.addItem(appItem)
        main.addItem(editItem)
        NSApp.mainMenu = main
    }
}
