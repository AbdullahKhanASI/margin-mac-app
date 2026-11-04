/// Where a touch landed, and which gestures it could still become.
///
/// A touch can sit in an edge and a corner at once. If it slides, the edge gets it; if it taps,
/// the corner does (falling through to the edge's tap when the corner is unbound).
public struct ZoneHit: Equatable, Sendable {
    public var edge: Zone?
    /// What the edge can do with this touch: `.slide` and `.doubleTap` on a trackpad, only
    /// `.slide` on a Magic Mouse.
    public var edgeGestures: Set<GestureKind>
    /// Corners only ever take a double-tap.
    public var corner: Zone?

    public init(edge: Zone? = nil, edgeGestures: Set<GestureKind> = [], corner: Zone? = nil) {
        self.edge = edge
        self.edgeGestures = edge == nil ? [] : edgeGestures
        self.corner = corner
    }

    public static let miss = ZoneHit()
    public var isMiss: Bool { edge == nil && corner == nil }

    /// Where a double-tap on this touch goes, given what each zone is bound to: the corner if it
    /// has a command, otherwise the edge under it if that has one. `isBound` says whether a zone
    /// has a tap command the engine can run.
    public func tapZone(isBound: (Zone) -> Bool) -> Zone? {
        if let corner, isBound(corner) { return corner }
        if let edge, edgeGestures.contains(.doubleTap), isBound(edge) { return edge }
        return nil
    }
}

public enum ZoneGeometry {
    public static let cornerSize = 0.15
    /// The Magic Mouse surface is narrow; its edges need more room.
    public static let mouseEdgeWidth = 0.22

    /// Height of the top and bottom strips, each measured in from its own border.
    public static func stripHeight(edgeWidth: Double) -> Double { min(edgeWidth * 1.25, 0.12) }

    /// Works out the zone a touch starts in. Coordinates are normalised 0–1 with y = 0 at the bottom.
    ///
    /// The side edges run the full height and win over the top and bottom strips, which fill the
    /// space between them. The corners are separate 15% squares that overlap whichever edges
    /// they touch. `bottomQuarterOnly` ignores edge touches above the lower 25%, but leaves the
    /// corners alone, as v1.2 did for the top-right mute corner.
    public static func lookup(x: Double, y: Double, edgeWidth: Double, bottomQuarterOnly: Bool,
                              isMouse: Bool) -> ZoneHit {
        let w = isMouse ? max(edgeWidth, mouseEdgeWidth) : edgeWidth

        var side: Zone?
        if x < w {
            side = .leftEdge
        } else if x > 1 - w {
            side = .rightEdge
        }

        if isMouse {
            // Only the top half of the mouse, where a fingertip rests; the rest is where the hand grips.
            guard y >= 0.5, let side else { return .miss }
            return ZoneHit(edge: side, edgeGestures: [.slide])
        }

        let strip = stripHeight(edgeWidth: w)
        var edge: Zone? = side
        if edge == nil {
            if y < strip {
                edge = .bottomEdge
            } else if y > 1 - strip {
                edge = .topEdge
            }
        }
        if bottomQuarterOnly, y > 0.25 { edge = nil }

        return ZoneHit(edge: edge, edgeGestures: [.slide, .doubleTap], corner: corner(x: x, y: y))
    }

    private static func corner(x: Double, y: Double) -> Zone? {
        let left = x < cornerSize, right = x > 1 - cornerSize
        let bottom = y < cornerSize, top = y > 1 - cornerSize
        switch (left, right, top, bottom) {
        case (true, _, true, _): return .topLeft
        case (_, true, true, _): return .topRight
        case (true, _, _, true): return .bottomLeft
        case (_, true, _, true): return .bottomRight
        default: return nil
        }
    }
}
