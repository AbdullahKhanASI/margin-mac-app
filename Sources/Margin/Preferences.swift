import AppKit
import Foundation
import MarginCore
import Observation
import SwiftUI

enum HapticStrength: String, Codable, CaseIterable, Identifiable {
    case light, medium, strong
    var id: Self { self }
    var title: String { rawValue.capitalized }
    /// One level lighter, used for the dense ticks of precise sliding.
    var softer: HapticStrength {
        switch self {
        case .strong: .medium
        case .medium, .light: .light
        }
    }
}

/// How many haptic notches a full 0–100% slide passes through.
enum HapticFeel: String, Codable, CaseIterable, Identifiable {
    case clicky, standard, rich
    var id: Self { self }
    var title: String {
        switch self {
        case .clicky: "Clicky"
        case .standard: "Default"
        case .rich: "Rich"
        }
    }
    var notches: Double {
        switch self {
        case .clicky: 16
        case .standard: 25
        case .rich: 40
        }
    }
}

enum Appearance: String, Codable, CaseIterable, Identifiable {
    case system, light, dark
    var id: Self { self }
    var title: String { rawValue.capitalized }
    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }
}

/// Everything the touch engine needs. A copy is handed to the engine whenever it changes,
/// so the engine never reads shared mutable state from its own queue.
struct EngineConfig: Codable, Equatable {
    var enabled = true
    var haptics = true
    var hapticStrength = HapticStrength.medium
    var hapticFeel = HapticFeel.standard
    /// What each zone does. Replaces v1.2's swapSides, quickMute, mediaStrip, mediaPlayPause and
    /// reverseMediaSwipe booleans, which are read once for migration and never written again.
    /// Qualified because SwiftUI also has a `Layout`.
    var layout = MarginCore.Layout.default
    /// Per-app overrides for trackpads. `Preferences` applies the frontmost app's on the main
    /// thread; the engine is handed the result.
    var profiles: [AppProfile] = []
    var bottomQuarterOnly = false
    /// Off by default: edge gestures only start while fn or ⌥ is held, so an edge touch never
    /// surprises anyone. v2.0's `requireModifier` (off by default) is not read, so every install
    /// starts with the modifier required.
    var useWithoutModifier = false
    var freezeCursor = true
    var preciseSliding = false
    var fineControl = true          // hold Shift-Option for finer changes
    var includeExternal = true
    var magicMouse = false
    /// 0.5 (slow) … 2.0 (fast).
    var sensitivity = 1.0
    /// Fraction of the trackpad width that counts as an edge.
    var edgeWidth = 0.08
    /// Settings → Timer. The engine only needs the alarm, and gets that from `setAlarm`.
    var timer = TimerSettings()

    /// Whether a gesture may start with the given keys held.
    func allowsGesture(with mods: NSEvent.ModifierFlags) -> Bool {
        useWithoutModifier || mods.contains(.function) || mods.contains(.option)
    }

    init() {}

    // Decode field by field so settings saved by an older build keep working after new options are added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EngineConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        haptics = try c.decodeIfPresent(Bool.self, forKey: .haptics) ?? d.haptics
        hapticStrength = try c.decodeIfPresent(HapticStrength.self, forKey: .hapticStrength) ?? d.hapticStrength
        hapticFeel = try c.decodeIfPresent(HapticFeel.self, forKey: .hapticFeel) ?? d.hapticFeel
        // Settings saved by v1.2 have no layout; it's rebuilt from their old booleans.
        layout = try SettingsMigration.decodeLayout(from: decoder)
        // Like the layout, unreadable profiles are dropped rather than resetting everything.
        profiles = (try? c.decodeIfPresent([AppProfile].self, forKey: .profiles)) ?? d.profiles
        bottomQuarterOnly = try c.decodeIfPresent(Bool.self, forKey: .bottomQuarterOnly) ?? d.bottomQuarterOnly
        useWithoutModifier = try c.decodeIfPresent(Bool.self, forKey: .useWithoutModifier) ?? d.useWithoutModifier
        freezeCursor = try c.decodeIfPresent(Bool.self, forKey: .freezeCursor) ?? d.freezeCursor
        preciseSliding = try c.decodeIfPresent(Bool.self, forKey: .preciseSliding) ?? d.preciseSliding
        fineControl = try c.decodeIfPresent(Bool.self, forKey: .fineControl) ?? d.fineControl
        includeExternal = try c.decodeIfPresent(Bool.self, forKey: .includeExternal) ?? d.includeExternal
        magicMouse = try c.decodeIfPresent(Bool.self, forKey: .magicMouse) ?? d.magicMouse
        sensitivity = try c.decodeIfPresent(Double.self, forKey: .sensitivity) ?? d.sensitivity
        edgeWidth = try c.decodeIfPresent(Double.self, forKey: .edgeWidth) ?? d.edgeWidth
        timer = (try? c.decodeIfPresent(TimerSettings.self, forKey: .timer)) ?? d.timer
    }
}

extension Notification.Name {
    static let marginConfigChanged = Notification.Name("MarginConfigChanged")
}

@Observable
final class Preferences {
    static let shared = Preferences()

    private static let configKey = "engineConfig"
    private static let appearanceKey = "appearance"

    var config: EngineConfig {
        didSet {
            guard config != oldValue else { return }
            if let data = try? JSONEncoder().encode(config) {
                UserDefaults.standard.set(data, forKey: Self.configKey)
            }
            // Any settings change goes to the engine, as before profiles existed.
            pushToEngine()
            NotificationCenter.default.post(name: .marginConfigChanged, object: oldValue)
        }
    }

    var appearance: Appearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Self.appearanceKey) }
    }

    /// Follows the frontmost app. Observed, so the status line and the profile list update.
    private(set) var tracker: ProfileTracker

    /// The profile in charge of the trackpads right now, for the status line.
    var activeProfile: AppProfile? { tracker.activeProfile(in: config.profiles) }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.configKey),
           let saved = try? JSONDecoder().decode(EngineConfig.self, from: data) {
            config = saved
        } else {
            config = EngineConfig()
        }
        appearance = UserDefaults.standard.string(forKey: Self.appearanceKey).flatMap(Appearance.init) ?? .system
        tracker = ProfileTracker(ownBundleID: Bundle.main.bundleIdentifier,
                                  frontmostBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)

        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main
        ) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            self?.appActivated(app)
        }
    }

    /// Hands the engine the settings with the trackpad layout for the frontmost app.
    func pushToEngine() {
        let layout = tracker.effective(global: config.layout, profiles: config.profiles)
        tracker.didApply(layout)
        TouchEngine.shared.update(config, trackpadLayout: layout)
    }

    private func appActivated(_ app: NSRunningApplication?) {
        guard let app, tracker.activate(app.bundleIdentifier) else { return }
        if let bundleID = app.bundleIdentifier, let name = app.localizedName {
            // Goes through `config`, so it's saved and the engine updated if the name changed.
            config.profiles.refreshName(bundleID: bundleID, name: name)
        }
        // Most switches are between apps with no profile; those leave the engine alone.
        if let layout = tracker.layoutToApply(global: config.layout, profiles: config.profiles) {
            TouchEngine.shared.update(config, trackpadLayout: layout)
        }
    }

    // MARK: Editing profiles

    func addProfile(for app: NSRunningApplication) {
        guard let bundleID = app.bundleIdentifier else { return }
        addProfile(bundleID: bundleID, name: app.localizedName ?? bundleID)
    }

    func addProfile(bundleID: String, name: String) {
        config.profiles.addProfile(bundleID: bundleID, name: name)
    }

    func removeProfile(_ bundleID: String) {
        config.profiles.removeProfile(bundleID: bundleID)
    }

    func profile(_ bundleID: String) -> AppProfile? {
        config.profiles.first { $0.bundleID == bundleID }
    }

    /// Changes one profile in place; does nothing if it was removed meanwhile.
    func editProfile(_ bundleID: String, _ edit: (inout AppProfile) -> Void) {
        guard let i = config.profiles.firstIndex(where: { $0.bundleID == bundleID }) else { return }
        edit(&config.profiles[i])
    }
}
