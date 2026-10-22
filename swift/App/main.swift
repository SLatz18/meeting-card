import AppKit

// LSUIElement app: no Dock icon, no main window. Accessory policy = cards never steal focus.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let controller = Controller(args: Args.parse(CommandLine.arguments))
app.delegate = controller
app.run()
