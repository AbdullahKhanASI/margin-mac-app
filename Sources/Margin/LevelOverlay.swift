import AppKit
import Observation
import SwiftUI

enum LevelKind {
    case volume, brightness
}

/// A small pill in the middle of the screen showing the level being slid.
/// It follows the finger continuously and fades out shortly after the slide ends.
final class LevelOverlay {
    static let shared = LevelOverlay()

    private let model = OverlayModel()
    private var panel: NSPanel?
    private var hideWork: DispatchWorkItem?

    private static let size = NSSize(width: 300, height: 64)
    private static let lingerSeconds = 1.1

    func show(_ kind: LevelKind, level: Double, muted: Bool) {
        let panel = panel ?? makePanel()
        self.panel = panel

        model.kind = kind
        model.level = level
        model.muted = muted

        if !model.visible {
            position(panel)
            panel.orderFrontRegardless()
            model.visible = true
        }

        hideWork?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.model.visible = false }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.lingerSeconds, execute: work)
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
        panel.contentView = NSHostingView(rootView: OverlayView(model: model))
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

@Observable
private final class OverlayModel {
    var kind = LevelKind.volume
    var level = 0.0
    var muted = false
    var visible = false
}

private struct OverlayView: View {
    let model: OverlayModel

    private var symbol: String {
        switch model.kind {
        case .brightness:
            return model.level < 0.5 ? "sun.min.fill" : "sun.max.fill"
        case .volume:
            if model.muted || model.level == 0 { return "speaker.slash.fill" }
            if model.level < 0.34 { return "speaker.wave.1.fill" }
            if model.level < 0.67 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        }
    }

    private var shownLevel: Double { model.muted ? 0 : model.level }

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 26)
                .contentTransition(.symbolEffect(.replace))

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
        .padding(.horizontal, 20)
        .frame(width: 280, height: 48)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.primary.opacity(0.08)))
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
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
