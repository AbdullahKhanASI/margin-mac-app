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
}

public enum ZoneGeometry {
    public static let cornerSize = 0.15
    /// The Magic Mouse surface is narrow; its edges need more room.
    public static let mouseEdgeWidth = 0.22

    /// Height of the bottom strip, measured up from the bottom.
    public static func stripHeight(edgeWidth: Double) -> Double { min(edgeWidth * 1.25, 0.12) }

    /// Works out the zone a touch starts in. Coordinates are normalised 0–1 with y = 0 at the bottom.
    ///
    /// This is the v1.2 geometry: the side edges, the bottom strip between them and the top-right
    /// corner. Phase 2 adds the top edge and the other three corners here.
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
        if bottomQuarterOnly, y > 0.25 { side = nil }

        let corner: Zone? = x > 1 - cornerSize && y > 1 - cornerSize ? .topRight : nil
        let edge: Zone? = side ?? (y < stripHeight(edgeWidth: w) ? .bottomEdge : nil)
        return ZoneHit(edge: edge, edgeGestures: [.slide, .doubleTap], corner: corner)
    }
}
