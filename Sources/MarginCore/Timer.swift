import Foundation

/// Where the timer is. Times are wall-clock `Date`s rather than uptime, so sleep doesn't lose
/// time: a timer whose end passes while the Mac sleeps is found expired on wake.
public enum TimerState: Codable, Equatable, Sendable {
    case idle
    case running(endsAt: Date)
    case paused(remaining: TimeInterval)
    /// Expired at `since`. It keeps ringing until dismissed; after the alarm pattern's time limit
    /// it falls quiet but stays here, so the menu bar can say "Timer done".
    case ringing(since: Date)
}

/// The timer's state machine, kept pure so it can be tested with any clock: every call that
/// depends on time takes `now`. `TimerService` owns one, feeds it `Date()` and saves it.
public struct TimerMachine: Codable, Equatable, Sendable {
    public private(set) var state: TimerState = .idle
    /// The dial starts here when no timer is running.
    public private(set) var lastMinutes = 25

    public init() {}

    /// Starts a timer of `minutes`, replacing any running one. This is the length the dial
    /// starts at next time.
    public mutating func start(minutes: Int, now: Date) {
        guard minutes > 0 else { return cancel() }
        lastMinutes = minutes
        start(duration: TimeInterval(minutes) * 60, now: now)
    }

    /// A timer of any length, which doesn't change `lastMinutes`. For `--preview-timer`'s 10 s.
    public mutating func start(duration: TimeInterval, now: Date) {
        state = .running(endsAt: now.addingTimeInterval(duration))
    }

    /// What lifting the dial at `minutes` does: zero cancels, anything else starts or changes
    /// the timer. A paused timer set from the dial runs again, since the user just chose a time.
    public mutating func setFromDial(minutes: Int, now: Date) {
        if minutes == 0 { cancel() } else { start(minutes: minutes, now: now) }
    }

    /// Pauses a running timer or resumes a paused one. While ringing it dismisses, so the same
    /// tap that pauses can also silence the alarm.
    public mutating func pauseResume(now: Date) {
        refresh(now: now)
        switch state {
        case .running(let endsAt): state = .paused(remaining: endsAt.timeIntervalSince(now))
        case .paused(let remaining): state = .running(endsAt: now.addingTimeInterval(remaining))
        case .ringing: dismiss()
        case .idle: break
        }
    }

    public mutating func cancel() {
        state = .idle
    }

    /// Stops the alarm. Does nothing unless ringing, so a stray dismiss can't cancel a timer.
    public mutating func dismiss() {
        if case .ringing = state { state = .idle }
    }

    /// Moves a running timer whose end has passed to `ringing`. `since` is when that was
    /// noticed, not the end time: a timer that ended during a long sleep rings on wake for the
    /// pattern's full time instead of having already timed out. Returns true if it started ringing.
    @discardableResult
    public mutating func refresh(now: Date) -> Bool {
        guard case .running(let endsAt) = state, endsAt <= now else { return false }
        state = .ringing(since: now)
        return true
    }

    /// Time left, or nil when no timer is counting down or paused.
    public func remaining(now: Date) -> TimeInterval? {
        switch state {
        case .running(let endsAt): max(endsAt.timeIntervalSince(now), 0)
        case .paused(let remaining): remaining
        case .idle, .ringing: nil
        }
    }

    /// Whether the alarm should still be going: ringing and within the pattern's time limit.
    public func isAlarmSounding(now: Date, limit: TimeInterval) -> Bool {
        guard case .ringing(let since) = state else { return false }
        return now.timeIntervalSince(since) < limit
    }

    /// The minutes the dial starts at: the time left, rounded up, or the last length used.
    public func dialStartMinutes(now: Date) -> Double {
        remaining(now: now).map { ($0 / 60).rounded(.up) } ?? Double(lastMinutes)
    }

    // Decoded field by field, like EngineConfig, so a saved timer survives new fields.
    private enum CodingKeys: String, CodingKey { case state, lastMinutes }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        state = (try? c.decodeIfPresent(TimerState.self, forKey: .state)) ?? .idle
        lastMinutes = (try? c.decodeIfPresent(Int.self, forKey: .lastMinutes)) ?? 25
    }
}

/// The dial's scale: 1-minute notches from 1 to 10, then 5-minute notches to 90. Notch 0 is
/// zero minutes, which cancels. That's 26 notches from 1 to 90, close to the Default feel's 25,
/// so a full sweep feels like the volume edge.
public enum TimerScale {
    public static let minutes: [Int] = [0] + Array(1...10) + Array(stride(from: 15, through: 90, by: 5))
    /// The highest notch, which is also the number of notches in a full sweep.
    public static var notches: Int { minutes.count - 1 }

    public static func minutes(atNotch notch: Int) -> Int {
        minutes[min(max(notch, 0), notches)]
    }

    /// The notch closest to `value` minutes; halfway rounds up, so 12.5 is 15.
    public static func notch(nearest value: Double) -> Int {
        var best = 0
        for (i, m) in minutes.enumerated() where abs(Double(m) - value) <= abs(Double(minutes[best]) - value) {
            best = i
        }
        return best
    }

    /// The next value up or down the scale from `minutes`, never below 1: the zone editor's
    /// minutes stepper for Start Timer, which has no use for zero.
    public static func step(_ minutes: Int, up: Bool) -> Int {
        let n = notch(nearest: Double(minutes))
        let next = up ? min(n + 1, notches) : max(n - 1, 1)
        return self.minutes[next]
    }
}

/// The dial while a finger is on it: notches counted from where the touch began, clamped to
/// the scale. Clamping moves the origin, so reversing at either end responds at once instead of
/// first unwinding travel past the end.
public struct TimerDial: Equatable, Sendable {
    public let startNotch: Int
    public private(set) var notch: Int
    private var counter: DetentCounter

    public init(startMinutes: Double, origin: Double, spacing: Double) {
        startNotch = TimerScale.notch(nearest: startMinutes)
        notch = startNotch
        counter = DetentCounter(origin: origin, spacing: spacing)
    }

    public var minutes: Int { TimerScale.minutes(atNotch: notch) }
    public var moved: Bool { notch != startNotch }

    /// Moves to `position`; returns true when the dial landed on a different notch.
    public mutating func move(to position: Double) -> Bool {
        _ = counter.move(to: position)
        let raw = startNotch + counter.notch
        let clamped = min(max(raw, 0), TimerScale.notches)
        if raw != clamped {
            counter.shift(by: Double(raw - clamped) * counter.spacing)
            _ = counter.move(to: position)
        }
        let changed = clamped != notch
        notch = clamped
        return changed
    }

    /// Keeps the value when a dropped finger is picked back up a little way off.
    public mutating func shift(by delta: Double) {
        counter.shift(by: delta)
    }

    /// The overlay text: "25 min".
    public static func label(minutes: Int) -> String { "\(minutes) min" }

    /// The overlay's hint while the finger is down.
    public static func hint(minutes: Int) -> String { minutes == 0 ? "Lift to cancel" : "Lift to start" }
}

/// How the menu bar shows time left: "24:12" up to an hour, then "1h 24m", which only needs
/// redrawing once a minute.
public enum TimerDisplay {
    public static func countdown(_ remaining: TimeInterval) -> String {
        let seconds = Int(remaining.rounded(.up))
        if seconds > 3600 {
            let minutes = (seconds + 59) / 60
            return "\(minutes / 60)h \(String(format: "%02d", minutes % 60))m"
        }
        return "\(seconds / 60):\(String(format: "%02d", seconds % 60))"
    }

    /// How long until the countdown text can next change.
    public static func refreshInterval(_ remaining: TimeInterval) -> TimeInterval {
        remaining > 3600 ? 60 : 1
    }
}
