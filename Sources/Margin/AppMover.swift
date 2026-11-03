import AppKit

/// Offers to move Margin into an Applications folder when it's launched from somewhere else
/// (Downloads, a disk image, or a randomised App Translocation path). Accessibility access and
/// Open at Login are tied to where the app lives, so they don't stick until it's installed.
enum AppMover {
    private static let suppressKey = "suppressMoveToApplications"

    /// Returns true if the app is relaunching from its new location and this instance should stop.
    static func moveIfNeeded() -> Bool {
        let bundleURL = Bundle.main.bundleURL.standardizedFileURL
        guard shouldOffer(bundleURL) else { return false }

        let alert = NSAlert()
        alert.messageText = "Move Margin to your Applications folder?"
        alert.informativeText = "Margin needs to live in Applications so macOS remembers its Accessibility "
            + "permission and can open it at login."
        alert.addButton(withTitle: "Move to Applications")
        alert.addButton(withTitle: "Not Now")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "Don't ask again"
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        if alert.suppressionButton?.state == .on {
            UserDefaults.standard.set(true, forKey: suppressKey)
        }
        guard response == .alertFirstButtonReturn else { return false }

        do {
            let destination = try install(from: bundleURL)
            relaunch(at: destination)
            return true
        } catch {
            let failure = NSAlert(error: error)
            failure.messageText = "Margin couldn't be moved"
            failure.informativeText = "\(error.localizedDescription)\n\nDrag Margin.app into Applications yourself, "
                + "then open it from there."
            failure.runModal()
            return false
        }
    }

    private static func shouldOffer(_ url: URL) -> Bool {
        if UserDefaults.standard.bool(forKey: suppressKey) { return false }
        if CommandLine.arguments.contains("--no-move") { return false }
        if isInApplications(url) { return false }
        // A development build sitting in this repo's build/ folder.
        let repoRoot = url.deletingLastPathComponent().deletingLastPathComponent()
        if FileManager.default.fileExists(atPath: repoRoot.appendingPathComponent("Package.swift").path) {
            return false
        }
        return true
    }

    private static func isInApplications(_ url: URL) -> Bool {
        let parent = url.deletingLastPathComponent().resolvingSymlinksInPath().path
        return applicationsFolders.contains { $0.resolvingSymlinksInPath().path == parent }
    }

    private static var applicationsFolders: [URL] {
        FileManager.default.urls(for: .applicationDirectory, in: [.localDomainMask, .userDomainMask])
    }

    /// Copies the bundle into /Applications (or ~/Applications if that isn't writable) and
    /// cleans up the original when it's safe to.
    private static func install(from source: URL) throws -> URL {
        let fm = FileManager.default
        let system = URL(fileURLWithPath: "/Applications", isDirectory: true)
        let folder: URL
        if fm.isWritableFile(atPath: system.path) {
            folder = system
        } else {
            folder = fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true)
            try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let destination = folder.appendingPathComponent(source.lastPathComponent)

        if fm.fileExists(atPath: destination.path) {
            // Quit any copy that's running from there before replacing it.
            for app in NSRunningApplication.runningApplications(withBundleIdentifier: Bundle.main.bundleIdentifier ?? "")
            where app.bundleURL?.standardizedFileURL == destination.standardizedFileURL {
                app.terminate()
            }
            try fm.trashItem(at: destination, resultingItemURL: nil)
        }
        try fm.copyItem(at: source, to: destination)
        clearQuarantine(destination)

        // Remove the downloaded copy, but never touch a disk image or a translocated path.
        let path = source.path
        if !path.hasPrefix("/Volumes/"), !path.contains("/AppTranslocation/"), fm.isDeletableFile(atPath: path) {
            try? fm.trashItem(at: source, resultingItemURL: nil)
        }
        return destination
    }

    private static func clearQuarantine(_ url: URL) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        process.arguments = ["-dr", "com.apple.quarantine", url.path]
        try? process.run()
        process.waitUntilExit()
    }

    /// Waits for this process to exit, then opens the installed copy.
    private static func relaunch(at url: URL) {
        let pid = ProcessInfo.processInfo.processIdentifier
        let script = "while /bin/kill -0 \(pid) 2>/dev/null; do /bin/sleep 0.2; done; /usr/bin/open \"$0\""
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, url.path]
        try? process.run()
        DispatchQueue.main.async { NSApp.terminate(nil) }
    }
}
