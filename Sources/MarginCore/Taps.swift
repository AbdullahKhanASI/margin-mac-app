/// A press on the trackpad is also a short touch that stays still, so a double-click on a file in
/// a corner looks just like a double-tap. `InputGate` notes when a physical click arrives while a
/// finger is down; a touch with a click inside it isn't a tap.
public enum TapGuard {
    /// Whether a touch from `touchStart` to `lift` was a clean tap, with no physical click during
    /// it. All three times must come from the same clock.
    public static func isClean(touchStart: Double, lift: Double, lastPhysicalClick: Double?) -> Bool {
        guard let click = lastPhysicalClick else { return true }
        return click < touchStart || click > lift
    }
}

/// Pairs taps into double-taps, separately for each zone, so a tap in one zone never pairs with
/// a tap in another.
public struct DoubleTapTracker: Sendable {
    public var window: Double
    private var lastTap: [Zone: Double] = [:]

    public init(window: Double) {
        self.window = window
    }

    /// Records a tap in `zone` and returns true when it completes a double-tap. A tap that wasn't
    /// clean breaks the pair, so a double-tap always needs two clean taps in a row.
    public mutating func tap(in zone: Zone, at time: Double, clean: Bool = true) -> Bool {
        guard clean else {
            lastTap[zone] = nil
            return false
        }
        if let last = lastTap[zone], time - last < window {
            lastTap[zone] = nil
            return true
        }
        lastTap[zone] = time
        return false
    }
}
