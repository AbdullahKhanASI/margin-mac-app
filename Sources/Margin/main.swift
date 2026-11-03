import AppKit

// Plain AppKit entry point: Margin has no SwiftUI scenes, only a menu bar item (MenuPanel)
// and a few windows it opens itself. A SwiftUI App with a placeholder scene would open an
// empty window on launch.
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
