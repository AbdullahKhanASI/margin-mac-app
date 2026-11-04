import AppKit
import MarginCore
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
    @State private var completed = Set<GestureStep.ID>()

    private var gestureSteps: [GestureStep] { GestureStep.steps(for: prefs.config.layout) }
    /// Accessibility is step 1, then the gestures, then login.
    private var loginStepNumber: Int { gestureSteps.count + 2 }

    private var accessibilityDetail: String {
        if state.accessibilityLikelyStale && !state.accessibilityTrusted {
            return "Already switched on but still not working? That's an old entry. Reset it, then switch Margin on again."
        }
        return "Lets Margin hold the pointer still and change levels."
    }

    private var tryHint: String {
        if prefs.config.useWithoutModifier {
            return "Try each one below. Steps tick off as you do them."
        }
        return "Hold fn or ⌥ (Option) while you try each one below. Steps tick off as you do them. "
            + "To use them without a key, turn on Settings → Use without Fn or Option key."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Your trackpad edges are now controls.")
                    .font(.title2.weight(.semibold))
                Text(tryHint)
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
                ForEach(Array(gestureSteps.enumerated()), id: \.element.id) { index, step in
                    Step(number: index + 2, title: step.title, detail: step.detail,
                         done: completed.contains(step.id)) {}
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
            guard let (zone, kind) = note.object as? (Zone, GestureKind) else { return }
            let id = GestureStep.ID(zone: zone, kind: kind)
            guard gestureSteps.contains(where: { $0.id == id }) else { return }
            withAnimation(.spring(duration: 0.3)) { _ = completed.insert(id) }
        }
    }
}

/// One "try this gesture" step, derived from a binding in the global layout.
private struct GestureStep: Identifiable {
    struct ID: Hashable {
        let zone: Zone
        let kind: GestureKind
    }

    let id: ID
    let title: String
    let detail: String

    /// In v1.2's order: level slides (volume, then brightness), corner taps, then flicks. Edge
    /// double-taps get no step, as play/pause had none in v1.2; the zone editor (phase 3) is the
    /// place to describe the rest. Phase 1 only describes what the engine can run.
    static func steps(for layout: MarginCore.Layout) -> [GestureStep] {
        var steps: [GestureStep] = []
        let edgeOrder: [Zone] = [.rightEdge, .leftEdge, .topEdge, .bottomEdge]

        for (source, detail) in [(LevelSource.outputVolume, "Up for louder, down for quieter."),
                                 (.brightness, "Up for brighter, down for dimmer.")] {
            for zone in edgeOrder where layout.edge(zone).slide == .level(source) {
                steps.append(GestureStep(id: ID(zone: zone, kind: .slide),
                                         title: "Slide along the \(zone.name)", detail: detail))
            }
        }
        for zone in Zone.corners where layout.corner(zone) == .toggleOutputMute {
            steps.append(GestureStep(id: ID(zone: zone, kind: .doubleTap), title: "Double-tap the \(zone.name)",
                                     detail: "Mutes and unmutes. You'll feel a stronger buzz."))
        }
        for zone in edgeOrder {
            guard case .flick(let forward, let back) = layout.edge(zone).slide,
                  [forward, back] == [.media(.next), .media(.previous)]
                    || [forward, back] == [.media(.previous), .media(.next)] else { continue }
            // Worded as in v1.2, which didn't mention Reverse Swipe either.
            steps.append(GestureStep(id: ID(zone: zone, kind: .slide), title: "Swipe along the \(zone.name)",
                                     detail: "Right to skip ahead, left to go back."))
        }
        return Array(steps.prefix(6))
    }
}

private extension Zone {
    var name: String {
        switch self {
        case .leftEdge: "left edge"
        case .rightEdge: "right edge"
        case .topEdge: "top edge"
        case .bottomEdge: "bottom edge"
        case .topLeft: "top-left corner"
        case .topRight: "top-right corner"
        case .bottomLeft: "bottom-left corner"
        case .bottomRight: "bottom-right corner"
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
