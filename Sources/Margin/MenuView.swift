import Combine
import MarginCore
import SwiftUI

extension Notification.Name {
    /// Development aid (`--open-panel --settings`): flips the menu to its Settings page.
    static let marginShowSettings = Notification.Name("MarginShowSettings")
    /// Posted when the menu bar panel closes, so it reopens on the home page.
    static let marginPanelClosed = Notification.Name("MarginPanelClosed")
}

struct MenuView: View {
    @Bindable private var prefs = Preferences.shared
    private let state = AppState.shared
    @State private var showingSettings: Bool

    init(showingSettings: Bool = false) {
        _showingSettings = State(initialValue: showingSettings)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if showingSettings {
                SettingsPage(prefs: prefs, state: state) { showingSettings = false }
            } else {
                mainPage
            }
        }
        .padding(14)
        .frame(width: 300)
        .preferredColorScheme(prefs.appearance.colorScheme)
        .onAppear { state.refreshLevels() }
        .onReceive(NotificationCenter.default.publisher(for: .marginShowSettings)) { _ in showingSettings = true }
        .onReceive(NotificationCenter.default.publisher(for: .marginPanelClosed)) { _ in showingSettings = false }
        .onReceive(NotificationCenter.default.publisher(for: .marginLevelsChanged)
            .debounce(for: .milliseconds(60), scheduler: RunLoop.main)) { _ in
            state.refreshLevels()
        }
        .onReceive(Timer.publish(every: 1, on: .main, in: .common).autoconnect()) { _ in
            state.refreshLevels()
        }
    }

    private var status: StatusChip.Status {
        if !prefs.config.enabled { return .off }
        if !state.accessibilityTrusted { return .needsAccess }
        if !state.multitouchAvailable || state.trackpadCount == 0 { return .noTrackpad }
        return .ready
    }

    private var feelDescription: String {
        let feel = prefs.config.hapticFeel
        let character = switch feel {
        case .clicky: "Fewer, distinct clicks"
        case .standard: "Balanced"
        case .rich: "Dense and smooth"
        }
        return "\(character): \(Int(feel.notches)) ticks from 0 to 100%"
    }

    @ViewBuilder private var mainPage: some View {
        HStack {
            Text("Margin").font(.headline)
            Spacer()
            StatusChip(status: status)
            Toggle("Enabled", isOn: $prefs.config.enabled)
                .toggleStyle(.switch)
                .controlSize(.small)
                .labelsHidden()
        }

        if !state.accessibilityTrusted && state.accessibilityLikelyStale {
            Notice(
                symbol: "lock.trianglebadge.exclamationmark",
                text: "Margin may already be switched on in Accessibility settings, but macOS isn't honouring it "
                    + "(this happens after an update). Reset the permission, then switch Margin on again.",
                action: "Reset Permission"
            ) { state.resetAccessibility() }
        } else if !state.accessibilityTrusted {
            Notice(
                symbol: "lock.shield",
                text: "Margin needs Accessibility access to change volume and brightness and to hold the pointer still.",
                action: "Grant Access"
            ) { state.requestAccessibility() }
        } else if !state.multitouchAvailable {
            Notice(symbol: "exclamationmark.triangle", text: "This version of macOS doesn't expose trackpad touches.")
        } else if state.trackpadCount == 0 {
            Notice(symbol: "rectangle.dashed", text: "No trackpad found. Margin will pick one up when it connects.")
        }

        TrackpadDiagram(
            config: prefs.config,
            volume: state.muted ? 0 : state.volume,
            muted: state.muted,
            brightness: state.brightness
        )
        .opacity(prefs.config.enabled ? 1 : 0.45)

        VStack(spacing: 8) {
            SwitchRow("Haptic Feedback", isOn: $prefs.config.haptics)
            if prefs.config.haptics {
                LabeledPicker(title: "Strength", selection: $prefs.config.hapticStrength)
                LabeledPicker(title: "Feel", selection: $prefs.config.hapticFeel)
                Text(feelDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            SwitchRow("Quick Mute", detail: "Double-tap the top-right corner", isOn: prefs.layoutToggle(\.quickMute))
            SwitchRow("Media Strip", detail: "Swipe the bottom edge to skip", isOn: prefs.layoutToggle(\.mediaStrip))
            if prefs.config.layout.mediaStrip {
                SwitchRow("Tap to Play or Pause", detail: "Double-tap the bottom edge",
                          isOn: prefs.layoutToggle(\.mediaPlayPause))
                    .padding(.leading, 14)
            }
        }

        Divider()

        LabeledSlider(title: "Sensitivity", value: $prefs.config.sensitivity, range: 0.5...2.0,
                      low: "slow", high: "fast",
                      readout: String(format: "%.1f×", prefs.config.sensitivity))
        LabeledSlider(title: "Edge Width", value: $prefs.config.edgeWidth, range: 0.04...0.15,
                      low: "thin", high: "wide",
                      readout: "\(Int((prefs.config.edgeWidth * 100).rounded()))%")

        Divider()

        HStack {
            Button {
                showingSettings = true
            } label: {
                Label("Settings", systemImage: "gearshape")
            }
            Spacer()
            Button("Quit") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .buttonStyle(.borderless)
    }
}

private struct SettingsPage: View {
    @Bindable var prefs: Preferences
    @Bindable var state: AppState
    let back: () -> Void

    var body: some View {
        HStack {
            Button(action: back) {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            Spacer()
            Text("Settings").font(.headline)
            Spacer()
            // Balances the back button so the title stays centred.
            Label("Back", systemImage: "chevron.left").hidden()
        }

        Section("Edges") {
            SwitchRow("Swap Sides", detail: "Volume on the left, brightness on the right", isOn: prefs.layoutToggle(\.sidesSwapped))
            SwitchRow("Bottom Quarter Only", detail: "Ignore touches above the lower 25%",
                      isOn: $prefs.config.bottomQuarterOnly)
            SwitchRow("Require fn or ⌥", detail: "Only slide while holding a modifier",
                      isOn: $prefs.config.requireModifier)
        }

        Section("While Sliding") {
            SwitchRow("Freeze Cursor", detail: "The pointer stays hidden and still", isOn: $prefs.config.freezeCursor)
            SwitchRow("Fine Control", detail: "Hold ⇧⌥ for slower, finer changes", isOn: $prefs.config.fineControl)
            SwitchRow("Precise Sliding", detail: "Always slow and fine, no keys needed",
                      isOn: $prefs.config.preciseSliding)
        }

        Section("Media Strip") {
            SwitchRow("Reverse Swipe", detail: "Swipe left to skip ahead", isOn: prefs.layoutToggle(\.reverseMediaSwipe))
                // With the strip off there's no flick to reverse, so the switch would do nothing.
                .disabled(!prefs.config.layout.mediaStrip)
        }

        Section("Devices") {
            SwitchRow("External Magic Trackpad", isOn: $prefs.config.includeExternal)
            SwitchRow("Magic Mouse", detail: "Slide on the mouse's top edges", isOn: $prefs.config.magicMouse)
        }

        Section("General") {
            SwitchRow("Open at Login", isOn: $state.launchAtLogin)
            Picker("Appearance", selection: $prefs.appearance) {
                ForEach(Appearance.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .controlSize(.small)
        }

        HStack {
            Button("Setup Guide…") { SetupGuide.shared.show() }
                .buttonStyle(.borderless)
            Spacer()
            Text("Version \(appVersion)")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 4)
    }

    private var appVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }
}

extension Preferences {
    /// A menu switch that edits the layout. These stand in for the zone editor until phase 3
    /// replaces them; the rules for each live with the layout in MarginCore.
    func layoutToggle(_ keyPath: WritableKeyPath<MarginCore.Layout, Bool>) -> Binding<Bool> {
        Binding(get: { self.config.layout[keyPath: keyPath] },
                set: { self.config.layout[keyPath: keyPath] = $0 })
    }
}

// MARK: - Trackpad diagram

private struct TrackpadDiagram: View {
    let config: EngineConfig
    let volume: Float
    let muted: Bool
    let brightness: Float?

    var body: some View {
        let volumeMeter = EdgeMeter(level: Double(volume),
                                    symbol: muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                                    ramp: .volume)
        let brightnessMeter = EdgeMeter(level: Double(brightness ?? 0),
                                        symbol: "sun.max.fill",
                                        ramp: .brightness,
                                        unavailable: brightness == nil)

        ZStack {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(.quaternary.opacity(0.6))
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.separator)

            HStack {
                if config.layout.sidesSwapped { volumeMeter } else { brightnessMeter }
                Spacer()
                if config.layout.sidesSwapped { brightnessMeter } else { volumeMeter }
            }
            .padding(10)

            if config.layout.mediaStrip {
                VStack {
                    Spacer()
                    HStack(spacing: 18) {
                        Image(systemName: "backward.fill")
                        Image(systemName: "playpause.fill")
                        Image(systemName: "forward.fill")
                    }
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
                    .padding(.horizontal, 12)
                    .background(.quaternary, in: Capsule())
                    .padding(.bottom, 8)
                }
            }

            if config.layout.quickMute {
                VStack {
                    HStack {
                        Spacer()
                        Image(systemName: "speaker.slash")
                            .font(.caption2)
                            .foregroundStyle(muted ? Color.accentColor : .secondary)
                            .padding(5)
                            .background(.quaternary, in: Circle())
                    }
                    Spacer()
                }
                .padding(.top, 8)
                .padding(.trailing, 34)
            }
        }
        .frame(height: 150)
        .animation(.easeOut(duration: 0.15), value: volume)
        .animation(.easeOut(duration: 0.15), value: brightness)
    }
}

/// A colour that changes with the level, so a meter reads at a glance.
private struct ColorRamp {
    let low: (r: Double, g: Double, b: Double)
    let high: (r: Double, g: Double, b: Double)

    /// Deep amber when dim, warm bright yellow when bright.
    static let brightness = ColorRamp(low: (0.85, 0.36, 0.08), high: (1.0, 0.86, 0.32))
    /// Dim navy when quiet, vivid sky blue when loud.
    static let volume = ColorRamp(low: (0.16, 0.26, 0.62), high: (0.36, 0.74, 1.0))

    func color(at t: Double) -> Color {
        let t = min(max(t, 0), 1)
        return Color(red: low.r + (high.r - low.r) * t,
                     green: low.g + (high.g - low.g) * t,
                     blue: low.b + (high.b - low.b) * t)
    }
}

private struct EdgeMeter: View {
    let level: Double
    let symbol: String
    let ramp: ColorRamp
    var unavailable = false

    var body: some View {
        VStack(spacing: 6) {
            Text(unavailable ? "–" : "\(Int((level * 100).rounded()))")
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.secondary)
            GeometryReader { geo in
                ZStack(alignment: .bottom) {
                    Capsule().fill(.quaternary)
                    // The bar's top colour follows the level; its base stays at the low end of the ramp.
                    Capsule()
                        .fill(LinearGradient(colors: [ramp.color(at: 0), ramp.color(at: level)],
                                             startPoint: .bottom, endPoint: .top))
                        .frame(height: geo.size.height * min(max(level, 0), 1))
                }
            }
            .frame(width: 8)
            Image(systemName: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(width: 24)
    }
}

// MARK: - Building blocks

private struct SwitchRow: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool

    init(_ title: String, detail: String? = nil, isOn: Binding<Bool>) {
        self.title = title
        self.detail = detail
        self._isOn = isOn
    }

    var body: some View {
        Toggle(isOn: $isOn) {
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                if let detail {
                    Text(detail).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .toggleStyle(.switch)
        .controlSize(.mini)
    }
}

private struct LabeledSlider: View {
    let title: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    let low: String
    let high: String
    let readout: String

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                Text(title)
                Spacer()
                Text(readout)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 6) {
                Text(low).font(.caption).foregroundStyle(.secondary)
                Slider(value: $value, in: range).controlSize(.small)
                Text(high).font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

private struct LabeledPicker<Option: Hashable & Identifiable & CaseIterable>: View
where Option.AllCases: RandomAccessCollection, Option: HasTitle {
    let title: String
    @Binding var selection: Option

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(width: 52, alignment: .leading)
            Picker(title, selection: $selection) {
                ForEach(Option.allCases) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)
        }
    }
}

protocol HasTitle {
    var title: String { get }
}

extension HapticStrength: HasTitle {}
extension HapticFeel: HasTitle {}

private struct StatusChip: View {
    enum Status { case ready, off, needsAccess, noTrackpad }
    let status: Status

    private var label: (String, Color) {
        switch status {
        case .ready: ("Ready", .green)
        case .off: ("Off", .secondary)
        case .needsAccess: ("Needs Access", .orange)
        case .noTrackpad: ("No Trackpad", .orange)
        }
    }

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(label.1).frame(width: 6, height: 6)
            Text(label.0).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct Notice: View {
    let symbol: String
    let text: String
    var action: String?
    var perform: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: symbol).foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 6) {
                Text(text).font(.caption).fixedSize(horizontal: false, vertical: true)
                if let action {
                    Button(action, action: perform).controlSize(.small)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}

private struct Section<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased())
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
            content
        }
        .padding(.top, 4)
    }
}
