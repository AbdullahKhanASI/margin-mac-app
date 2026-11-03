import AppKit
import SwiftUI

/// The first-run window: grant access, then try each gesture once. Steps tick themselves off
/// as the touch engine reports the gestures, so the user learns by doing.
final class SetupGuide {
    static let shared = SetupGuide()
    private static let seenKey = "setupGuideSeen"

    private var window: NSWindow?

    func showIfFirstLaunch() {
        guard !UserDefaults.standard.bool(forKey: Self.seenKey) else { return }
        show()
    }

    func show() {
        UserDefaults.standard.set(true, forKey: Self.seenKey)
        if window == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: SetupGuideView { [weak self] in
                self?.window?.close()
            }))
            window.title = "Welcome to Margin"
            window.styleMask = [.titled, .closable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.isReleasedWhenClosed = false
            window.center()
            self.window = window
        }
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }
}

private struct SetupGuideView: View {
    let done: () -> Void

    private let prefs = Preferences.shared
    private let state = AppState.shared
    @State private var completed = Set<String>()

    private var volumeSide: String { prefs.config.swapSides ? "left" : "right" }
    private var brightnessSide: String { prefs.config.swapSides ? "right" : "left" }

    /// Steps 1–3 are always shown; mute and the media strip are optional.
    private var loginStepNumber: Int {
        4 + (prefs.config.quickMute ? 1 : 0) + (prefs.config.mediaStrip ? 1 : 0)
    }

    private var accessibilityDetail: String {
        if state.accessibilityLikelyStale && !state.accessibilityTrusted {
            return "Already switched on but still not working? That's an old entry. Reset it, then switch Margin on again."
        }
        return "Lets Margin hold the pointer still and change levels."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your trackpad edges are now controls.")
                    .font(.title2.weight(.semibold))
                Text("Try each one below. Steps tick off as you do them.")
                    .foregroundStyle(.secondary)
            }

            VStack(spacing: 10) {
                Step(
                    number: 1,
                    title: "Allow Accessibility access",
                    detail: accessibilityDetail,
                    done: state.accessibilityTrusted
                ) {
                    if !state.accessibilityTrusted {
                        if state.accessibilityLikelyStale {
                            Button("Reset") { state.resetAccessibility() }.controlSize(.small)
                        } else {
                            Button("Open Settings") { state.requestAccessibility() }.controlSize(.small)
                        }
                    }
                }
                Step(number: 2, title: "Slide along the \(volumeSide) edge",
                     detail: "Up for louder, down for quieter.", done: completed.contains("volume")) {}
                Step(number: 3, title: "Slide along the \(brightnessSide) edge",
                     detail: "Up for brighter, down for dimmer.", done: completed.contains("brightness")) {}
                if prefs.config.quickMute {
                    Step(number: 4, title: "Double-tap the top-right corner",
                         detail: "Mutes and unmutes. You'll feel a stronger buzz.", done: completed.contains("mute")) {}
                }
                if prefs.config.mediaStrip {
                    Step(number: loginStepNumber - 1, title: "Swipe along the bottom edge",
                         detail: "Right to skip ahead, left to go back.", done: completed.contains("skip")) {}
                }
                Step(number: loginStepNumber, title: "Open Margin at login",
                     detail: "So your edges keep working after a restart.", done: state.launchAtLogin) {
                    if !state.launchAtLogin {
                        Button("Turn On") { state.launchAtLogin = true }.controlSize(.small)
                    }
                }
            }

            HStack {
                Text("Margin lives in your menu bar.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done", action: done)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .padding(.top, 8)
        .frame(width: 440)
        .preferredColorScheme(prefs.appearance.colorScheme)
        .onReceive(NotificationCenter.default.publisher(for: .marginGestureCompleted)) { note in
            guard let gesture = note.object as? CompletedGesture else { return }
            let key: String? = switch gesture {
            case .volume: "volume"
            case .brightness: "brightness"
            case .mute: "mute"
            case .skip: "skip"
            case .playPause: nil
            }
            if let key {
                withAnimation(.spring(duration: 0.3)) { _ = completed.insert(key) }
            }
        }
    }
}

private struct Step<Accessory: View>: View {
    let number: Int
    let title: String
    let detail: String
    let done: Bool
    @ViewBuilder let accessory: Accessory

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(done ? Color.green : Color.secondary.opacity(0.15))
                if done {
                    Image(systemName: "checkmark").font(.caption.weight(.bold)).foregroundStyle(.white)
                } else {
                    Text("\(number)").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                }
            }
            .frame(width: 24, height: 24)

            VStack(alignment: .leading, spacing: 2) {
                Text(title).fontWeight(.medium)
                Text(detail).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            accessory
        }
        .padding(12)
        .background(.quaternary.opacity(done ? 0.3 : 0.6), in: RoundedRectangle(cornerRadius: 10))
        .opacity(done ? 0.75 : 1)
    }
}
