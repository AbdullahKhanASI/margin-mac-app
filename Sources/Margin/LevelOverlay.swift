import AppKit
import Observation
import SwiftUI

enum LevelKind {
    case volume, brightness, inputVolume
}

/// A small pill in the middle of the screen showing the level being slid, a stepper's running
/// count or the timer dial. It follows the finger continuously and fades out shortly after the
/// slide ends. The timer's alarm is the exception: it stays until dismissed, and is the only
/// content that takes clicks.
final class LevelOverlay {
    static let shared = LevelOverlay()

    private let model = OverlayModel()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    private static let size = NSSize(width: 300, height: 64)
    private static let lingerSeconds = 1.1

    func show(_ kind: LevelKind, level: Double, muted: Bool) {
        model.counter = nil
        model.showingAlarm = false
        model.kind = kind
        model.level = level
        model.muted = muted
        present()
    }

    /// A stepper's symbol and running count, such as "Undo ×3", or the dial's "25 min" with
    /// a hint under it.
    func showCounter(symbol: String, label: String, detail: String? = nil) {
        model.counter = OverlayModel.Counter(symbol: symbol, label: label, detail: detail)
        model.showingAlarm = false
        present()
    }

    /// "Time's up", until `hideAlarm`. A slide meanwhile shows its level and then returns here.
    func showAlarm() {
        alarmActive = true
        model.showingAlarm = true
        present()
    }

    func hideAlarm() {
        guard alarmActive else { return }
        alarmActive = false
        if model.showingAlarm { hide() }
    }

    private var alarmActive = false

    private func present() {
        let panel = panel ?? makePanel()
        self.panel = panel
        panel.ignoresMouseEvents = !model.showingAlarm

        if !model.visible {
            position(panel)
            panel.orderFrontRegardless()
            model.visible = true
        }

        hideWork?.cancel()
        hideWork = nil
        guard !model.showingAlarm else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            if self.alarmActive { self.showAlarm() } else { self.hide() }
        }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lingerSeconds, execute: work)
    }

    private func hide() {
        hideWork?.cancel()
        hideWork = nil
        model.visible = false
        model.showingAlarm = false
        panel?.ignoresMouseEvents = true
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.size),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.overlayWindow)))
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        panel.contentView = ClickThroughHostingView(rootView: OverlayView(model: model))
        return panel
    }

    /// Centre of the screen the pointer is on.
    private func position(_ panel: NSPanel) {
        let mouse = NSEvent.mouseLocation
        let screen = NSScreen.screens.first { $0.frame.contains(mouse) } ?? NSScreen.main
        guard let frame = screen?.frame else { return }
        panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2,
                                     y: frame.midY - Self.size.height / 2))
    }
}

/// Takes the first click, so the alarm dismisses on one click without Margin being frontmost.
private final class ClickThroughHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

@Observable
private final class OverlayModel {
    var kind = LevelKind.volume
    var level = 0.0
    var muted = false
    var visible = false
    /// Set while showing a stepper; nil shows the level.
    var counter: Counter?
    /// Showing "Time's up", which takes priority over the level and the counter.
    var showingAlarm = false

    struct Counter: Equatable {
        var symbol: String
        var label: String
        var detail: String?
    }
}

private struct OverlayView: View {
    let model: OverlayModel

    private var symbol: String {
        if model.showingAlarm { return "alarm.fill" }
        if let counter = model.counter { return counter.symbol }
        switch model.kind {
        case .brightness:
            return model.level < 0.5 ? "sun.min.fill" : "sun.max.fill"
        case .volume:
            if model.muted || model.level == 0 { return "speaker.slash.fill" }
            if model.level < 0.34 { return "speaker.wave.1.fill" }
            if model.level < 0.67 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        case .inputVolume:
            return model.muted || model.level == 0 ? "mic.slash.fill" : "mic.fill"
        }
    }

    private var shownLevel: Double { model.muted ? 0 : model.level }

    @ViewBuilder private var levelBar: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.15))
                Capsule().fill(.primary)
                    .frame(width: max(geo.size.height, geo.size.width * shownLevel))
                    .opacity(shownLevel > 0 ? 1 : 0)
            }
        }
        .frame(height: 6)

        Text("\(Int((shownLevel * 100).rounded()))")
            .font(.system(size: 13, weight: .medium).monospacedDigit())
            .foregroundStyle(.secondary)
            .frame(width: 30, alignment: .trailing)
            .contentTransition(.identity)
            .transaction { $0.animation = nil }
    }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 26)
                .contentTransition(.symbolEffect(.replace))

            if model.showingAlarm {
                Text("Time's up · tap to dismiss")
                    .font(.system(size: 15, weight: .medium))
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else if let counter = model.counter {
                HStack(alignment: .firstTextBaseline) {
                    Text(counter.label)
                        .font(.system(size: 15, weight: .medium).monospacedDigit())
                    Spacer(minLength: 8)
                    if let detail = counter.detail {
                        Text(detail).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                .contentTransition(.identity)
                .transaction { $0.animation = nil }
            } else {
                levelBar
            }
        }
        .padding(.horizontal, 20)
        .frame(width: 280, height: 48)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .contentShape(Capsule())
        .onTapGesture {
            if model.showingAlarm { TimerService.shared.dismiss() }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        // A light spring smooths the per-frame updates without lagging behind the finger.
        .animation(.interactiveSpring(response: 0.18, dampingFraction: 0.9), value: model.level)
        .animation(.easeOut(duration: 0.15), value: model.kind)
        .opacity(model.visible ? 1 : 0)
        .scaleEffect(model.visible ? 1 : 0.96)
        .animation(.easeOut(duration: model.visible ? 0.12 : 0.3), value: model.visible)
        .preferredColorScheme(Preferences.shared.appearance.colorScheme)
    }
}
