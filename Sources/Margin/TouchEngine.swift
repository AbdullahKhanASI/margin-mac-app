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
    /// Posted on the main thread after a gesture does something; `object` is a `CompletedGesture`.
    static let marginGestureCompleted = Notification.Name("MarginGestureCompleted")
}

enum CompletedGesture {
    case volume, brightness, mute, skip, playPause
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
    TouchEngine.shared.enqueue(fingers, timestamp: timestamp, device: deviceID, isMouse: isMouse != 0)
}

/// Turns raw finger positions into edge gestures:
/// vertical slides on the left / right edges, swipes and double-taps on the bottom edge,
/// and a double-tap in the top-right corner.
final class TouchEngine {
    static let shared = TouchEngine()

    private enum Phase {
        case pending   // landed in a zone, waiting to see what the finger does
        case sliding   // adjusting volume / brightness
        case swiping   // media strip swipe
        case rejected  // ordinary pointer movement; leave it alone
    }

    private struct Gesture {
        var device: UInt64
        var fingerID: Int32
        var startTime: Double
        var start: CGPoint
        var last: CGPoint
        var anchor: CGPoint
        var role: LevelKind?
        var isStrip: Bool
        var isCorner: Bool
        var isMouse: Bool
        var phase = Phase.pending
        var stepOrigin = 0.0
        var level: Double?        // nil when the level can't be set directly; keys are used instead
        var muted = false
        var lastDetent = 0
        var detentsFine = false   // whether lastDetent was counted on the precise (denser) scale
        var maxTravel = 0.0
        var swipeFired = false
        var lostAt: Double?

        var isEngaged: Bool { phase == .sliding || phase == .swiping }
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
        static let cornerSize = 0.15
        static let mouseEdgeWidth = 0.22     // the Magic Mouse surface is narrow; its edges need more room
        static let dropoutGrace = 0.12       // seconds a slide survives the trackpad losing the finger
        static let dropoutReach = 0.1        // how far a re-found finger may be from where it was lost
        static let hapticInterval = 0.025
    }

    private let queue = DispatchQueue(label: "margin.touch-engine", qos: .userInteractive)
    private var config = EngineConfig()
    private var gesture: Gesture?
    private var ignoredFinger: Int32?
    private var blockedUntilLift = false
    private var lastCornerTap = -1.0
    private var lastStripTap = -1.0
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

    func enqueue(_ fingers: [Finger], timestamp: Double, device: UInt64, isMouse: Bool) {
        queue.async { self.process(fingers, timestamp, device, isMouse) }
    }

    // MARK: Frame processing

    private func process(_ fingers: [Finger], _ ts: Double, _ device: UInt64, _ isMouse: Bool) {
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
                finish(g, at: ts, cancelled: false)
                gesture = nil
            }

        case 1:
            guard !blockedUntilLift else { return }
            let f = fingers[0]
            let p = CGPoint(x: f.x, y: f.y)

            guard var g = gesture else {
                guard f.id != ignoredFinger else { return }
                gesture = begin(f, p, ts, device, isMouse)
                if gesture == nil { ignoredFinger = f.id }
                return
            }

            if g.fingerID != f.id {
                if g.isEngaged, hypot(p.x - g.last.x, p.y - g.last.y) < Tuning.dropoutReach {
                    // Same finger, new identity: shift the origins so the value doesn't jump.
                    g.stepOrigin += p.y - g.last.y
                    g.start.x += p.x - g.last.x
                    g.last = p
                    g.fingerID = f.id
                } else {
                    finish(g, at: ts, cancelled: false)
                    gesture = begin(f, p, ts, device, isMouse)
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

    private func begin(_ f: Finger, _ p: CGPoint, _ ts: Double, _ device: UInt64, _ isMouse: Bool) -> Gesture? {
        let c = config
        if c.requireModifier {
            let mods = NSEvent.modifierFlags
            guard mods.contains(.function) || mods.contains(.option) else { return nil }
        }
        // A physical click is held: the user is dragging something.
        guard NSEvent.pressedMouseButtons == 0 else { return nil }

        let w = isMouse ? max(c.edgeWidth, Tuning.mouseEdgeWidth) : c.edgeWidth
        var role: LevelKind?
        if p.x < w {
            role = c.swapSides ? .volume : .brightness
        } else if p.x > 1 - w {
            role = c.swapSides ? .brightness : .volume
        }
        if isMouse {
            // Only the top half of the mouse, where a fingertip rests; the rest is where the hand grips.
            if p.y < 0.5 { role = nil }
            guard role != nil else { return nil }
        } else if c.bottomQuarterOnly, p.y > 0.25 {
            role = nil
        }

        let isCorner = !isMouse && c.quickMute && p.x > 1 - Tuning.cornerSize && p.y > 1 - Tuning.cornerSize
        let isStrip = !isMouse && c.mediaStrip && role == nil && p.y < min(w * 1.25, 0.12)
        guard role != nil || isCorner || isStrip else { return nil }

        InputGate.shared.setTapCandidate(isCorner || (isStrip && c.mediaPlayPause))
        return Gesture(
            device: device,
            fingerID: f.id,
            startTime: ts,
            start: p,
            last: p,
            anchor: CGEvent(source: nil)?.location ?? .zero,
            role: role,
            isStrip: isStrip,
            isCorner: isCorner,
            isMouse: isMouse
        )
    }

    private func advance(_ g: inout Gesture, to p: CGPoint) {
        g.last = p
        let dx = p.x - g.start.x
        let dy = p.y - g.start.y
        g.maxTravel = max(g.maxTravel, hypot(dx, dy))
        if g.maxTravel > Tuning.tapTravel { InputGate.shared.setTapCandidate(false) }

        switch g.phase {
        case .pending:
            if g.role != nil, abs(dy) > Tuning.slideStart, abs(dy) > 1.5 * abs(dx) {
                g.phase = .sliding
                g.stepOrigin = p.y
                readLevel(into: &g)
                engage(g)
            } else if g.isStrip, abs(dx) > Tuning.swipeStart, abs(dx) > 2 * abs(dy) {
                g.phase = .swiping
                engage(g)
            } else if g.maxTravel > Tuning.rejectTravel {
                g.phase = .rejected
            }

        case .sliding:
            step(&g, to: p)

        case .swiping:
            if !g.swipeFired, abs(dx) > Tuning.swipeFire {
                g.swipeFired = true
                let forward = (dx > 0) != config.reverseMediaSwipe
                send(forward ? .next : .previous)
                haptic(g.device, force: true)
                announce(.skip)
            }

        case .rejected:
            break
        }
    }

    private func readLevel(into g: inout Gesture) {
        switch g.role {
        case .volume:
            if let out = SystemControls.outputVolume() {
                g.level = Double(out.volume)
                g.muted = out.muted
            }
        case .brightness:
            g.level = SystemControls.brightness().map(Double.init)
        case nil:
            break
        }
        if let level = g.level {
            g.lastDetent = Int((level * config.hapticFeel.notches).rounded())
            g.detentsFine = false
        }
    }

    private func step(_ g: inout Gesture, to p: CGPoint) {
        guard let role = g.role else { return }
        let fine = config.preciseSliding
            || (config.fineControl && NSEvent.modifierFlags.isSuperset(of: [.shift, .option]))
        guard let level = g.level else {
            stepWithKeys(&g, role: role, to: p, fine: fine)
            return
        }

        // Continuous: the level tracks the finger, so the overlay moves smoothly.
        let rate = config.sensitivity / Tuning.fullRange / (fine ? Tuning.fineSlowdown : 1)
        let newLevel = min(max(level + (p.y - g.stepOrigin) * rate, 0), 1)
        g.stepOrigin = p.y
        guard newLevel != level else { return }

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
        let size = Tuning.baseStep / config.sensitivity / (fine ? 2 : 1)
        let up: MediaKey = role == .volume ? .soundUp : .brightnessUp
        let down: MediaKey = role == .volume ? .soundDown : .brightnessDown

        var delta = p.y - g.stepOrigin
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

    private func engage(_ g: Gesture) {
        InputGate.shared.setTapCandidate(false)
        if g.isMouse {
            // The pointer follows the mouse body, not the finger, so only the scrolling needs stopping.
            InputGate.shared.setScrollSuppressed(true)
        } else if config.freezeCursor {
            InputGate.shared.freeze(at: g.anchor)
        }
    }

    private func finish(_ g: Gesture, at ts: Double, cancelled: Bool) {
        if g.isEngaged {
            InputGate.shared.unfreeze()
            InputGate.shared.setScrollSuppressed(false)
            if g.phase == .sliding, let role = g.role {
                announce(role == .volume ? .volume : .brightness)
            }
        }
        guard !cancelled, g.phase == .pending,
              ts - g.startTime < Tuning.tapDuration,
              g.maxTravel < Tuning.tapTravel
        else { return }

        if g.isCorner {
            if lastCornerTap > 0, ts - lastCornerTap < Tuning.doubleTapWindow {
                lastCornerTap = -1
                if let out = SystemControls.outputVolume(), SystemControls.setMuted(!out.muted) {
                    showOverlay(.volume, Double(out.volume), muted: !out.muted)
                } else {
                    send(.mute)
                }
                announce(.mute)
                if config.haptics { SystemControls.buzz(device: g.device) }
            } else {
                lastCornerTap = ts
            }
        } else if g.isStrip, config.mediaPlayPause {
            if lastStripTap > 0, ts - lastStripTap < Tuning.doubleTapWindow {
                lastStripTap = -1
                send(.play)
                announce(.playPause)
                haptic(g.device, force: true)
            } else {
                lastStripTap = ts
            }
        }
    }

    private func cancel() {
        if let g = gesture { finish(g, at: 0, cancelled: true) }
        gesture = nil
        InputGate.shared.setTapCandidate(false)
    }

    private func scheduleDropoutEnd() {
        dropoutToken += 1
        let token = dropoutToken
        queue.asyncAfter(deadline: .now() + Tuning.dropoutGrace) {
            guard token == self.dropoutToken, let g = self.gesture, g.lostAt != nil else { return }
            self.finish(g, at: g.lostAt ?? 0, cancelled: false)
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

    private func announce(_ gesture: CompletedGesture) {
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: .marginGestureCompleted, object: gesture)
        }
    }

    private func showOverlay(_ kind: LevelKind, _ level: Double, muted: Bool) {
        DispatchQueue.main.async {
            LevelOverlay.shared.show(kind, level: level, muted: muted)
            NotificationCenter.default.post(name: .marginLevelsChanged, object: nil)
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
