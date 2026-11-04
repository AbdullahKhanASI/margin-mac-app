import Combine
import MarginCore
import SwiftUI

extension Notification.Name {
    /// Development aid (`--open-panel --settings`): flips the menu to its Settings page.
    static let marginShowSettings = Notification.Name("MarginShowSettings")
    /// Posted when the menu bar panel closes, so it reopens on the home page.
    static let marginPanelClosed = Notification.Name("MarginPanelClosed")
}

/// The menu's pages. Settings and the zone editor drill in from the main page, and a profile
/// from Settings, so there are no popovers inside the panel.
enum MenuPage: Equatable {
    case main
    case settings
    case profile(String)                    // by bundle ID
    case zone(Zone, profile: String? = nil) // nil edits the global layout
}

struct MenuView: View {
    @Bindable private var prefs = Preferences.shared
    private let state = AppState.shared
    private let timer = TimerService.shared
    @State private var page: MenuPage

    init(page: MenuPage = .main) {
        _page = State(initialValue: page)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            switch page {
            case .main: mainPage
            case .settings:
                SettingsPage(prefs: prefs, state: state, openProfile: { page = .profile($0) }) { page = .main }
            case .profile(let bundleID):
                ProfilePage(prefs: prefs, bundleID: bundleID, levels: LiveLevels(state),
                            editZone: { page = .zone($0, profile: bundleID) }) { page = .settings }
            case .zone(let zone, let profile):
                ZoneEditorPage(prefs: prefs, zone: zone, profileID: profile) {
                    page = profile.map { .profile($0) } ?? .main
                }
            }
        }
        .padding(14)
        .frame(width: 300)
        .preferredColorScheme(prefs.appearance.colorScheme)
        .onAppear { state.refreshLevels() }
        .onReceive(NotificationCenter.default.publisher(for: .marginShowSettings)) { _ in page = .settings }
        .onReceive(NotificationCenter.default.publisher(for: .marginPanelClosed)) { _ in page = .main }
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
        // So a changed binding never comes as a surprise.
        if let profile = prefs.activeProfile {
            ProfileStatusLine(profile: profile) { page = .profile(profile.bundleID) }
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

        TrackpadDiagram(layout: prefs.config.layout, levels: LiveLevels(state)) { page = .zone($0) }
            .opacity(prefs.config.enabled ? 1 : 0.45)

        if timer.state != .idle { TimerRow(timer: timer) }

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
                page = .settings
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
    let openProfile: (String) -> Void
    let back: () -> Void

    var body: some View {
        PageHeader(title: "Settings", back: back)

        PanelSection("Edges") {
            SwitchRow("Bottom Quarter Only", detail: "Ignore touches above the lower 25%",
                      isOn: $prefs.config.bottomQuarterOnly)
            SwitchRow("Require fn or ⌥", detail: "Only slide while holding a modifier",
                      isOn: $prefs.config.requireModifier)
            ResetLayoutRow(layout: $prefs.config.layout)
        }

        AppProfilesSection(prefs: prefs, open: openProfile)

        TimerSettingsSection(prefs: prefs, timer: TimerService.shared)

        PanelSection("While Sliding") {
            SwitchRow("Freeze Cursor", detail: "The pointer stays hidden and still", isOn: $prefs.config.freezeCursor)
            SwitchRow("Fine Control", detail: "Hold ⇧⌥ for slower, finer changes", isOn: $prefs.config.fineControl)
            SwitchRow("Precise Sliding", detail: "Always slow and fine, no keys needed",
                      isOn: $prefs.config.preciseSliding)
        }

        PanelSection("Devices") {
            SwitchRow("External Magic Trackpad", isOn: $prefs.config.includeExternal)
            SwitchRow("Magic Mouse", detail: "Slide on the mouse's top edges", isOn: $prefs.config.magicMouse)
        }

        PanelSection("General") {
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

// MARK: - Building blocks

/// A drilled-in page's title, with a way back to the main page.
struct PageHeader: View {
    let title: String
    let back: () -> Void

    var body: some View {
        HStack {
            Button(action: back) {
                Label("Back", systemImage: "chevron.left")
            }
            .buttonStyle(.borderless)
            Spacer()
            Text(title).font(.headline).lineLimit(1)
            Spacer()
            // Balances the back button so the title stays centred.
            Label("Back", systemImage: "chevron.left").hidden()
        }
    }
}

/// Puts every zone back as v1.2 had it. It asks first, inline, because a menu panel can't show
/// an alert above itself and a custom layout can't be got back.
private struct ResetLayoutRow: View {
    @Binding var layout: MarginCore.Layout
    @State private var confirming = false

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 1) {
                Text("Reset Layout")
                Text(confirming ? "Every zone goes back to its default." : "Volume, brightness, media and mute")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Group {
                if confirming {
                    Button("Cancel") { confirming = false }
                    Button("Reset") {
                        layout = .default
                        confirming = false
                    }
                    .keyboardShortcut(.defaultAction)
                } else {
                    Button("Reset…") { confirming = true }
                        .disabled(layout == .default)
                }
            }
            .controlSize(.small)
        }
        .onDisappear { confirming = false }
    }
}

struct SwitchRow: View {
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

struct PanelSection<Content: View>: View {
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
