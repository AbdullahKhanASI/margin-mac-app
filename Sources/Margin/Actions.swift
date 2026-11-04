import AppKit
import MarginCore

/// Carries out commands: media keys, mute, system commands and keystrokes. The engine keeps the
/// haptics and the gesture report, because it knows which trackpad was touched.
enum Actions {
    /// Runs `command` on the main queue. Safe to call from any thread.
    static func fire(_ command: Command) {
        DispatchQueue.main.async { run(command) }
    }

    /// Whether this build can carry out `command`. The engine treats the rest as unbound, so
    /// they never claim a touch or swallow a click.
    static func canRun(_ command: Command) -> Bool {
        switch command {
        case .media, .toggleOutputMute, .toggleInputMute,
             .lockScreen, .screenshotRegion, .missionControl, .appWindows, .showDesktop,
             .startScreenSaver, .sleepDisplay, .keystroke:
            true
        // Window commands arrive in phase 6, the timer in phase 5; launchApp isn't scheduled yet.
        case .none, .window, .timerStart, .timerPauseResume, .timerCancel, .launchApp:
            false
        }
    }

    private static func run(_ command: Command) {
        switch command {
        case .media(let key):
            SystemControls.press(key)
            NotificationCenter.default.post(name: .marginLevelsChanged, object: nil)
        case .toggleOutputMute:
            if let out = SystemControls.outputVolume(), SystemControls.setMuted(!out.muted) {
                LevelOverlay.shared.show(.volume, level: Double(out.volume), muted: !out.muted)
            } else {
                SystemControls.press(.mute)
            }
            NotificationCenter.default.post(name: .marginLevelsChanged, object: nil)
        case .toggleInputMute:
            // A mic with neither mute nor volume has nothing to toggle; the buzz still says the
            // tap was seen.
            if let mic = SystemControls.toggleInputMute() {
                LevelOverlay.shared.show(.inputVolume, level: Double(mic.volume), muted: mic.muted)
            }
        case .missionControl:
            open("/System/Applications/Mission Control.app")
        case .startScreenSaver:
            open("/System/Library/CoreServices/ScreenSaverEngine.app")
        case .sleepDisplay:
            let pmset = Process()
            pmset.executableURL = URL(fileURLWithPath: "/usr/bin/pmset")
            pmset.arguments = ["displaysleepnow"]
            try? pmset.run()
        case .showDesktop:
            // Unverified on macOS 14–16; see `ShowDesktopShortcut`.
            post(ShowDesktopShortcut.resolve(symbolicHotKeys: symbolicHotKeys()))
        default:
            if let shortcut = command.shortcut { post(shortcut) }
        }
    }

    /// Sends a shortcut to the frontmost app, or to the system for system shortcuts. Needs the
    /// Accessibility access Margin already has.
    static func post(_ combo: KeyCombo) {
        let source = CGEventSource(stateID: .hidSystemState)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source, virtualKey: combo.keyCode, keyDown: down)
            else { continue }
            event.flags = CGEventFlags(rawValue: combo.postedFlags)
            event.post(tap: .cghidEventTap)
        }
    }

    private static func open(_ path: String) {
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }

    private static func symbolicHotKeys() -> Any? {
        let domain = "com.apple.symbolichotkeys" as CFString
        CFPreferencesAppSynchronize(domain)
        return CFPreferencesCopyAppValue("AppleSymbolicHotKeys" as CFString, domain)
    }
}
