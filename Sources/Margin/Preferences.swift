import Foundation
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
    var quickMute = true
    var mediaStrip = true
    var mediaPlayPause = true
    var reverseMediaSwipe = false
    var swapSides = false
    var bottomQuarterOnly = false
    var requireModifier = false
    var freezeCursor = true
    var preciseSliding = false
    var fineControl = true          // hold Shift-Option for finer changes
    var includeExternal = true
    var magicMouse = false
    /// 0.5 (slow) … 2.0 (fast).
    var sensitivity = 1.0
    /// Fraction of the trackpad width that counts as an edge.
    var edgeWidth = 0.08

    init() {}

    // Decode field by field so settings saved by an older build keep working after new options are added.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = EngineConfig()
        enabled = try c.decodeIfPresent(Bool.self, forKey: .enabled) ?? d.enabled
        haptics = try c.decodeIfPresent(Bool.self, forKey: .haptics) ?? d.haptics
        hapticStrength = try c.decodeIfPresent(HapticStrength.self, forKey: .hapticStrength) ?? d.hapticStrength
        hapticFeel = try c.decodeIfPresent(HapticFeel.self, forKey: .hapticFeel) ?? d.hapticFeel
        quickMute = try c.decodeIfPresent(Bool.self, forKey: .quickMute) ?? d.quickMute
        mediaStrip = try c.decodeIfPresent(Bool.self, forKey: .mediaStrip) ?? d.mediaStrip
        mediaPlayPause = try c.decodeIfPresent(Bool.self, forKey: .mediaPlayPause) ?? d.mediaPlayPause
        reverseMediaSwipe = try c.decodeIfPresent(Bool.self, forKey: .reverseMediaSwipe) ?? d.reverseMediaSwipe
        swapSides = try c.decodeIfPresent(Bool.self, forKey: .swapSides) ?? d.swapSides
        bottomQuarterOnly = try c.decodeIfPresent(Bool.self, forKey: .bottomQuarterOnly) ?? d.bottomQuarterOnly
        requireModifier = try c.decodeIfPresent(Bool.self, forKey: .requireModifier) ?? d.requireModifier
        freezeCursor = try c.decodeIfPresent(Bool.self, forKey: .freezeCursor) ?? d.freezeCursor
        preciseSliding = try c.decodeIfPresent(Bool.self, forKey: .preciseSliding) ?? d.preciseSliding
        fineControl = try c.decodeIfPresent(Bool.self, forKey: .fineControl) ?? d.fineControl
        includeExternal = try c.decodeIfPresent(Bool.self, forKey: .includeExternal) ?? d.includeExternal
        magicMouse = try c.decodeIfPresent(Bool.self, forKey: .magicMouse) ?? d.magicMouse
        sensitivity = try c.decodeIfPresent(Double.self, forKey: .sensitivity) ?? d.sensitivity
        edgeWidth = try c.decodeIfPresent(Double.self, forKey: .edgeWidth) ?? d.edgeWidth
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
            TouchEngine.shared.update(config)
            NotificationCenter.default.post(name: .marginConfigChanged, object: oldValue)
        }
    }

    var appearance: Appearance {
        didSet { UserDefaults.standard.set(appearance.rawValue, forKey: Self.appearanceKey) }
    }

    private init() {
        if let data = UserDefaults.standard.data(forKey: Self.configKey),
           let saved = try? JSONDecoder().decode(EngineConfig.self, from: data) {
            config = saved
        } else {
            config = EngineConfig()
        }
        appearance = UserDefaults.standard.string(forKey: Self.appearanceKey).flatMap(Appearance.init) ?? .system
    }
}
