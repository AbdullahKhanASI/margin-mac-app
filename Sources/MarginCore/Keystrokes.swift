import Foundation

extension KeyCombo {
    /// `CGEventFlags` bits, which are also `NSEvent.ModifierFlags` bits.
    public enum Modifier {
        public static let shift: UInt64 = 0x20000
        public static let control: UInt64 = 0x40000
        public static let option: UInt64 = 0x80000
        public static let command: UInt64 = 0x100000
        public static let numericPad: UInt64 = 0x200000
        public static let function: UInt64 = 0x800000
    }

    /// Virtual key codes from Carbon's Events.h (kVK_*), for the shortcuts Margin sends itself.
    public enum Key {
        public static let z: UInt16 = 6
        public static let q: UInt16 = 12
        public static let four: UInt16 = 21
        public static let tab: UInt16 = 48
        public static let f11: UInt16 = 103
        public static let leftArrow: UInt16 = 123
        public static let rightArrow: UInt16 = 124
        public static let downArrow: UInt16 = 125
        public static let upArrow: UInt16 = 126
    }

    /// The flags to post. A real keyboard marks arrow keys as numeric-pad and fn keys, and
    /// system shortcuts such as ⌃↓ only match when those bits are there too.
    public var postedFlags: UInt64 {
        (Key.leftArrow...Key.upArrow).contains(keyCode) ? modifiers | Modifier.numericPad | Modifier.function : modifiers
    }
}

extension Command {
    /// The keystrokes behind the system commands that are plain shortcuts. Nil for commands
    /// that work some other way. Show Desktop isn't here: it depends on the user's settings
    /// (see `ShowDesktopShortcut`).
    public var shortcut: KeyCombo? {
        typealias M = KeyCombo.Modifier
        typealias K = KeyCombo.Key
        switch self {
        case .lockScreen: return KeyCombo(keyCode: K.q, modifiers: M.control | M.command)
        case .screenshotRegion: return KeyCombo(keyCode: K.four, modifiers: M.shift | M.command)
        case .appWindows: return KeyCombo(keyCode: K.downArrow, modifiers: M.control)
        case .keystroke(let combo): return combo
        default: return nil
        }
    }
}

/// Show Desktop has no fixed shortcut: it's F11 by default and can be changed in Keyboard
/// Shortcuts, which store it as symbolic hot key 36. Until it's changed there's no entry at all,
/// and the default applies.
///
/// ⌘F3 (the spec's fallback) does nothing when posted: the Mission Control key on Apple keyboards
/// isn't the F3 key code. F11 with the fn bit, as macOS records it, works.
/// Verified on macOS 27 only; the spec asks for 14–16 too.
public enum ShowDesktopShortcut {
    public static let hotKeyID = "36"
    public static let fallback = KeyCombo(keyCode: KeyCombo.Key.f11, modifiers: KeyCombo.Modifier.function)

    /// The shortcut from `AppleSymbolicHotKeys` in `com.apple.symbolichotkeys`, or the F11
    /// default when it's missing, switched off or unreadable. Entries look like
    /// `{enabled = 1; value = {parameters = (65535, 103, 8388608); type = standard;};}`, where
    /// the parameters are the character, the key code and the modifier flags.
    public static func resolve(symbolicHotKeys: Any?) -> KeyCombo {
        guard let keys = symbolicHotKeys as? [String: Any],
              let entry = keys[hotKeyID] as? [String: Any],
              (entry["enabled"] as? NSNumber)?.boolValue == true,
              let value = entry["value"] as? [String: Any],
              let parameters = value["parameters"] as? [NSNumber], parameters.count >= 3,
              let keyCode = UInt16(exactly: parameters[1].intValue)
        else { return fallback }
        return KeyCombo(keyCode: keyCode, modifiers: parameters[2].uint64Value)
    }
}

extension Stepper {
    /// The shortcut for one notch forward (up a side edge, right along the top or bottom) and one
    /// back. Nil for steppers this build can't run yet.
    public var shortcuts: (forward: KeyCombo, back: KeyCombo)? {
        typealias M = KeyCombo.Modifier
        typealias K = KeyCombo.Key
        switch self {
        case .undoRedo:
            // Back undoes, like scrubbing back in time; forward redoes.
            return (KeyCombo(keyCode: K.z, modifiers: M.shift | M.command), KeyCombo(keyCode: K.z, modifiers: M.command))
        case .tabs:
            return (KeyCombo(keyCode: K.tab, modifiers: M.control), KeyCombo(keyCode: K.tab, modifiers: M.control | M.shift))
        case .spaces, .arrowKeys:
            return nil
        }
    }

    /// The overlay's running count, from the net number of notches since the finger landed:
    /// "Undo ×3", "Redo ×1", "Tab →2", "Tab ←1".
    public func label(count: Int) -> String {
        let n = abs(count)
        switch self {
        case .undoRedo:
            if count == 0 { return "Undo" }
            return count < 0 ? "Undo ×\(n)" : "Redo ×\(n)"
        case .tabs:
            if count == 0 { return "Tab" }
            return count < 0 ? "Tab ←\(n)" : "Tab →\(n)"
        case .spaces, .arrowKeys:
            // Not runnable yet; worded when they are.
            return "\(count)"
        }
    }
}

/// Counts haptic notches along an edge on a fixed grid, the way `step()` counts a level's
/// detents, so a stepper's notches are as far apart under the finger as the volume edge's.
public struct DetentCounter: Equatable, Sendable {
    /// Where the slide engaged; notch 0 is centred on it.
    public var origin: Double
    /// Travel between notches.
    public var spacing: Double
    /// The notch the finger was last on, signed: positive is forward.
    public private(set) var notch = 0

    public init(origin: Double, spacing: Double) {
        self.origin = origin
        self.spacing = spacing
    }

    /// The spacing `step()` gives a level: `notches` across the travel that sweeps 0–100%.
    public static func spacing(fullRange: Double, sensitivity: Double, notches: Double) -> Double {
        fullRange / sensitivity / notches
    }

    /// Moves to `position` and returns how many notches were crossed since the last call:
    /// positive forward, negative back. Each crossed notch fires one command.
    public mutating func move(to position: Double) -> Int {
        let new = Int(((position - origin) / spacing).rounded())
        defer { notch = new }
        return new - notch
    }

    /// Keeps the count when the finger is picked back up after a dropout at a slightly
    /// different place, as `step()` does by shifting its origin.
    public mutating func shift(by delta: Double) {
        origin += delta
    }
}
