import AppKit

/// Owns the CGEvent tap. While a slide is in progress it pins the (hidden) pointer in place,
/// and it swallows the tap-to-click that a Quick Mute or media-strip tap would otherwise cause.
final class InputGate {
    static let shared = InputGate()

    private let lock = NSLock()
    private var tap: CFMachPort?

    private var frozen = false
    private var anchor = CGPoint.zero
    private var scrollSuppressed = false

    // Tap-to-click suppression. `fingerDown` and `lastLift` are written straight from the
    // multitouch thread so they are current when the synthesized click arrives.
    private var fingerDown = false
    private var lastLift: TimeInterval = 0
    private var tapCandidate = false
    private var droppedDowns = Set<UInt32>()

    var isInstalled: Bool { lock.withLock { tap != nil } }

    /// Creates the event tap. Fails (returns false) until Accessibility access is granted.
    @discardableResult
    func install() -> Bool {
        if isInstalled { return true }
        let types: [CGEventType] = [
            .mouseMoved, .leftMouseDragged, .rightMouseDragged,
            .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp, .scrollWheel,
        ]
        let mask = types.reduce(CGEventMask(0)) { $0 | (1 << $1.rawValue) }
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: gateCallback,
            userInfo: nil
        ) else { return false }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        lock.withLock { tap = port }
        return true
    }

    // MARK: Cursor freeze

    func freeze(at point: CGPoint) {
        let shouldFreeze = lock.withLock {
            guard !frozen else { return false }
            frozen = true
            anchor = point
            return true
        }
        guard shouldFreeze else { return }
        DispatchQueue.main.async {
            CGWarpMouseCursorPosition(point)
            CGAssociateMouseAndMouseCursorPosition(0)
            CGDisplayHideCursor(CGMainDisplayID())
        }
    }

    func unfreeze() {
        let wasFrozen = lock.withLock {
            defer { frozen = false }
            return frozen
        }
        guard wasFrozen else { return }
        DispatchQueue.main.async {
            CGAssociateMouseAndMouseCursorPosition(1)
            CGDisplayShowCursor(CGMainDisplayID())
        }
    }

    /// While sliding on a Magic Mouse, the same finger would otherwise scroll the window under it.
    func setScrollSuppressed(_ value: Bool) {
        lock.withLock { scrollSuppressed = value }
    }

    // MARK: Click suppression

    func fingerState(down: Bool) {
        lock.withLock {
            if fingerDown && !down { lastLift = ProcessInfo.processInfo.systemUptime }
            fingerDown = down
        }
    }

    /// Set by the engine when the current touch could be a Quick Mute / play-pause tap.
    func setTapCandidate(_ value: Bool) {
        lock.withLock { tapCandidate = value }
    }

    fileprivate func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = lock.withLock({ tap }) { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(event)
        }

        lock.lock()
        defer { lock.unlock() }

        switch type {
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged:
            if frozen {
                CGWarpMouseCursorPosition(anchor)
                return nil
            }
        case .leftMouseDown, .rightMouseDown:
            // Physical clicks happen with a finger down; tap-to-click arrives just after lift.
            let isTapClick = !fingerDown && tapCandidate
                && ProcessInfo.processInfo.systemUptime - lastLift < 0.35
            if frozen || isTapClick {
                droppedDowns.insert(type.rawValue)
                return nil
            }
        case .scrollWheel:
            if scrollSuppressed { return nil }
        case .leftMouseUp:
            if droppedDowns.remove(CGEventType.leftMouseDown.rawValue) != nil { return nil }
        case .rightMouseUp:
            if droppedDowns.remove(CGEventType.rightMouseDown.rawValue) != nil { return nil }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }
}

private func gateCallback(
    proxy: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    InputGate.shared.handle(type, event)
}
