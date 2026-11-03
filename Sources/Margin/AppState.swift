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
        if !accessibilityTrusted {
            if accessRequestedAt == nil { accessRequestedAt = Date() }
            openAccessibilitySettings()
        }
        updateAccessibilityHealth()
    }

    func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    // MARK: Stale permission

    /// True when Margin probably appears switched on in Accessibility settings but macOS no longer
    /// honours it. That happens when the app's signature changes (an update or a rebuild): the old
    /// entry stays in the list, but it belongs to a different binary as far as macOS is concerned.
    private(set) var accessibilityLikelyStale = false

    private static let grantedOnceKey = "accessibilityGrantedOnce"
    /// When the user last asked for access this session. If it hasn't come through a little
    /// while later, the toggle they flipped is likely the stale one.
    private var accessRequestedAt: Date?

    func updateAccessibilityHealth() {
        let defaults = UserDefaults.standard
        if accessibilityTrusted {
            defaults.set(true, forKey: Self.grantedOnceKey)
            accessRequestedAt = nil
            if accessibilityLikelyStale { accessibilityLikelyStale = false }
            return
        }
        let grantedBefore = defaults.bool(forKey: Self.grantedOnceKey)
        let waitedTooLong = accessRequestedAt.map { Date().timeIntervalSince($0) > 20 } ?? false
        let stale = grantedBefore || waitedTooLong
        if stale != accessibilityLikelyStale { accessibilityLikelyStale = stale }
    }

    /// Removes Margin's Accessibility entry so it can be granted afresh, then asks again.
    func resetAccessibility() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tccutil")
        process.arguments = ["reset", "Accessibility", Bundle.main.bundleIdentifier ?? "com.abdullahkhan.Margin"]
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            NSLog("Margin: tccutil reset failed: \(error)")
        }
        UserDefaults.standard.set(false, forKey: Self.grantedOnceKey)
        accessRequestedAt = nil
        accessibilityLikelyStale = false
        // Give TCC a moment to drop the old entry before the prompt re-adds this copy.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { self.requestAccessibility() }
    }
}
