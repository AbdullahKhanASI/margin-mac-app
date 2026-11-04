import AppKit
import CMultitouch
import MarginCore

struct Finger {
    let id: Int32
    let x: Double
    let y: Double
}

extension Notification.Name {
    static let marginLevelsChanged = Notification.Name("MarginLevelsChanged")
    /// Posted on the main thread after a gesture does something; `object` is a `(Zone, GestureKind)`.
    static let marginGestureCompleted = Notification.Name("MarginGestureCompleted")
}

/// Called by MultitouchSupport on its own thread, once per trackpad frame.
func multitouchFrame(_ touches: UnsafePointer<MRTouch>?, _ count: Int32, _ timestamp: Double, _ deviceID: UInt64,
                     _ isMouse: Int32) {
    var fingers: [Finger] = []
    if let touches {
        for i in 0..<Int(count) {
            let t = touches[i]
            // 3 = touch down, 4 = touching. Hovering and lift-off states are ignored.
            if t.state == 3 || t.state == 4 {
                fingers.append(Finger(id: t.identifier, x: Double(t.x), y: Double(t.y)))
            }
        }
    }
    // Fingers resting on a Magic Mouse say nothing about tap-to-click on the trackpad.
    if isMouse == 0 { InputGate.shared.fingerState(down: !fingers.isEmpty) }
    // `timestamp` is MultitouchSupport's own clock. InputGate times clicks with `systemUptime`,
    // which nothing guarantees is the same clock, so frames also carry `systemUptime` taken here,
    // as they arrive, for comparing against clicks.
    TouchEngine.shared.enqueue(fingers, timestamp: timestamp, uptime: ProcessInfo.processInfo.systemUptime,
                               device: deviceID, isMouse: isMouse != 0)
}

/// Turns raw finger positions into edge gestures. `ZoneGeometry` says which zone a touch starts in;
/// the layout says what that zone's slide and double-tap do: `trackpadLayout` on a trackpad, the
/// config's global `layout` on a Magic Mouse, which app profiles never change (decision 3).
final class TouchEngine {
    static let shared = TouchEngine()

    private enum Phase {
        case pending   // landed in a zone, waiting to see what the finger does
        case sliding   // following the finger with a `level`, `stepper` or `timer` slide
        case swiping   // a `flick`, which fires once
        case rejected  // ordinary pointer movement; leave it alone
    }

    private struct Gesture {
        var device: UInt64
        var fingerID: Int32
        var startTime: Double
        var startUptime: Double   // `startTime` on the `systemUptime` clock, for the click guard
        var start: CGPoint
        var last: CGPoint
        var anchor: CGPoint
        /// Bindings are resolved when the touch begins and kept until it lifts, so a layout
        /// change never cuts off a gesture in progress.
        var edge: Zone?           // where a slide goes
        var slide: SlideAction
        var tapZone: Zone?        // where a double-tap goes: the corner, or the edge under it
        var tap: Command
        var isMouse: Bool
        var phase = Phase.pending
        var stepOrigin = 0.0
        var level: Double?        // nil when the level can't be set directly; keys are used instead
        var muted = false
        var lastDetent = 0
        var detentsFine = false   // whether lastDetent was counted on the precise (denser) scale
        var stepper: DetentCounter?  // a stepper's notches; it stores no level
        var dial: TimerDial?         // the timer dial's notches and value
        var maxTravel = 0.0
        var swipeFired = false
        var lostAt: Double?

        var isEngaged: Bool { phase == .sliding || phase == .swiping }

        /// Position along the edge being slid: y on the side edges, x on the top and bottom.
        func along(_ p: CGPoint) -> Double { edge?.slidesVertically == false ? p.x : p.y }
    }

    // Tuning, in normalized trackpad units (0–1).
    private enum Tuning {
        static let slideStart = 0.02         // vertical travel before a slide engages
        static let swipeStart = 0.03         // horizontal travel before a strip swipe engages
        static let swipeFire = 0.12          // horizontal travel that skips a track
        static let rejectTravel = 0.05       // travel that turns a pending touch into normal pointing
        static let tapTravel = 0.025
        static let tapDuration = 0.3
        static let doubleTapWindow = 0.4
        static let fullRange = 0.7           // travel that sweeps 0–100% at sensitivity 1.0
        static let baseStep = 0.045          // one key step, when falling back to media keys
        static let fineSlowdown = 3.0        // precise sliding moves the level this much slower
        static let dropoutGrace = 0.12       // seconds a slide survives the trackpad losing the finger
        static let dropoutReach = 0.1        // how far a re-found finger may be from where it was lost
        static let hapticInterval = 0.025
    }

    private let queue = DispatchQueue(label: "margin.touch-engine", qos: .userInteractive)
    private var config = EngineConfig()
    /// The global layout with the frontmost app's profile on top, worked out on the main thread.
    private var trackpadLayout = MarginCore.Layout.default
    private var gesture: Gesture?
    private var ignoredFinger: Int32?
    private var blockedUntilLift = false
    private var taps = DoubleTapTracker(window: Tuning.doubleTapWindow)
    private var lastHaptic = 0.0
    private var dropoutToken = 0
    /// A copy of the timer, so the dial can start at the time left.
    private var timer = TimerMachine()
    private var alarm: Alarm?
    private var alarmToken = 0
    private var alarmTap: AlarmTap?

    /// The ringing alarm, as `TimerService` set it.
    private struct Alarm {
        var pattern: AlarmPattern
        var device: UInt64
        var fingerDown = false
        var lastBurst: Double?
    }

    /// A touch while the alarm rings, watched to see whether it's a tap, which dismisses it.
    private struct AlarmTap {
        var device: UInt64
        var start: Double
        var origin: CGPoint
        var maxTravel = 0.0
        var multiFinger = false
    }

    private static let alarmPoll = 0.1

    /// Both values are copies, so nothing on this queue reads shared state. A gesture already
    /// running keeps the bindings it resolved in `begin`, so a switch never cuts it off.
    func update(_ newConfig: EngineConfig, trackpadLayout: MarginCore.Layout) {
        queue.async {
            self.config = newConfig
            self.trackpadLayout = trackpadLayout
            if !newConfig.enabled { self.cancel() }
        }
    }

    /// A copy of the timer's state, for where the dial starts.
    func updateTimer(_ machine: TimerMachine) {
        queue.async { self.timer = machine }
    }

    /// Starts or stops the alarm. While active, the pattern repeats as long as a finger rests on
    /// `device`, and a tap on any trackpad dismisses it. The pattern is a copy, like the config.
    func setAlarm(active: Bool, pattern: AlarmPattern, device: UInt64) {
        queue.async {
            self.alarmToken += 1
            self.alarmTap = nil
            guard active else {
                self.alarm = nil
                return
            }
            self.alarm = Alarm(pattern: pattern, device: device)
            self.pollAlarm(self.alarmToken)
        }
    }

    func reset() {
        queue.async {
            self.cancel()
            self.blockedUntilLift = false
            self.ignoredFinger = nil
        }
    }

    func enqueue(_ fingers: [Finger], timestamp: Double, uptime: Double, device: UInt64, isMouse: Bool) {
        queue.async { self.process(fingers, timestamp, uptime, device, isMouse) }
    }

    // MARK: Frame processing

    private func process(_ fingers: [Finger], _ ts: Double, _ uptime: Double, _ device: UInt64, _ isMouse: Bool) {
        // The alarm comes first, and even with Margin switched off, since the timer still rings.
        if alarm != nil, !isMouse {
            if alarmDismissed(by: fingers, ts, device) { return }
            defer {
                // Set after the gesture code, which may have cleared it, so the tap-to-click
                // that comes with a dismissing tap is swallowed.
                if alarmTap?.start == ts { InputGate.shared.setTapCandidate(true) }
            }
            processGesture(fingers, ts, uptime, device, isMouse)
            return
        }
        processGesture(fingers, ts, uptime, device, isMouse)
    }

    private func processGesture(_ fingers: [Finger], _ ts: Double, _ uptime: Double, _ device: UInt64,
                                _ isMouse: Bool) {
        guard config.enabled else { return }
        // One gesture at a time; ignore a second trackpad while the first is in use.
        if let g = gesture, g.device != device { return }

        switch fingers.count {
        case 0:
            blockedUntilLift = false
            ignoredFinger = nil
            guard var g = gesture else { return }
            if g.isEngaged {
                // The trackpad sometimes drops a finger for a frame or two mid-slide.
                // Hold the slide briefly so it can be picked back up.
                if g.lostAt == nil {
                    g.lostAt = ts
                    gesture = g
                    scheduleDropoutEnd()
                }
            } else {
                finish(g, at: ts, uptime: uptime, cancelled: false)
                gesture = nil
            }

        case 1:
            guard !blockedUntilLift else { return }
            let f = fingers[0]
            let p = CGPoint(x: f.x, y: f.y)

            guard var g = gesture else {
                guard f.id != ignoredFinger else { return }
                gesture = begin(f, p, ts, uptime, device, isMouse)
                if gesture == nil { ignoredFinger = f.id }
                return
            }

            if g.fingerID != f.id {
                if g.isEngaged, hypot(p.x - g.last.x, p.y - g.last.y) < Tuning.dropoutReach {
                    // Same finger, new identity: shift the origins so the value doesn't jump.
                    let shift = g.along(p) - g.along(g.last)
                    g.stepOrigin += shift
                    g.stepper?.shift(by: shift)
                    g.dial?.shift(by: shift)
                    g.start.x += p.x - g.last.x
                    g.last = p
                    g.fingerID = f.id
                } else {
                    finish(g, at: ts, uptime: uptime, cancelled: false)
                    gesture = begin(f, p, ts, uptime, device, isMouse)
                    if gesture == nil { ignoredFinger = f.id }
                    return
                }
            }
            g.lostAt = nil
            advance(&g, to: p)
            gesture = g

        default:
            // Two or more fingers: that's a scroll or a system gesture, never ours.
            blockedUntilLift = true
            cancel()
        }
    }

    private func begin(_ f: Finger, _ p: CGPoint, _ ts: Double, _ uptime: Double, _ device: UInt64,
                       _ isMouse: Bool) -> Gesture? {
        let c = config
        if c.requireModifier {
            let mods = NSEvent.modifierFlags
            guard mods.contains(.function) || mods.contains(.option) else { return nil }
        }
        // A physical click is held: the user is dragging something.
        guard NSEvent.pressedMouseButtons == 0 else { return nil }

        let layout = isMouse ? c.layout : trackpadLayout
        let hit = ZoneGeometry.lookup(x: p.x, y: p.y, edgeWidth: c.edgeWidth,
                                      bottomQuarterOnly: c.bottomQuarterOnly, isMouse: isMouse)
        var slide = SlideAction.none
        if let edge = hit.edge, hit.edgeGestures.contains(.slide) {
            slide = Self.runnable(layout.edge(edge).slide)
        }
        // A corner bound to nothing lets its taps fall through to the edge under it.
        let tapZone = hit.tapZone { Self.runnable(layout.tap($0)) != .none }
        let tap = tapZone.map { layout.tap($0) } ?? .none
        guard slide != .none || tap != .none else { return nil }

        InputGate.shared.setTapCandidate(tap != .none)
        return Gesture(
            device: device,
            fingerID: f.id,
            startTime: ts,
            startUptime: uptime,
            start: p,
            last: p,
            anchor: CGEvent(source: nil)?.location ?? .zero,
            edge: slide == .none ? nil : hit.edge,
            slide: slide,
            tapZone: tapZone,
            tap: tap,
            isMouse: isMouse
        )
    }

    /// Anything in the layout this build can't run yet (window commands, until phase 6) is
    /// treated as unbound, so it never claims a touch or swallows a click.
    private static func runnable(_ slide: SlideAction) -> SlideAction {
        Actions.canRun(slide) ? slide : .none
    }

    private static func runnable(_ command: Command) -> Command {
        Actions.canRun(command) ? command : .none
    }

    private static func levelKind(_ slide: SlideAction) -> LevelKind? {
        switch slide {
        case .level(.outputVolume): .volume
        case .level(.brightness): .brightness
        case .level(.inputVolume): .inputVolume
        default: nil
        }
    }

    private func advance(_ g: inout Gesture, to p: CGPoint) {
        g.last = p
        let dx = p.x - g.start.x
        let dy = p.y - g.start.y
        g.maxTravel = max(g.maxTravel, hypot(dx, dy))
        if g.maxTravel > Tuning.tapTravel { InputGate.shared.setTapCandidate(false) }

        // Travel along the edge, and across it. The side edges must be 1.5× more along than
        // across to engage, the top and bottom 2×, as in v1.2.
        let vertical = g.edge?.slidesVertically ?? true
        let along = vertical ? dy : dx
        let across = vertical ? dx : dy
        let ratio = vertical ? 1.5 : 2.0

        switch g.phase {
        case .pending:
            if case .level = g.slide, abs(along) > Tuning.slideStart, abs(along) > ratio * abs(across) {
                g.phase = .sliding
                g.stepOrigin = g.along(p)
                readLevel(into: &g)
                engage(g)
            } else if case .stepper = g.slide, abs(along) > Tuning.slideStart, abs(along) > ratio * abs(across) {
                g.phase = .sliding
                let spacing = DetentCounter.spacing(fullRange: Tuning.fullRange, sensitivity: config.sensitivity,
                                                    notches: config.hapticFeel.notches)
                g.stepper = DetentCounter(origin: g.along(p), spacing: spacing)
                engage(g)
            } else if g.slide == .timer, abs(along) > Tuning.slideStart, abs(along) > ratio * abs(across) {
                g.phase = .sliding
                // A full sweep has as many notches as the scale, so it feels like the volume edge.
                let spacing = DetentCounter.spacing(fullRange: Tuning.fullRange, sensitivity: config.sensitivity,
                                                    notches: Double(TimerScale.notches))
                g.dial = TimerDial(startMinutes: timer.dialStartMinutes(now: Date()), origin: g.along(p),
                                   spacing: spacing)
                engage(g)
                showDial(g.dial, lifted: false)
            } else if case .flick = g.slide, abs(along) > Tuning.swipeStart, abs(along) > ratio * abs(across) {
                g.phase = .swiping
                engage(g)
            } else if g.maxTravel > Tuning.rejectTravel {
                g.phase = .rejected
            }

        case .sliding:
            if case .stepper(let stepper) = g.slide {
                stepNotches(&g, stepper, to: p)
            } else if g.slide == .timer {
                turnDial(&g, to: p)
            } else {
                step(&g, to: p)
            }

        case .swiping:
            if !g.swipeFired, case .flick(let forward, let back) = g.slide, let edge = g.edge,
               abs(along) > Tuning.swipeFire {
                g.swipeFired = true
                perform(along > 0 ? forward : back, device: g.device, zone: edge, kind: .slide)
            }

        case .rejected:
            break
        }
    }

    private func readLevel(into g: inout Gesture) {
        switch Self.levelKind(g.slide) {
        case .volume:
            if let out = SystemControls.outputVolume() {
                g.level = Double(out.volume)
                g.muted = out.muted
            }
        case .brightness:
            g.level = SystemControls.brightness().map(Double.init)
        case .inputVolume:
            if let mic = SystemControls.inputVolume() {
                g.level = Double(mic.volume)
                g.muted = mic.muted
            }
        case nil:
            break
        }
        if let level = g.level {
            g.lastDetent = Int((level * config.hapticFeel.notches).rounded())
            g.detentsFine = false
        }
    }

    private func step(_ g: inout Gesture, to p: CGPoint) {
        guard let role = Self.levelKind(g.slide) else { return }
        let fine = config.preciseSliding
            || (config.fineControl && NSEvent.modifierFlags.isSuperset(of: [.shift, .option]))
        guard let level = g.level else {
            stepWithKeys(&g, role: role, to: p, fine: fine)
            return
        }

        // Continuous: the level tracks the finger, so the overlay moves smoothly.
        let rate = config.sensitivity / Tuning.fullRange / (fine ? Tuning.fineSlowdown : 1)
        let newLevel = min(max(level + (g.along(p) - g.stepOrigin) * rate, 0), 1)
        g.stepOrigin = g.along(p)
        guard newLevel != level else {
            // Already at 0% or 100%: nothing to set, but the overlay still shows the level, so a
            // slide past the end says "already full" or "already off" instead of seeming dead.
            showOverlay(role, level, muted: g.muted, changed: false)
            return
        }

        let applied: Bool
        switch role {
        case .volume:
            applied = SystemControls.setOutputVolume(Float(newLevel))
            if applied, g.muted, newLevel > level {
                SystemControls.setMuted(false)
                g.muted = false
            }
        case .brightness:
            applied = SystemControls.setBrightness(Float(newLevel))
        case .inputVolume:
            applied = SystemControls.setInputVolume(Float(newLevel))
            if applied, g.muted, newLevel > level {
                SystemControls.setInputMuted(false)
                g.muted = false
            }
        }
        guard applied else {
            g.level = nil
            return
        }
        g.level = newLevel

        // Precise sliding packs proportionally more, lighter notches into the range, so ticks
        // stay as far apart under the finger as on a normal slide but each one is a finer step.
        let notches = config.hapticFeel.notches * (fine ? Tuning.fineSlowdown : 1)
        let detent = Int((newLevel * notches).rounded())
        if fine != g.detentsFine {
            // Switched scales mid-slide: re-anchor without a spurious tick.
            g.detentsFine = fine
            g.lastDetent = detent
        } else if detent != g.lastDetent {
            g.lastDetent = detent
            haptic(g.device, softer: fine)
        }
        showOverlay(role, newLevel, muted: g.muted)
    }

    /// Fallback for outputs that can't be set directly: press the media keys once per step.
    private func stepWithKeys(_ g: inout Gesture, role: LevelKind, to p: CGPoint, fine: Bool) {
        // There are no media keys for the microphone; a mic without a settable volume does nothing.
        guard role != .inputVolume else { return }
        let size = Tuning.baseStep / config.sensitivity / (fine ? 2 : 1)
        let up: MediaKey = role == .volume ? .soundUp : .brightnessUp
        let down: MediaKey = role == .volume ? .soundDown : .brightnessDown

        var delta = g.along(p) - g.stepOrigin
        var changed = false
        while delta >= size {
            send(up, fine: fine)
            g.stepOrigin += size
            delta -= size
            changed = true
        }
        while delta <= -size {
            send(down, fine: fine)
            g.stepOrigin -= size
            delta += size
            changed = true
        }
        if changed { haptic(g.device, softer: fine) }
    }

    /// A stepper: one command per notch crossed, each with a tick, and a running count in the
    /// overlay. The count lives in the gesture, so it starts again from zero on the next touch.
    private func stepNotches(_ g: inout Gesture, _ stepper: Stepper, to p: CGPoint) {
        guard var counter = g.stepper else { return }
        let vertical = g.edge?.slidesVertically ?? true
        let shortcuts = stepper.shortcuts(slidingVertically: vertical)
        let crossed = counter.move(to: g.along(p))
        g.stepper = counter
        guard crossed != 0 else { return }
        for _ in 0..<abs(crossed) {
            Actions.fire(.keystroke(crossed > 0 ? shortcuts.forward : shortcuts.back))
        }
        haptic(g.device)
        let label = stepper.label(count: counter.notch, slidingVertically: vertical)
        let symbol = stepper.symbol(count: counter.notch, slidingVertically: vertical)
        DispatchQueue.main.async { LevelOverlay.shared.showCounter(symbol: symbol, label: label) }
    }

    /// One tick per notch, and the value in the overlay.
    private func turnDial(_ g: inout Gesture, to p: CGPoint) {
        guard var dial = g.dial else { return }
        let changed = dial.move(to: g.along(p))
        g.dial = dial
        guard changed else { return }
        haptic(g.device)
        showDial(dial, lifted: false)
    }

    /// Lifting starts, changes or cancels the timer. A dial lifted where it started changes
    /// nothing while a timer exists, so resting a finger on it to look is harmless.
    private func liftDial(_ g: Gesture) {
        guard let dial = g.dial else { return }
        let timerExists = timer.remaining(now: Date()) != nil
        guard dial.moved || (!timerExists && dial.minutes > 0) else { return }
        haptic(g.device, force: true)
        showDial(dial, lifted: true)
        let minutes = dial.minutes
        let device = g.device
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .marginTimerSet, object: nil,
                                            userInfo: ["minutes": minutes, "device": device])
        }
    }

    private func showDial(_ dial: TimerDial?, lifted: Bool) {
        guard let dial else { return }
        let minutes = dial.minutes
        DispatchQueue.main.async {
            LevelOverlay.shared.showCounter(symbol: "timer", label: TimerDial.label(minutes: minutes),
                                            detail: lifted ? nil : TimerDial.hint(minutes: minutes))
        }
    }

    private func engage(_ g: Gesture) {
        InputGate.shared.setTapCandidate(false)
        if g.isMouse {
            // The pointer follows the mouse body, not the finger, so only the scrolling needs stopping.
            InputGate.shared.setScrollSuppressed(true)
        } else if config.freezeCursor {
            InputGate.shared.freeze(at: g.anchor)
        }
    }

    private func finish(_ g: Gesture, at ts: Double, uptime: Double, cancelled: Bool) {
        if g.isEngaged {
            InputGate.shared.unfreeze()
            InputGate.shared.setScrollSuppressed(false)
            if g.phase == .sliding, g.slide == .timer, !cancelled { liftDial(g) }
            if g.phase == .sliding, let edge = g.edge { announce(edge, .slide) }
        }
        guard !cancelled, g.phase == .pending,
              ts - g.startTime < Tuning.tapDuration,
              g.maxTravel < Tuning.tapTravel,
              let zone = g.tapZone, g.tap != .none
        else { return }

        let clean = TapGuard.isClean(touchStart: g.startUptime, lift: uptime,
                                     lastPhysicalClick: InputGate.shared.lastPhysicalClick)
        if taps.tap(in: zone, at: ts, clean: clean) {
            perform(g.tap, device: g.device, zone: zone, kind: .doubleTap)
        }
    }

    /// Runs a tap or flick command, with its haptic, and reports the gesture.
    private func perform(_ command: Command, device: UInt64, zone: Zone, kind: GestureKind) {
        Actions.fire(command, device: device)
        switch command {
        case .toggleOutputMute, .toggleInputMute:
            // A heavier buzz, so mute can be felt without looking.
            if config.haptics { SystemControls.buzz(device: device) }
        default:
            haptic(device, force: true)
        }
        announce(zone, kind)
    }

    private func cancel() {
        if let g = gesture { finish(g, at: 0, uptime: 0, cancelled: true) }
        gesture = nil
        InputGate.shared.setTapCandidate(false)
    }

    private func scheduleDropoutEnd() {
        dropoutToken += 1
        let token = dropoutToken
        queue.asyncAfter(deadline: .now() + Tuning.dropoutGrace) {
            guard token == self.dropoutToken, let g = self.gesture, g.lostAt != nil else { return }
            // Only engaged slides wait out a dropout, and they never become taps, so the
            // click-guard time doesn't matter here.
            self.finish(g, at: g.lostAt ?? 0, uptime: ProcessInfo.processInfo.systemUptime, cancelled: false)
            self.gesture = nil
        }
    }

    // MARK: Alarm

    /// Watches a touch while the alarm rings. Returns true when it was a single tap, which
    /// dismisses the alarm and is swallowed: it never reaches the gesture code, so it can't
    /// also count towards a double-tap.
    private func alarmDismissed(by fingers: [Finger], _ ts: Double, _ device: UInt64) -> Bool {
        if device == alarm?.device { alarm?.fingerDown = !fingers.isEmpty }
        switch fingers.count {
        case 0:
            guard let tap = alarmTap, tap.device == device else { return false }
            alarmTap = nil
            guard !tap.multiFinger, ts - tap.start < Tuning.tapDuration, tap.maxTravel < Tuning.tapTravel
            else { return false }
            if let g = gesture, g.isEngaged { finish(g, at: ts, uptime: 0, cancelled: true) }
            gesture = nil
            // The click after the lift still has to be swallowed, so the candidate stays set
            // until that's had time to arrive.
            InputGate.shared.setTapCandidate(true)
            queue.asyncAfter(deadline: .now() + 0.4) {
                if self.gesture == nil { InputGate.shared.setTapCandidate(false) }
            }
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .marginAlarmDismissed, object: nil)
            }
            return true
        case 1:
            let p = CGPoint(x: fingers[0].x, y: fingers[0].y)
            guard var tap = alarmTap, tap.device == device else {
                alarmTap = AlarmTap(device: device, start: ts, origin: p)
                return false
            }
            tap.maxTravel = max(tap.maxTravel, hypot(p.x - tap.origin.x, p.y - tap.origin.y))
            // Pointing, not a tap: let its clicks through.
            if tap.maxTravel > Tuning.tapTravel, alarmTap?.maxTravel ?? 0 <= Tuning.tapTravel, gesture == nil {
                InputGate.shared.setTapCandidate(false)
            }
            alarmTap = tap
            return false
        default:
            alarmTap?.multiFinger = true
            return false
        }
    }

    /// Plays a burst of the pattern whenever one is due and a finger is on the alarm's trackpad,
    /// since the motor can't be felt otherwise. Polls rather than waiting a full interval, so a
    /// finger that lands is buzzed straight away.
    private func pollAlarm(_ token: Int) {
        guard token == alarmToken, var alarm else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if alarm.fingerDown, alarm.pattern.burstDue(lastBurst: alarm.lastBurst, now: now) {
            alarm.lastBurst = now
            self.alarm = alarm
            let strength: HapticStrength = alarm.pattern.strong ? .strong : .medium
            for offset in alarm.pattern.pulseOffsets {
                queue.asyncAfter(deadline: .now() + offset) {
                    guard token == self.alarmToken else { return }
                    SystemControls.tick(strength, device: alarm.device)
                }
            }
        }
        queue.asyncAfter(deadline: .now() + Self.alarmPoll) { self.pollAlarm(token) }
    }

    // MARK: Output

    private func send(_ key: MediaKey, fine: Bool = false) {
        DispatchQueue.main.async {
            SystemControls.press(key, fine: fine)
            NotificationCenter.default.post(name: .marginLevelsChanged, object: nil)
        }
    }

    private func announce(_ zone: Zone, _ kind: GestureKind) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .marginGestureCompleted, object: (zone, kind))
        }
    }

    /// `changed` is false when the level stayed put, so the menu isn't asked to re-read it.
    private func showOverlay(_ kind: LevelKind, _ level: Double, muted: Bool, changed: Bool = true) {
        DispatchQueue.main.async {
            LevelOverlay.shared.show(kind, level: level, muted: muted)
            if changed { NotificationCenter.default.post(name: .marginLevelsChanged, object: nil) }
        }
    }

    private func haptic(_ device: UInt64, force: Bool = false, softer: Bool = false) {
        guard config.haptics else { return }
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - lastHaptic > Tuning.hapticInterval else { return }
        lastHaptic = now
        let strength = softer ? config.hapticStrength.softer : config.hapticStrength
        SystemControls.tick(strength, device: device)
    }
}
