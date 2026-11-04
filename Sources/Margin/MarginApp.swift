import AppKit
import CMultitouch
import MarginCore
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var watchdog: Timer?
    private var startedDevices = 0

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Runs before anything else so permissions are only ever requested for the installed copy.
        if AppMover.moveIfNeeded() { return }

        mr_allow_background_cursor_control()
        MenuPanel.shared.install()
        Preferences.shared.pushToEngine()
        startDevices()

        let state = AppState.shared
        state.updateAccessibilityHealth()
        // The setup guide asks for access itself on first launch; later launches prompt directly.
        if CommandLine.arguments.contains("--setup-guide") {
            SetupGuide.shared.show()
        } else if UserDefaults.standard.bool(forKey: "setupGuideSeen") {
            if !state.accessibilityTrusted { state.requestAccessibility() }
        } else {
            SetupGuide.shared.showIfFirstLaunch()
        }
        InputGate.shared.install()

        NSWorkspace.shared.notificationCenter.addObserver(
            self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(configChanged(_:)), name: .marginConfigChanged, object: nil)

        // Picks up a granted Accessibility permission and trackpads that connect or disconnect.
        watchdog = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
            self?.checkHealth()
        }

        // Development aid: show the menu's content in an ordinary window.
        if CommandLine.arguments.contains("--preview-menu") { showPreviewWindow() }
        if CommandLine.arguments.contains("--preview-overlay") { previewOverlay() }
        if CommandLine.arguments.contains("--open-panel") {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { MenuPanel.shared.open() }
            if CommandLine.arguments.contains("--settings") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                    NotificationCenter.default.post(name: .marginShowSettings, object: nil)
                }
            }
        }
    }

    private var previewWindow: NSWindow?

    /// Sweeps the overlay up and down without touching the real volume or brightness.
    private func previewOverlay() {
        var t = 0.0
        Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { _ in
            t += 1.0 / 60
            let kind: LevelKind = Int(t / 4) % 2 == 0 ? .volume : .brightness
            LevelOverlay.shared.show(kind, level: 0.5 + 0.45 * sin(t * 1.5), muted: false)
        }
    }

    private func showPreviewWindow() {
        // `--settings` or `--zone <zone>` opens on that page, e.g. `--zone bottomEdge`.
        let args = CommandLine.arguments
        var page = MenuPage.main
        if args.contains("--settings") { page = .settings }
        // `--profile <bundleID>` opens that profile, or its zone with `--zone` too.
        var profile: String?
        if let i = args.firstIndex(of: "--profile"), i + 1 < args.count {
            profile = args[i + 1]
            page = .profile(args[i + 1])
        }
        if let i = args.firstIndex(of: "--zone"), i + 1 < args.count, let zone = Zone(rawValue: args[i + 1]) {
            page = .zone(zone, profile: profile)
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: MenuView(page: page)))
        window.title = "Margin Menu Preview"
        window.center()
        window.makeKeyAndOrderFront(nil)
        previewWindow = window
    }

    func applicationWillTerminate(_ notification: Notification) {
        TouchEngine.shared.reset()
        InputGate.shared.unfreeze()
        mr_stop()
    }

    private func startDevices() {
        let config = Preferences.shared.config
        TouchEngine.shared.reset()
        startedDevices = Int(mr_start(multitouchFrame, config.includeExternal ? 1 : 0, config.magicMouse ? 1 : 0))
        AppState.shared.trackpadCount = Int(mr_device_count(config.includeExternal ? 1 : 0, 0))
        NSLog("Margin: listening on %d device(s)", startedDevices)
    }

    private func checkHealth() {
        let state = AppState.shared
        let trusted = AXIsProcessTrusted()
        if trusted != state.accessibilityTrusted { state.accessibilityTrusted = trusted }
        state.updateAccessibilityHealth()
        if trusted { InputGate.shared.install() }

        let config = Preferences.shared.config
        if Int(mr_device_count(config.includeExternal ? 1 : 0, config.magicMouse ? 1 : 0)) != startedDevices {
            startDevices()
        }
    }

    @objc private func didWake() {
        // Devices come back a moment after wake; restarting re-registers the frame callbacks.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { self.startDevices() }
    }

    @objc private func configChanged(_ note: Notification) {
        guard let old = note.object as? EngineConfig else { return }
        let new = Preferences.shared.config
        if old.includeExternal != new.includeExternal || old.magicMouse != new.magicMouse { startDevices() }
    }
}

enum MenuBarIcon {
    /// A small trackpad outline with a bar on each edge, drawn as a template image.
    static let image: NSImage = {
        let size = NSSize(width: 20, height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            NSColor.black.set()
            let body = NSBezierPath(roundedRect: rect.insetBy(dx: 1, dy: 1.5), xRadius: 3, yRadius: 3)
            body.lineWidth = 1.4
            body.stroke()
            for x in [4.0, 14.5] {
                NSBezierPath(roundedRect: NSRect(x: x, y: 4.5, width: 1.6, height: 5), xRadius: 0.8, yRadius: 0.8).fill()
            }
            return true
        }
        image.isTemplate = true
        return image
    }()
}
