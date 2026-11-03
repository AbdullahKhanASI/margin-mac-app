import AppKit
import SwiftUI

/// Margin's menu bar item and its drop-down panel.
///
/// MenuBarExtra's window floats below the menu bar with all four corners rounded. This panel
/// instead hangs flush from the bottom of the menu bar, like a system menu, with only its
/// bottom corners rounded.
final class MenuPanel: NSObject, NSWindowDelegate {
    static let shared = MenuPanel()
    static let cornerRadius: CGFloat = 10

    private var statusItem: NSStatusItem?
    private var panel: NSPanel?
    private var monitors: [Any] = []
    private(set) var isOpen = false

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        item.button?.image = MenuBarIcon.image
        item.button?.target = self
        item.button?.action = #selector(toggle)
        // Open on press, like the system's own menu bar items.
        item.button?.sendAction(on: [.leftMouseDown, .rightMouseDown])
        statusItem = item
    }

    @objc private func toggle() {
        isOpen ? close() : open()
    }

    func open() {
        let panel = panel ?? makePanel()
        self.panel = panel

        panel.appearance = switch Preferences.shared.appearance {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
        AppState.shared.refreshLevels()
        anchor(panel)
        panel.makeKeyAndOrderFront(nil)
        statusItem?.button?.highlight(true)
        isOpen = true

        // Clicks in other apps close the panel. A click on our own status item can also arrive here
        // (the menu bar routes it), so leave that one to `toggle`; otherwise the panel would close
        // and immediately reopen.
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown], handler: { [weak self] _ in
            guard let self, !self.isOverStatusItem(NSEvent.mouseLocation) else { return }
            self.close()
        }) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { [weak self] event in
            if event.keyCode == 53 { // Escape
                self?.close()
                return nil
            }
            return event
        }) {
            monitors.append(local)
        }
    }

    private func isOverStatusItem(_ point: NSPoint) -> Bool {
        guard let button = statusItem?.button, let window = button.window else { return false }
        return window.convertToScreen(button.convert(button.bounds, to: nil)).contains(point)
    }

    func close() {
        guard isOpen else { return }
        isOpen = false
        panel?.orderOut(nil)
        statusItem?.button?.highlight(false)
        // Reset while hidden, so the next open starts on the home page without a flash of Settings.
        NotificationCenter.default.post(name: .marginPanelClosed, object: nil)
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
    }

    private func makePanel() -> NSPanel {
        let controller = NSHostingController(rootView: PanelContent())
        // The window follows the SwiftUI content's size, e.g. when switching to Settings.
        controller.sizingOptions = .preferredContentSize

        let panel = KeyablePanel(contentViewController: controller)
        panel.styleMask = [.borderless, .nonactivatingPanel]
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .popUpMenu
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.delegate = self
        return panel
    }

    /// Top edge on the bottom of the menu bar, left edge under the status item, kept on screen.
    private func anchor(_ panel: NSPanel) {
        guard let button = statusItem?.button, let barWindow = button.window else { return }
        let buttonFrame = barWindow.convertToScreen(button.convert(button.bounds, to: nil))
        let screen = barWindow.screen ?? NSScreen.main
        let size = panel.frame.size

        var x = buttonFrame.minX
        if let screen { x = min(x, screen.frame.maxX - size.width) }
        panel.setFrameOrigin(NSPoint(x: x, y: barWindow.frame.minY - size.height))
    }

    func windowDidResize(_ notification: Notification) {
        guard let panel else { return }
        anchor(panel)
        panel.invalidateShadow()
    }
}

/// Borderless panels can't become key by default, which would leave the controls inert.
private final class KeyablePanel: NSPanel {
    override var canBecomeKey: Bool { true }
}

private struct PanelContent: View {
    var body: some View {
        MenuView()
            .background(VisualEffectBackground())
            .clipShape(UnevenRoundedRectangle(bottomLeadingRadius: MenuPanel.cornerRadius,
                                              bottomTrailingRadius: MenuPanel.cornerRadius,
                                              style: .continuous))
    }
}

/// The translucent material system menus use.
private struct VisualEffectBackground: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}
