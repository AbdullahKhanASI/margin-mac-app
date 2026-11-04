import AppKit
import MarginCore
import SwiftUI

/// Settings → App Profiles: one row per profile, and a way to add one for a running app.
struct AppProfilesSection: View {
    @Bindable var prefs: Preferences
    let open: (String) -> Void

    var body: some View {
        PanelSection("App Profiles") {
            if prefs.config.profiles.isEmpty {
                Caption("Give the trackpad different actions while a particular app is in front.")
            }
            ForEach(prefs.config.profiles) { profile in
                ProfileRow(profile: profile, isOn: enabled(profile.bundleID)) { open(profile.bundleID) }
            }
            AddProfileMenu(existing: Set(prefs.config.profiles.map(\.bundleID)),
                           add: { app in
                               prefs.addProfile(for: app)
                               if let bundleID = app.bundleIdentifier { open(bundleID) }
                           },
                           chooseOther: chooseOther)
        }
    }

    private func enabled(_ bundleID: String) -> Binding<Bool> {
        Binding(get: { prefs.profile(bundleID)?.enabled ?? false },
                set: { on in prefs.editProfile(bundleID) { $0.enabled = on } })
    }

    /// An app that isn't running, picked from /Applications with the same chooser as Launch App.
    /// Choosing one that already has a profile just opens it.
    private func chooseOther() {
        AppChooser.choose { bundleID in
            guard let bundleID, bundleID != Bundle.main.bundleIdentifier else { return }
            prefs.addProfile(bundleID: bundleID, name: InstalledApp(bundleID: bundleID)?.name ?? bundleID)
            open(bundleID)
        }
    }
}

/// A profile in the list: its app, a switch, and a way in.
private struct ProfileRow: View {
    let profile: AppProfile
    @Binding var isOn: Bool
    let open: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Button(action: open) {
                HStack(spacing: 8) {
                    AppIcon(bundleID: profile.bundleID, size: 18)
                    Text(profile.name).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            Toggle("Enabled", isOn: $isOn)
                .toggleStyle(.switch)
                .controlSize(.mini)
                .labelsHidden()
        }
    }
}

/// The + button: running apps with a normal activation policy, which are the apps a person
/// switches between (background agents and menu bar apps never become frontmost), then
/// Other App… for one that isn't open.
private struct AddProfileMenu: View {
    let existing: Set<String>
    let add: (NSRunningApplication) -> Void
    let chooseOther: () -> Void

    var body: some View {
        Menu {
            let apps = candidates
            if apps.isEmpty {
                Text("Every running app has a profile")
            }
            ForEach(apps, id: \.processIdentifier) { app in
                Button {
                    add(app)
                } label: {
                    Label {
                        Text(app.localizedName ?? app.bundleIdentifier ?? "")
                    } icon: {
                        if let icon = app.icon { Image(nsImage: Self.menuIcon(icon)) }
                    }
                }
            }
            Divider()
            Button("Other App…", action: chooseOther)
        } label: {
            Label("Add App", systemImage: "plus")
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
        .controlSize(.small)
    }

    /// Read each time the list is drawn, so it reflects what's running when Settings opens.
    private var candidates: [NSRunningApplication] {
        var seen = existing
        if let own = Bundle.main.bundleIdentifier { seen.insert(own) }
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .filter { app in
                // One entry per bundle ID, even with several copies running.
                guard let id = app.bundleIdentifier, !seen.contains(id) else { return false }
                seen.insert(id)
                return true
            }
            .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
    }

    /// Menus draw images at their own size, and app icons are large.
    private static func menuIcon(_ icon: NSImage) -> NSImage {
        let small = icon.copy() as? NSImage ?? icon
        small.size = NSSize(width: 16, height: 16)
        return small
    }
}

/// One profile: its switch, the diagram in profile mode, and removing it.
struct ProfilePage: View {
    @Bindable var prefs: Preferences
    let bundleID: String
    let levels: LiveLevels
    let editZone: (Zone) -> Void
    let back: () -> Void
    @State private var confirmingRemove = false

    var body: some View {
        if let profile = prefs.profile(bundleID) {
            PageHeader(title: profile.name, back: back)
            HStack(spacing: 8) {
                AppIcon(bundleID: bundleID, size: 32)
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.enabled ? "While \(profile.name) is in front" : "Off")
                        .lineLimit(2)
                    Text("Trackpads only. Magic Mouse keeps the main layout.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
                Spacer()
                Toggle("Enabled", isOn: enabled)
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .labelsHidden()
            }

            TrackpadDiagram(layout: prefs.config.layout.applying(profile.overrides), levels: levels,
                            profileOverrides: profile.overrides, select: editZone)
                .opacity(profile.enabled ? 1 : 0.45)
            Caption("Tinted zones differ from your main layout. Click a zone to change it for \(profile.name).")

            Divider()
            removeRow
        } else {
            // Removed while this page was open.
            PageHeader(title: "Profile", back: back)
            Caption("This profile no longer exists.")
        }
    }

    private var enabled: Binding<Bool> {
        Binding(get: { prefs.profile(bundleID)?.enabled ?? false },
                set: { on in prefs.editProfile(bundleID) { $0.enabled = on } })
    }

    /// Asks inline first, as Reset Layout does: the panel can't show an alert above itself.
    private var removeRow: some View {
        HStack {
            if confirmingRemove {
                Text("Remove this profile?").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { confirmingRemove = false }
                Button("Remove", role: .destructive) {
                    confirmingRemove = false
                    prefs.removeProfile(bundleID)
                    back()
                }
            } else {
                Spacer()
                Button("Remove Profile…", role: .destructive) { confirmingRemove = true }
            }
        }
        .controlSize(.small)
    }
}

/// "Using Chrome profile" under the main page's header. Clicking it opens the profile.
struct ProfileStatusLine: View {
    let profile: AppProfile
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(spacing: 6) {
                AppIcon(bundleID: profile.bundleID, size: 14)
                Text("Using \(profile.name) profile")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Open the \(profile.name) profile")
    }
}

/// An app's icon by bundle ID, or a generic one if the app can't be found.
struct AppIcon: View {
    let bundleID: String
    let size: CGFloat

    var body: some View {
        Group {
            if let app = InstalledApp(bundleID: bundleID) {
                Image(nsImage: app.icon).resizable()
            } else {
                Image(systemName: "questionmark.app").resizable().foregroundStyle(.secondary)
            }
        }
        .frame(width: size, height: size)
    }
}
