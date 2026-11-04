import AppKit
import CMultitouch
import MarginCore
import Observation
import UserNotifications

extension Notification.Name {
    /// Posted by the engine on the main thread when a finger lifts off the timer dial;
    /// `userInfo` has "minutes" (Int, 0 cancels) and "device" (UInt64).
    static let marginTimerSet = Notification.Name("MarginTimerSet")
    /// Posted by the engine on the main thread when a tap dismisses the alarm.
    static let marginAlarmDismissed = Notification.Name("MarginAlarmDismissed")
}

/// The one timer: owns the `TimerMachine`, saves it, drives the menu bar countdown and the
/// alarm. Main thread only. The engine gets copies through `TouchEngine.updateTimer` and
/// `setAlarm`, so it never reads this from its own queue.
@Observable
final class TimerService {
    static let shared = TimerService()

    private(set) var machine: TimerMachine
    /// True from the end of the timer until it's dismissed or the pattern's time limit runs out.
    private(set) var alarmSounding = false
    /// Settings → Timer's Try is playing the pattern.
    private(set) var isTrying = false

    private static let defaultsKey = "timer"
    /// Injected so a preview or a test harness could run it on another clock.
    @ObservationIgnored var clock: () -> Date = Date.init
    /// The trackpad the timer was last set from; its motor plays the alarm. Not saved: device
    /// IDs needn't survive a restart, and the built-in trackpad is the fallback.
    @ObservationIgnored private var device: UInt64?
    @ObservationIgnored private var ticker: Timer?
    @ObservationIgnored private var autoStop: Timer?
    @ObservationIgnored private var tryEnd: DispatchWorkItem?

    var state: TimerState { machine.state }
    private var settings: TimerSettings { Preferences.shared.config.timer }

    private init() {
        machine = UserDefaults.standard.data(forKey: Self.defaultsKey)
            .flatMap { try? JSONDecoder().decode(TimerMachine.self, from: $0) } ?? TimerMachine()
    }

    /// Called once at launch: picks up a timer saved by the last run, and the notifications
    /// the engine and the system send.
    func start() {
        let center = NotificationCenter.default
        center.addObserver(forName: .marginTimerSet, object: nil, queue: .main) { [weak self] note in
            guard let minutes = note.userInfo?["minutes"] as? Int else { return }
            self?.setFromDial(minutes: minutes, device: note.userInfo?["device"] as? UInt64)
        }
        center.addObserver(forName: .marginAlarmDismissed, object: nil, queue: .main) { [weak self] _ in
            self?.dismiss()
        }
        // Timers don't fire during sleep; look again on wake, so a timer that ended then rings now.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil,
                                                          queue: .main) { [weak self] _ in
            self?.refresh()
        }

        let now = clock()
        if machine.refresh(now: now) {
            // Ended while Margin wasn't running.
            changed(from: .running(endsAt: now))
        } else {
            if machine.isAlarmSounding(now: now, limit: pattern.stopsAfter) {
                // Relaunched mid-alarm: carry on ringing, without a second chime or Shortcut.
                startAlarm(announce: false)
            }
            pushToEngine()
            scheduleTick()
            updateStatusItem()
        }
    }

    // MARK: Commands

    func start(minutes: Int, device: UInt64? = nil) {
        apply(device: device) { $0.start(minutes: minutes, now: $1) }
    }

    /// What lifting the dial does: start, change or (at zero) cancel.
    func setFromDial(minutes: Int, device: UInt64?) {
        apply(device: device) { $0.setFromDial(minutes: minutes, now: $1) }
    }

    func pauseResume() {
        apply { $0.pauseResume(now: $1) }
    }

    func cancel() {
        apply { m, _ in m.cancel() }
    }

    /// Stops the alarm, or a Try, from a tap, the overlay or the timer row.
    func dismiss() {
        if tryEnd != nil { return endTry() }
        apply { m, _ in m.dismiss() }
    }

    /// `--preview-timer`: a 10-second timer, to try the alarm.
    func startPreview() {
        apply { $0.start(duration: 10, now: $1) }
    }

    /// Plays the chosen pattern for 6 seconds, so there's time to rest a finger on the trackpad.
    func tryAlarm() {
        guard !alarmSounding else { return }
        tryEnd?.cancel()
        TouchEngine.shared.setAlarm(active: true, pattern: pattern, device: mr_builtin_device_id())
        let work = DispatchWorkItem { [weak self] in self?.endTry() }
        tryEnd = work
        isTrying = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 6, execute: work)
    }

    private func endTry() {
        tryEnd?.cancel()
        tryEnd = nil
        isTrying = false
        if !alarmSounding { TouchEngine.shared.setAlarm(active: false, pattern: pattern, device: 0) }
    }

    private func apply(device: UInt64? = nil, _ change: (inout TimerMachine, Date) -> Void) {
        let old = machine.state
        let now = clock()
        machine.refresh(now: now)
        change(&machine, now)
        if let device { self.device = device }
        changed(from: old)
    }

    // MARK: Ticking

    /// The clock moved on: notices a timer that has ended and redraws the countdown.
    func refresh() {
        let old = machine.state
        if machine.refresh(now: clock()) {
            changed(from: old)
        } else {
            scheduleTick()
            updateStatusItem()
        }
    }

    /// One shot, for when the countdown text can next change or the timer ends, whichever is
    /// sooner. That's every second, or every minute while more than an hour is left.
    private func scheduleTick() {
        ticker?.invalidate()
        ticker = nil
        guard let remaining = machine.remaining(now: clock()), case .running = machine.state else { return }
        let delay = max(min(TimerDisplay.refreshInterval(remaining), remaining), 0.05)
        ticker = Timer.scheduledTimer(withTimeInterval: delay, repeats: false) { [weak self] _ in self?.refresh() }
        ticker?.tolerance = 0.05
    }

    // MARK: State changes

    private func changed(from old: TimerState) {
        let new = machine.state
        save()
        pushToEngine()
        scheduleTick()

        let wasActive = old.isCounting
        switch new {
        case .running where !wasActive:
            runShortcut(settings.startShortcut)
        case .idle where wasActive:
            // Cancelled before it rang: the end Shortcut still runs, so a Focus turned on at
            // the start is turned off again.
            runShortcut(settings.endShortcut)
        case .ringing where !old.isRinging:
            startAlarm(announce: true)
        default:
            break
        }
        if !new.isRinging, alarmSounding { stopAlarm() }
        updateStatusItem()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(machine) {
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        }
    }

    private func pushToEngine() {
        TouchEngine.shared.updateTimer(machine)
    }

    // MARK: Alarm

    private var pattern: AlarmPattern { settings.alarm.pattern }

    private func startAlarm(announce: Bool) {
        guard case .ringing(let since) = machine.state else { return }
        tryEnd?.cancel()
        tryEnd = nil
        isTrying = false
        alarmSounding = true
        let pattern = self.pattern
        TouchEngine.shared.setAlarm(active: true, pattern: pattern, device: device ?? mr_builtin_device_id())
        LevelOverlay.shared.showAlarm()
        if announce {
            if settings.playSound { NSSound(named: "Glass")?.play() }
            if settings.showNotification { TimerNotifications.post() }
            runShortcut(settings.endShortcut)
        }
        autoStop?.invalidate()
        let left = since.addingTimeInterval(pattern.stopsAfter).timeIntervalSince(clock())
        autoStop = Timer.scheduledTimer(withTimeInterval: max(left, 0), repeats: false) { [weak self] _ in
            // Stays `ringing`, so the menu bar says "Timer done" until it's dismissed.
            self?.stopAlarm()
            self?.updateStatusItem()
        }
    }

    private func stopAlarm() {
        alarmSounding = false
        autoStop?.invalidate()
        autoStop = nil
        TouchEngine.shared.setAlarm(active: false, pattern: pattern, device: 0)
        LevelOverlay.shared.hideAlarm()
    }

    // MARK: Menu bar

    /// The text next to the icon, or nil for the icon alone.
    var statusText: String? {
        switch machine.state {
        case .idle: nil
        case .running: machine.remaining(now: clock()).map(TimerDisplay.countdown)
        case .paused(let remaining): "⏸ " + TimerDisplay.countdown(remaining)
        case .ringing: alarmSounding ? "Time's up" : "Timer done"
        }
    }

    private func updateStatusItem() {
        MenuPanel.shared.setTimer(text: statusText, pulsing: alarmSounding)
    }

    // MARK: Shortcuts

    private func runShortcut(_ name: String?) {
        guard let name, !name.isEmpty else { return }
        ShortcutsCLI.run(name)
    }
}

private extension TimerState {
    /// A timer exists that hasn't rung yet.
    var isCounting: Bool {
        switch self {
        case .running, .paused: true
        case .idle, .ringing: false
        }
    }

    var isRinging: Bool {
        if case .ringing = self { return true }
        return false
    }
}

/// The optional "Time's up" notification.
enum TimerNotifications {
    /// UNUserNotificationCenter throws an exception in a process with no bundle, such as
    /// `swift run` from `.build`, so it's only touched from the app bundle.
    private static var available: Bool { Bundle.main.bundleIdentifier != nil }

    /// Asks the first time the setting is turned on; `done` says whether Margin may notify.
    static func requestPermission(_ done: @escaping (Bool) -> Void) {
        guard available else { return done(false) }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, _ in
            DispatchQueue.main.async { done(granted) }
        }
    }

    static func post() {
        guard available else { return }
        let content = UNMutableNotificationContent()
        content.title = "Time's up"
        content.body = "Your Margin timer has ended."
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "margin.timer", content: content,
                                                                     trigger: nil))
    }
}

/// `/usr/bin/shortcuts`, which needs no permission to list or run Shortcuts.
enum ShortcutsCLI {
    private static let path = "/usr/bin/shortcuts"

    /// The user's Shortcuts by name, read off the main thread.
    static func list(_ done: @escaping ([String]) -> Void) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let pipe = Pipe()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = ["list"]
            process.standardOutput = pipe
            process.standardError = FileHandle.nullDevice
            var names: [String] = []
            if (try? process.run()) != nil {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                names = String(decoding: data, as: UTF8.self)
                    .split(separator: "\n").map(String.init).filter { !$0.isEmpty }
            }
            DispatchQueue.main.async { done(names) }
        }
    }

    /// Runs it in the background; Margin doesn't wait for it or report failures.
    static func run(_ name: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = ["run", name]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
    }
}
