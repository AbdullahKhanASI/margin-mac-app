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
/// the config's `layout` says what that zone's slide and double-tap do.
final class TouchEngine {
    static let shared = TouchEngine()

    private enum Phase {
        case pending   // landed in a zone, waiting to see what the finger does
        case sliding   // following the finger with a `level` or `stepper` slide
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
    private var gesture: Gesture?
    private var ignoredFinger: Int32?
    private var blockedUntilLift = false
    private var taps = DoubleTapTracker(window: Tuning.doubleTapWindow)
    private var lastHaptic = 0.0
    private var dropoutToken = 0

    func update(_ newConfig: EngineConfig) {
        queue.async {
            self.config = newConfig
            if !newConfig.enabled { self.cancel() }
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

        let hit = ZoneGeometry.lookup(x: p.x, y: p.y, edgeWidth: c.edgeWidth,
                                      bottomQuarterOnly: c.bottomQuarterOnly, isMouse: isMouse)
        var slide = SlideAction.none
        if let edge = hit.edge, hit.edgeGestures.contains(.slide) {
            slide = Self.runnable(c.layout.edge(edge).slide)
        }
        // A corner bound to nothing lets its taps fall through to the edge under it.
        let tapZone = hit.tapZone { Self.runnable(c.layout.tap($0)) != .none }
        let tap = tapZone.map { c.layout.tap($0) } ?? .none
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

    /// Anything in the layout this build can't run yet (the timer, window and timer commands) is
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
            } else if case .flick = g.slide, abs(along) > Tuning.swipeStart, abs(along) > ratio * abs(across) {
                g.phase = .swiping
                engage(g)
            } else if g.maxTravel > Tuning.rejectTravel {
                g.phase = .rejected
            }

        case .sliding:
            if case .stepper(let stepper) = g.slide {
                stepNotches(&g, stepper, to: p)
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
        Actions.fire(command)
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
