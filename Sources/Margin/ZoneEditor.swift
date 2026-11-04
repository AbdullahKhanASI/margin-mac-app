import MarginCore
import SwiftUI

/// The third page of the menu: what one zone does when slid along and double-tapped.
///
/// Opened from a profile, it edits that profile's overrides instead of the global layout. Each
/// picker then shows what the zone does in that app, and gains a "Use Global" entry that drops
/// the override.
struct ZoneEditorPage: View {
    @Bindable var prefs: Preferences
    let zone: Zone
    /// The profile being edited, or nil for the global layout.
    let profileID: String?
    let back: () -> Void
    /// Read when the page opens, so a change in System Settings shows the next time.
    @State private var rightClickCorners: Set<Zone> = []

    private var profile: AppProfile? { profileID.flatMap(prefs.profile) }

    /// What the zone does where this page is editing: globally, or in the profile's app.
    private var layout: MarginCore.Layout {
        guard let profile else { return prefs.config.layout }
        return prefs.config.layout.applying(profile.overrides)
    }

    var body: some View {
        PageHeader(title: zone.title, back: back)
        if let profile {
            Caption("In the \(profile.name) profile. Anything set to Use Global follows your main layout.")
        }

        if zone.isEdge {
            PanelSection("Slide") {
                slidePicker
                if case .flick = slide.wrappedValue { flickCommands }
                if slide.wrappedValue == .level(.inputVolume), !SystemControls.inputVolumeAvailable {
                    Caption("This microphone's volume can't be set, so sliding does nothing.")
                }
                if zone.slidesVertically, prefs.config.magicMouse {
                    if profileID != nil {
                        // Decision 3: the mouse always keeps the global layout.
                        Caption("Profiles don't change Magic Mouse; it keeps the main layout's slide.")
                    } else if slide.wrappedValue != .none {
                        Caption("Magic Mouse is on, so this slide also works along the mouse's "
                                + (zone == .leftEdge ? "left" : "right") + " side.")
                    }
                }
            }
        }

        PanelSection("Double-tap") {
            CommandPicker(title: "Action", groups: ActionCatalog.tapGroups(for: zone, canRun: Actions.canRun),
                          command: tap, inherit: tapInherit)
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
        Binding(get: { layout.edge(zone).slide },
                set: { new in
                    if let profileID {
                        prefs.editProfile(profileID) { $0.overrides.setSlide(new, for: zone) }
                    } else {
                        prefs.config.layout.setSlide(new, for: zone)
                    }
                })
    }

    private var slideInherited: Bool { profile.map { $0.overrides.slide(zone) == nil } ?? false }

    private var slidePicker: some View {
        let choice = Binding<Inheritable<SlideChoice>>(
            get: { slideInherited ? .useGlobal : .choice(SlideChoice(slide.wrappedValue)) },
            set: { new in
                switch new {
                case .useGlobal:
                    if let profileID { prefs.editProfile(profileID) { $0.overrides.setSlide(nil, for: zone) } }
                case .choice(let picked):
                    // Re-choosing the current kind keeps its settings, such as a flick's commands;
                    // in a profile it pins the global one as the profile's own.
                    let current = slide.wrappedValue
                    if picked == SlideChoice(current) {
                        if slideInherited { slide.wrappedValue = current }
                    } else {
                        slide.wrappedValue = picked.action
                    }
                }
            }
        )
        return PickerRow(title: "Action") {
            Picker("Slide", selection: choice) {
                if profileID != nil {
                    UseGlobalLabel(label: prefs.config.layout.edge(zone).slide.label)
                        .tag(Inheritable<SlideChoice>.useGlobal)
                }
                OptionLabel(ActionCatalog.slideOption(.none)).tag(Inheritable.choice(SlideChoice.none))
                ForEach(ActionCatalog.slideGroups(for: zone, canRun: Actions.canRun)) { group in
                    SwiftUI.Section(group.title) {
                        ForEach(group.options) { OptionLabel($0).tag(Inheritable.choice($0.choice)) }
                    }
                }
            }
        }
    }

    /// A flick's two commands, and a swap that does what Reverse Swipe did. In a profile, changing
    /// either one makes the whole flick the profile's own.
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
        Binding(get: { layout.tap(zone) },
                set: { new in
                    if let profileID {
                        prefs.editProfile(profileID) { $0.overrides.setTap(new, for: zone) }
                    } else {
                        prefs.config.layout.setTap(new, for: zone)
                    }
                })
    }

    private var tapInherit: CommandPicker.Inherit? {
        guard let profileID, let profile else { return nil }
        return CommandPicker.Inherit(
            global: prefs.config.layout.tap(zone),
            isInherited: profile.overrides.tap(zone) == nil,
            useGlobal: { prefs.editProfile(profileID) { $0.overrides.setTap(nil, for: zone) } }
        )
    }
}

/// A picker's selection when it can also follow the global layout.
enum Inheritable<Choice: Hashable>: Hashable {
    case useGlobal
    case choice(Choice)
}

/// "Use Global", with what that currently is, so the choice says what it will do.
private struct UseGlobalLabel: View {
    let label: String

    var body: some View {
        Label("Use Global (\(label))", systemImage: "arrow.uturn.backward")
    }
}

/// Chooses a command, and asks for the rest when it needs more: an app for Launch App, a shortcut
/// for Keystroke. Until that's given, the binding keeps its old command, so nothing half-set is
/// ever saved.
struct CommandPicker: View {
    /// Given when editing a profile: the picker offers "Use Global", and shows it while the
    /// profile doesn't override this command.
    struct Inherit {
        let global: Command
        let isInherited: Bool
        let useGlobal: () -> Void
    }

    let title: String
    let groups: [CatalogGroup<CommandChoice>]
    @Binding var command: Command
    var inherit: Inherit?
    /// Keystroke… was chosen and the recorder is waiting for the first shortcut.
    @State private var recordingNew = false

    var body: some View {
        PickerRow(title: title) {
            Picker(title, selection: selection) {
                if let inherit {
                    UseGlobalLabel(label: inherit.global.label).tag(Inheritable<CommandChoice>.useGlobal)
                }
                OptionLabel(ActionCatalog.commandOption(.command(.none)))
                    .tag(Inheritable.choice(CommandChoice.command(.none)))
                ForEach(groups) { group in
                    SwiftUI.Section(group.title) {
                        ForEach(group.options) { OptionLabel($0).tag(Inheritable.choice($0.choice)) }
                    }
                }
            }
        }
        if case .launchApp(let bundleID) = command, !recordingNew, !isInherited {
            AppRow(bundleID: bundleID) { chooseApp() }
        }
        if recordingNew || (CommandChoice(command) == .keystroke && !isInherited) {
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

    private var isInherited: Bool { inherit?.isInherited ?? false }

    private var selection: Binding<Inheritable<CommandChoice>> {
        Binding(get: {
                    if recordingNew { return .choice(.keystroke) }
                    return isInherited ? .useGlobal : .choice(CommandChoice(command))
                },
                set: choose)
    }

    private func choose(_ entry: Inheritable<CommandChoice>) {
        guard entry != selection.wrappedValue else { return }
        recordingNew = false
        guard case .choice(let choice) = entry else {
            inherit?.useGlobal()
            return
        }
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

struct Caption: View {
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
