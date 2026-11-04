import AppKit
import UniformTypeIdentifiers

/// An installed app, found by bundle ID, for showing a Launch App binding.
struct InstalledApp {
    let url: URL
    let name: String
    let icon: NSImage

    init?(bundleID: String) {
        guard !bundleID.isEmpty, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
        else { return nil }
        self.url = url
        name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        icon = NSWorkspace.shared.icon(forFile: url.path)
    }
}

/// Picks an app for Launch App with an open panel in /Applications.
///
/// The menu panel sits at `.popUpMenu`, above ordinary windows, so the open panel is raised above
/// it, and the menu is told a child window is up so clicking in it doesn't close the menu.
@MainActor
enum AppChooser {
    private static let delegate = ApplicationsOnly()

    /// Calls `completion` with the chosen app's bundle ID, or nil if it was cancelled or the app
    /// has no bundle ID.
    static func choose(completion: @escaping (String?) -> Void) {
        let panel = NSOpenPanel()
        panel.title = "Choose an App"
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowedContentTypes = [.application]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.treatsFilePackagesAsDirectories = false
        panel.delegate = delegate
        panel.level = MenuPanel.childLevel

        MenuPanel.shared.beginChildWindow()
        // Margin is a menu bar app, so it isn't active; the open panel needs it to be, to take
        // the keyboard.
        NSApp.activate()
        panel.begin { response in
            MenuPanel.shared.endChildWindow()
            guard response == .OK, let url = panel.url else { return completion(nil) }
            completion(Bundle(url: url)?.bundleIdentifier)
        }
    }
}

/// Keeps the open panel inside the Applications folders. Finder shows the system's own apps
/// (Calculator, Notes) in /Applications, but they live in /System/Applications.
///
/// An item counts if either its own path or the one it links to is inside: Safari's entry in
/// /Applications is a symlink into the system's Cryptex volume, so checking only the resolved
/// path greyed it out.
private final class ApplicationsOnly: NSObject, NSOpenSavePanelDelegate {
    private static let roots = ["/Applications", "/System/Applications"]

    func panel(_ sender: Any, shouldEnable url: URL) -> Bool {
        [url.standardizedFileURL.path, url.resolvingSymlinksInPath().path].contains { path in
            Self.roots.contains { path == $0 || path.hasPrefix($0 + "/") }
        }
    }
}
