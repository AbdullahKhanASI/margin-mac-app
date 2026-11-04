import AppKit
import Carbon
import MarginCore
import SwiftUI

/// Names keys the way the current keyboard layout prints them, so ⌘Z on a German keyboard
/// reads ⌘Y. The rules for modifiers and the keys every layout names alike are in MarginCore.
enum KeyNames {
    static func display(_ combo: KeyCombo) -> String {
        combo.displayString(character: character)
    }

    /// The character a key types with no modifiers, or nil for keys that type nothing.
    static func character(_ keyCode: UInt16) -> String? {
        // Input methods such as Japanese have no key layout of their own; their ASCII-capable
        // layout is what shortcuts are typed on.
        let layoutData = [TISCopyCurrentKeyboardLayoutInputSource, TISCopyCurrentASCIICapableKeyboardLayoutInputSource]
            .lazy
            .compactMap { copy -> CFData? in
                guard let source = copy()?.takeRetainedValue(),
                      let pointer = TISGetInputSourceProperty(source, kTISPropertyUnicodeKeyLayoutData)
                else { return nil }
                return Unmanaged<CFData>.fromOpaque(pointer).takeUnretainedValue()
            }
            .first
        guard let layoutData, let bytes = CFDataGetBytePtr(layoutData) else { return nil }

        var deadKeys: UInt32 = 0
        var length = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let status = bytes.withMemoryRebound(to: UCKeyboardLayout.self, capacity: 1) { layout in
            UCKeyTranslate(layout, keyCode, UInt16(kUCKeyActionDisplay), 0, UInt32(LMGetKbdType()),
                           OptionBits(1 << kUCKeyTranslateNoDeadKeysBit), &deadKeys, 4, &length, &chars)
        }
        guard status == noErr, length > 0 else { return nil }
        let text = String(utf16CodeUnits: chars, count: length)
        return text.unicodeScalars.allSatisfy { CharacterSet.controlCharacters.contains($0) } ? nil : text
    }
}

/// Click, press a shortcut, and it's recorded. While recording it takes the panel's key presses
/// ahead of its own shortcuts, so Escape cancels the recording rather than closing the menu.
struct ShortcutRecorderRow: View {
    let combo: KeyCombo?
    /// Start listening as soon as the row appears: the user has just chosen Keystroke….
    let recordOnAppear: Bool
    let record: (KeyCombo) -> Void
    let cancel: () -> Void

    @State private var recording = false
    @State private var rules = ShortcutRecording()
    @State private var message: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(action: { recording ? stop(cancelled: true) : start() }) {
                HStack {
                    Image(systemName: "keyboard")
                    Text(label)
                        .font(recording ? .body : .body.monospaced())
                        .foregroundStyle(recording ? .secondary : .primary)
                    Spacer()
                    if recording {
                        Text("Esc to cancel").font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(recording ? Color.accentColor : Color(nsColor: .separatorColor)))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if let message {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { if recordOnAppear { start() } }
        .onDisappear { if recording { stop(cancelled: true) } }
    }

    private var label: String {
        if recording { return "Press a shortcut…" }
        return combo.map(KeyNames.display) ?? "Click to record"
    }

    private func start() {
        rules = ShortcutRecording()
        message = nil
        recording = true
        MenuPanel.shared.keyInterceptor = { event in
            handle(event)
            return nil
        }
    }

    private func stop(cancelled: Bool) {
        recording = false
        MenuPanel.shared.keyInterceptor = nil
        if cancelled { cancel() }
    }

    private func handle(_ event: NSEvent) {
        let modifiers = UInt64(event.modifierFlags.rawValue)
        let outcome: ShortcutRecording.Outcome
        switch event.type {
        case .keyDown:
            guard !event.isARepeat else { return }
            outcome = rules.keyDown(keyCode: event.keyCode, modifiers: modifiers)
        case .flagsChanged:
            outcome = rules.modifiersChanged(modifiers, at: event.timestamp)
        default:
            return
        }
        switch outcome {
        case .waiting:
            break
        case .recorded(let combo):
            stop(cancelled: false)
            record(combo)
        case .cancelled:
            stop(cancelled: true)
        case .keptBySystem:
            // Keep listening; the user can try another.
            message = "macOS keeps that shortcut for itself, so it can't be recorded. "
                + "⌘Tab and ⌘Space are two of these."
        }
    }
}
