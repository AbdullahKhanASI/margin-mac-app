import Foundation

extension KeyCombo {
    /// The modifiers a recorded shortcut keeps. Caps Lock and the numeric-pad bit are left out:
    /// they describe the keyboard's state, not the shortcut.
    public static let recordedModifiers = Modifier.shift | Modifier.control | Modifier.option | Modifier.command
        | Modifier.function

    /// The shortcut as menus write it, such as ⇧⌘K or ⌃→. Modifiers come in the order macOS uses,
    /// ⌃⌥⇧⌘. `character` names a key that types something (a letter, digit or punctuation) in the
    /// current keyboard layout; it lives in the app because the layout does.
    public func displayString(character: (UInt16) -> String?) -> String {
        var text = ""
        // fn is shown only where it's a deliberate part of the shortcut: arrows, F-keys and the
        // navigation keys carry it on every Apple keyboard.
        if modifiers & Modifier.function != 0, !Self.implicitlyFunction(keyCode) { text += "fn " }
        if modifiers & Modifier.control != 0 { text += "⌃" }
        if modifiers & Modifier.option != 0 { text += "⌥" }
        if modifiers & Modifier.shift != 0 { text += "⇧" }
        if modifiers & Modifier.command != 0 { text += "⌘" }
        let key = Self.fixedName(keyCode) ?? character(keyCode)?.uppercased() ?? "Key \(keyCode)"
        return text + key
    }

    /// Names for keys that don't type a character, the same on every layout. Nil for the rest.
    public static func fixedName(_ keyCode: UInt16) -> String? {
        switch keyCode {
        case 36: "↩"
        case 48: "⇥"
        case 49: "Space"
        case 51: "⌫"
        case 53: "⎋"
        case 76: "⌤"
        case 114: "Help"
        case 115: "↖"
        case 116: "⇞"
        case 117: "⌦"
        case 119: "↘"
        case 121: "⇟"
        case Key.leftArrow: "←"
        case Key.rightArrow: "→"
        case Key.downArrow: "↓"
        case Key.upArrow: "↑"
        default: functionKeys[keyCode].map { "F\($0)" }
        }
    }

    /// Key codes of F1–F20 (kVK_F*), which aren't in order.
    private static let functionKeys: [UInt16: Int] = [
        122: 1, 120: 2, 99: 3, 118: 4, 96: 5, 97: 6, 98: 7, 100: 8, 101: 9, 109: 10,
        103: 11, 111: 12, 105: 13, 107: 14, 113: 15, 106: 16, 64: 17, 79: 18, 80: 19, 90: 20,
    ]

    private static func implicitlyFunction(_ keyCode: UInt16) -> Bool {
        functionKeys[keyCode] != nil || (Key.leftArrow...Key.upArrow).contains(keyCode)
            || [114, 115, 116, 117, 119, 121].contains(keyCode)
    }
}

/// Turns the keys pressed while the recorder is listening into a shortcut.
///
/// Some shortcuts never reach an app: macOS takes ⌘Tab, ⌘Space and the other system shortcuts
/// before Margin can see them. All the recorder sees is the modifiers going down and back up with
/// no key in between, so that's what it reports, as long as the modifiers were held long enough
/// to mean a real attempt rather than a brush of ⌘.
public struct ShortcutRecording: Sendable {
    public enum Outcome: Equatable, Sendable {
        case waiting
        case recorded(KeyCombo)
        case cancelled
        /// Modifiers were held and let go with no key: macOS kept the shortcut.
        case keptBySystem
    }

    /// How long modifiers must be held, with no key arriving, before it counts as a swallowed
    /// shortcut.
    public static let attemptDuration = 0.25
    static let escape: UInt16 = 53

    private var modifiersDownAt: Double?
    private var keyArrived = false

    public init() {}

    public mutating func keyDown(keyCode: UInt16, modifiers: UInt64) -> Outcome {
        let mods = modifiers & KeyCombo.recordedModifiers
        // Escape on its own cancels, so it can't be recorded bare; with modifiers it's a shortcut.
        if keyCode == Self.escape, mods & ~KeyCombo.Modifier.function == 0 { return .cancelled }
        keyArrived = true
        return .recorded(KeyCombo(keyCode: keyCode, modifiers: mods))
    }

    public mutating func modifiersChanged(_ modifiers: UInt64, at time: Double) -> Outcome {
        // fn alone is the Globe key, which has a job of its own; it doesn't start an attempt.
        let held = modifiers & KeyCombo.recordedModifiers & ~KeyCombo.Modifier.function
        if held != 0 {
            if modifiersDownAt == nil {
                modifiersDownAt = time
                keyArrived = false
            }
            return .waiting
        }
        defer { modifiersDownAt = nil }
        guard let since = modifiersDownAt, !keyArrived, time - since >= Self.attemptDuration else { return .waiting }
        return .keptBySystem
    }
}
