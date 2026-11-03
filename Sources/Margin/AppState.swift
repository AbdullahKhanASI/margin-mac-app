import AppKit
import ApplicationServices
import CMultitouch
import Observation
import ServiceManagement

/// Live state shown in the menu: permissions, connected trackpads, current levels.
@Observable
final class AppState {
    static let shared = AppState()

    var accessibilityTrusted = AXIsProcessTrusted()
    var trackpadCount = 0
    var multitouchAvailable = mr_multitouch_available() == 1
    var volume: Float = 0
    var muted = false
    var brightness: Float?

    var launchAtLogin: Bool {
        get {
            _ = loginToggleCount
            return SMAppService.mainApp.status == .enabled
        }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                NSLog("Margin: launch at login change failed: \(error)")
            }
            loginToggleCount += 1
        }
    }
    // Bumped so SwiftUI re-reads `launchAtLogin`, which lives outside the observation system.
    private var loginToggleCount = 0

    func refreshLevels() {
        if let output = SystemControls.outputVolume() {
            volume = output.volume
            muted = output.muted
        }
        brightness = SystemControls.brightness()
    }

    func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        accessibilityTrusted = AXIsProcessTrustedWithOptions(options)
        if !accessibilityTrusted,
           let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
