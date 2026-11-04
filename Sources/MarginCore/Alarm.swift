import Foundation

/// How hard the alarm tries to get attention (spec decision 7). The motor can only be felt with a
/// finger on the glass, so the haptic alarm backs up the visual one rather than replacing it.
public enum AlarmIntensity: String, Codable, CaseIterable, Identifiable, Sendable {
    case gentle, normal, insistent

    public var id: Self { self }
    public var title: String { rawValue.capitalized }

    public var pattern: AlarmPattern {
        switch self {
        case .gentle: AlarmPattern(pulses: 1, spacing: 0, strong: false, repeatEvery: 4, stopsAfter: 60)
        case .normal: AlarmPattern(pulses: 3, spacing: 0.12, strong: true, repeatEvery: 4, stopsAfter: 120)
        case .insistent: AlarmPattern(pulses: 5, spacing: 0.1, strong: true, repeatEvery: 2, stopsAfter: 300)
        }
    }
}

/// One alarm intensity as plain data, so it can be tuned without touching the engine. The engine
/// plays `pulses` actuations `spacing` apart, every `repeatEvery` seconds while a finger rests
/// on the trackpad; `TimerService` stops the alarm after `stopsAfter`.
public struct AlarmPattern: Equatable, Sendable {
    public var pulses: Int
    public var spacing: TimeInterval
    /// Strong actuations, or medium ones.
    public var strong: Bool
    public var repeatEvery: TimeInterval
    public var stopsAfter: TimeInterval

    public init(pulses: Int, spacing: TimeInterval, strong: Bool, repeatEvery: TimeInterval, stopsAfter: TimeInterval) {
        self.pulses = pulses
        self.spacing = spacing
        self.strong = strong
        self.repeatEvery = repeatEvery
        self.stopsAfter = stopsAfter
    }

    /// When each pulse of one burst fires, from the start of the burst.
    public var pulseOffsets: [TimeInterval] {
        (0..<pulses).map { Double($0) * spacing }
    }

    /// Whether a burst is due: none has played yet, or the last began `repeatEvery` ago.
    public func burstDue(lastBurst: TimeInterval?, now: TimeInterval) -> Bool {
        guard let lastBurst else { return true }
        return now - lastBurst >= repeatEvery
    }
}

/// Settings → Timer. Stored inside `EngineConfig`, decoded field by field so that settings
/// saved before a field existed still load.
public struct TimerSettings: Codable, Equatable, Sendable {
    public var alarm = AlarmIntensity.normal
    public var playSound = false
    public var showNotification = false
    /// The names of Shortcuts to run with `shortcuts run`, or nil for none.
    public var startShortcut: String?
    public var endShortcut: String?

    public init() {}

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = TimerSettings()
        alarm = (try? c.decodeIfPresent(AlarmIntensity.self, forKey: .alarm)) ?? d.alarm
        playSound = try c.decodeIfPresent(Bool.self, forKey: .playSound) ?? d.playSound
        showNotification = try c.decodeIfPresent(Bool.self, forKey: .showNotification) ?? d.showNotification
        startShortcut = try c.decodeIfPresent(String.self, forKey: .startShortcut)
        endShortcut = try c.decodeIfPresent(String.self, forKey: .endShortcut)
    }
}
