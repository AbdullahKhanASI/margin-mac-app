import MarginCore
import SwiftUI

/// The main page's timer row, shown while a timer exists: the time left, pause or resume, and
/// cancel. While ringing, clicking anywhere on it dismisses the alarm.
struct TimerRow: View {
    let timer: TimerService

    var body: some View {
        // Redrawn each second for the countdown; nothing else here changes on its own.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            HStack(spacing: 8) {
                Image(systemName: symbol)
                    .foregroundStyle(timer.alarmSounding ? .orange : .secondary)
                    .frame(width: 18)
                Text(text(now: context.date))
                    .monospacedDigit()
                Spacer()
                buttons
            }
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 10)
        .background(.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .contentShape(Rectangle())
        .onTapGesture {
            if case .ringing = timer.state { timer.dismiss() }
        }
    }

    private var symbol: String {
        switch timer.state {
        case .ringing: timer.alarmSounding ? "alarm.fill" : "checkmark.circle"
        case .paused: "pause.circle"
        case .running, .idle: "timer"
        }
    }

    private func text(now: Date) -> String {
        switch timer.state {
        case .idle: ""
        case .running(let endsAt): TimerDisplay.countdown(max(endsAt.timeIntervalSince(now), 0)) + " left"
        case .paused(let remaining): TimerDisplay.countdown(remaining) + " left, paused"
        case .ringing: timer.alarmSounding ? "Time's up" : "Timer done"
        }
    }

    @ViewBuilder private var buttons: some View {
        Group {
            switch timer.state {
            case .running, .paused:
                let paused = if case .paused = timer.state { true } else { false }
                Button { timer.pauseResume() } label: {
                    Image(systemName: paused ? "play.fill" : "pause.fill")
                }
                .help(paused ? "Resume" : "Pause")
                Button { timer.cancel() } label: { Image(systemName: "xmark") }
                    .help("Cancel")
            case .ringing:
                Button("Dismiss") { timer.dismiss() }
            case .idle:
                EmptyView()
            }
        }
        .buttonStyle(.borderless)
        .controlSize(.small)
    }
}

/// Settings → Timer: the alarm's intensity with a Try button, the chime, the notification and
/// the Shortcuts to run.
struct TimerSettingsSection: View {
    @Bindable var prefs: Preferences
    let timer: TimerService
    /// Nil until `shortcuts list` has answered.
    @State private var shortcuts: [String]?
    @State private var notificationsRefused = false

    private var settings: Binding<TimerSettings> { $prefs.config.timer }

    var body: some View {
        PanelSection("Timer") {
            HStack(spacing: 8) {
                Text("Alarm").font(.caption).foregroundStyle(.secondary)
                Picker("Alarm", selection: settings.alarm) {
                    ForEach(AlarmIntensity.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Button(timer.isTrying ? "Stop" : "Try") {
                    timer.isTrying ? timer.dismiss() : timer.tryAlarm()
                }
                .disabled(timer.alarmSounding)
            }
            .controlSize(.small)
            Caption(timer.isTrying ? "Rest a finger on the trackpad to feel it."
                                   : "Felt while a finger rests on the trackpad. " + patternDescription)

            SwitchRow("Play a Sound", detail: "A chime when the timer ends", isOn: settings.playSound)
            SwitchRow("Show a Notification", isOn: notificationBinding)
            if notificationsRefused {
                Caption("Margin isn't allowed to notify. Turn it on in System Settings → Notifications.")
            }

            ShortcutRow(title: "On Start", selection: settings.startShortcut, shortcuts: shortcuts)
            ShortcutRow(title: "On End", selection: settings.endShortcut, shortcuts: shortcuts)
            Caption("Runs a Shortcut, for example to turn a Focus on and off.")
        }
        .onAppear {
            if shortcuts == nil { ShortcutsCLI.list { shortcuts = $0 } }
        }
    }

    private var patternDescription: String {
        let p = prefs.config.timer.alarm.pattern
        let pulses = p.pulses == 1 ? "One pulse" : "\(p.pulses) pulses"
        return "\(pulses) every \(Int(p.repeatEvery)) s, for \(Int(p.stopsAfter / 60)) min."
    }

    /// Asks for permission the first time it's turned on, and stays off if refused.
    private var notificationBinding: Binding<Bool> {
        Binding(get: { prefs.config.timer.showNotification },
                set: { on in
                    guard on else {
                        prefs.config.timer.showNotification = false
                        return
                    }
                    TimerNotifications.requestPermission { granted in
                        notificationsRefused = !granted
                        prefs.config.timer.showNotification = granted
                    }
                })
    }
}

/// Chooses a Shortcut by name from `shortcuts list`, or none.
private struct ShortcutRow: View {
    let title: String
    @Binding var selection: String?
    let shortcuts: [String]?

    var body: some View {
        HStack {
            Text("Run Shortcut \(title)")
            Spacer()
            Picker(title, selection: $selection) {
                Text("None").tag(String?.none)
                // A Shortcut that's since been renamed or deleted stays listed, so it can be seen.
                if let selection, !(shortcuts ?? []).contains(selection) {
                    Text(selection).tag(String?.some(selection))
                }
                ForEach(shortcuts ?? [], id: \.self) { Text($0).tag(String?.some($0)) }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .fixedSize()
            .controlSize(.small)
            .disabled(shortcuts == nil)
        }
    }
}

/// Start Timer's length, stepping along the dial's scale.
struct TimerMinutesRow: View {
    @Binding var minutes: Int

    var body: some View {
        HStack {
            Text("Length")
            Spacer()
            Text("\(minutes) min").monospacedDigit().foregroundStyle(.secondary)
            Stepper("Length", onIncrement: { minutes = TimerScale.step(minutes, up: true) },
                    onDecrement: { minutes = TimerScale.step(minutes, up: false) })
                .labelsHidden()
                .controlSize(.small)
        }
    }
}
