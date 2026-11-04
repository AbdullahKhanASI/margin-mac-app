import MarginCore
import SwiftUI

/// The third page of the menu: what one zone does when slid along and double-tapped.
struct ZoneEditorPage: View {
    @Bindable var prefs: Preferences
    let zone: Zone
    let back: () -> Void
    /// Read when the page opens, so a change in System Settings shows the next time.
    @State private var rightClickCorners: Set<Zone> = []

    var body: some View {
        PageHeader(title: zone.title, back: back)

        if zone.isEdge {
            PanelSection("Slide") {
                slidePicker
                if case .flick = slide.wrappedValue { flickCommands }
                if slide.wrappedValue == .level(.inputVolume), !SystemControls.inputVolumeAvailable {
                    Caption("This microphone's volume can't be set, so sliding does nothing.")
                }
                if zone.slidesVertically, prefs.config.magicMouse, slide.wrappedValue != .none {
                    Caption("Magic Mouse is on, so this slide also works along the mouse's "
                            + (zone == .leftEdge ? "left" : "right") + " side.")
                }
            }
        }

        PanelSection("Double-tap") {
            CommandPicker(title: "Action", groups: ActionCatalog.tapGroups(for: zone, canRun: Actions.canRun),
                          command: tap)
            if zone.slidesVertically, tap.wrappedValue != .none {
                Caption("May interfere with clicking near the sides.")
            }
            if rightClickCorners.contains(zone) {
                Caption("This corner is your right-click corner. Taps and clicks are told apart, "
                        + "so a double-tap here still works.")
            }
        }
        .onAppear { rightClickCorners = TrackpadSettings.rightClickCorners() }
    }

    // MARK: Slide

    private var slide: Binding<SlideAction> {
        Binding(get: { prefs.config.layout.edge(zone).slide },
                set: { prefs.config.layout.setSlide($0, for: zone) })
    }

    private var slidePicker: some View {
        let choice = Binding<SlideChoice>(
            get: { SlideChoice(slide.wrappedValue) },
            // Re-choosing the current kind keeps its settings, such as a flick's commands.
            set: { if $0 != SlideChoice(slide.wrappedValue) { slide.wrappedValue = $0.action } }
        )
        return PickerRow(title: "Action") {
            Picker("Slide", selection: choice) {
                OptionLabel(ActionCatalog.slideOption(.none)).tag(SlideChoice.none)
                ForEach(ActionCatalog.slideGroups(for: zone, canRun: Actions.canRun)) { group in
                    SwiftUI.Section(group.title) {
                        ForEach(group.options) { OptionLabel($0).tag($0.choice) }
                    }
                }
            }
        }
    }

    /// A flick's two commands, and a swap that does what Reverse Swipe did.
    @ViewBuilder private var flickCommands: some View {
        let groups = ActionCatalog.flickGroups(canRun: Actions.canRun)
        let (forward, back) = zone.slidesVertically ? ("↑", "↓") : ("→", "←")
        CommandPicker(title: "Forward \(forward)", groups: groups, command: flick(forward: true))
        CommandPicker(title: "Back \(back)", groups: groups, command: flick(forward: false))
        HStack {
            Spacer()
            Button {
                if case .flick(let f, let b) = slide.wrappedValue { slide.wrappedValue = .flick(forward: b, back: f) }
            } label: {
                Label("Swap Directions", systemImage: "arrow.left.arrow.right")
            }
            .controlSize(.small)
        }
    }

    private func flick(forward isForward: Bool) -> Binding<Command> {
        Binding(
            get: {
                guard case .flick(let f, let b) = slide.wrappedValue else { return .none }
                return isForward ? f : b
            },
            set: { new in
                guard case .flick(let f, let b) = slide.wrappedValue else { return }
                slide.wrappedValue = isForward ? .flick(forward: new, back: b) : .flick(forward: f, back: new)
            }
        )
    }

    // MARK: Tap

    private var tap: Binding<Command> {
        Binding(get: { prefs.config.layout.tap(zone) },
                set: { prefs.config.layout.setTap($0, for: zone) })
    }
}

/// Chooses a command, and asks for the rest when it needs more: an app for Launch App, a shortcut
/// for Keystroke. Until that's given, the binding keeps its old command, so nothing half-set is
/// ever saved.
struct CommandPicker: View {
    let title: String
    let groups: [CatalogGroup<CommandChoice>]
    @Binding var command: Command
    /// Keystroke… was chosen and the recorder is waiting for the first shortcut.
    @State private var recordingNew = false

    var body: some View {
        PickerRow(title: title) {
            Picker(title, selection: selection) {
                OptionLabel(ActionCatalog.commandOption(.command(.none))).tag(CommandChoice.command(.none))
                ForEach(groups) { group in
                    SwiftUI.Section(group.title) {
                        ForEach(group.options) { OptionLabel($0).tag($0.choice) }
                    }
                }
            }
        }
        if case .launchApp(let bundleID) = command, !recordingNew {
            AppRow(bundleID: bundleID) { chooseApp() }
        }
        if recordingNew || CommandChoice(command) == .keystroke {
            ShortcutRecorderRow(
                combo: recordingNew ? nil : command.shortcut,
                recordOnAppear: recordingNew,
                record: { combo in
                    recordingNew = false
                    command = .keystroke(combo)
                },
                cancel: { recordingNew = false }
            )
            // A new recorder for a new keystroke, so it starts listening on appear.
            .id(recordingNew)
        }
    }

    private var selection: Binding<CommandChoice> {
        Binding(get: { recordingNew ? .keystroke : CommandChoice(command) },
                set: choose)
    }

    private func choose(_ choice: CommandChoice) {
        guard choice != selection.wrappedValue else { return }
        recordingNew = false
        switch choice {
        case .command(let new): command = new
        case .launchApp: chooseApp()
        case .keystroke: recordingNew = true
        // Phase 5 adds the minutes stepper; until then canRun keeps this out of the list.
        case .timerStart: command = .timerStart(minutes: 25)
        }
    }

    private func chooseApp() {
        AppChooser.choose { bundleID in
            if let bundleID { command = .launchApp(bundleID: bundleID) }
        }
    }
}

/// The app a Launch App binding opens, with a button to pick another.
private struct AppRow: View {
    let bundleID: String
    let change: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if let app = InstalledApp(bundleID: bundleID) {
                Image(nsImage: app.icon).resizable().frame(width: 18, height: 18)
                Text(app.name)
            } else {
                Image(systemName: "questionmark.app")
                Text("App not found").foregroundStyle(.secondary)
            }
            Spacer()
            Button("Change…", action: change).controlSize(.small)
        }
    }
}

private struct OptionLabel<Choice: Hashable & Sendable>: View {
    let option: CatalogOption<Choice>
    init(_ option: CatalogOption<Choice>) { self.option = option }

    var body: some View {
        Label(option.label, systemImage: option.symbol)
    }
}

/// A title on the left and a pop-up menu on the right.
private struct PickerRow<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            content
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
                .controlSize(.small)
        }
    }
}

private struct Caption: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}
