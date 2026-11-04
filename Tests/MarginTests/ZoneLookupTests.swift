import MarginCore
import XCTest

final class ZoneLookupTests: XCTestCase {
    private func hit(_ x: Double, _ y: Double, edgeWidth: Double = 0.08, bottomQuarterOnly: Bool = false,
                     mouse: Bool = false) -> ZoneHit {
        ZoneGeometry.lookup(x: x, y: y, edgeWidth: edgeWidth, bottomQuarterOnly: bottomQuarterOnly, isMouse: mouse)
    }

    private let trackpad: Set<GestureKind> = [.slide, .doubleTap]

    func testSideEdges() {
        XCTAssertEqual(hit(0.03, 0.5), ZoneHit(edge: .leftEdge, edgeGestures: trackpad))
        XCTAssertEqual(hit(0.97, 0.5), ZoneHit(edge: .rightEdge, edgeGestures: trackpad))
        XCTAssertTrue(hit(0.5, 0.5).isMiss)
        // Just inside and just outside the default 8% edge.
        XCTAssertEqual(hit(0.079, 0.5).edge, .leftEdge)
        XCTAssertNil(hit(0.081, 0.5).edge)
        XCTAssertEqual(hit(0.921, 0.5).edge, .rightEdge)
        XCTAssertNil(hit(0.919, 0.5).edge)
    }

    func testEdgeWidthWidensTheEdges() {
        XCTAssertTrue(hit(0.1, 0.5).isMiss)
        XCTAssertEqual(hit(0.1, 0.5, edgeWidth: 0.12).edge, .leftEdge)
        XCTAssertEqual(hit(0.89, 0.5, edgeWidth: 0.15).edge, .rightEdge)
    }

    func testBottomStrip() {
        XCTAssertEqual(hit(0.5, 0.05), ZoneHit(edge: .bottomEdge, edgeGestures: trackpad))
        // The strip is 1.25 × the edge width tall: 0.1 at the default width...
        XCTAssertEqual(hit(0.5, 0.099).edge, .bottomEdge)
        XCTAssertNil(hit(0.5, 0.101).edge)
        // ...0.05 at a thin edge...
        XCTAssertNil(hit(0.5, 0.06, edgeWidth: 0.04).edge)
        // ...and never taller than 0.12.
        XCTAssertEqual(hit(0.5, 0.119, edgeWidth: 0.15).edge, .bottomEdge)
        XCTAssertNil(hit(0.5, 0.121, edgeWidth: 0.15).edge)
    }

    func testSideEdgeWinsOverBottomStrip() {
        XCTAssertEqual(hit(0.03, 0.03).edge, .leftEdge)
        XCTAssertEqual(hit(0.97, 0.03).edge, .rightEdge)
    }

    func testTopRightCorner() {
        // Inside both the corner and the right edge: slides go to the edge, taps to the corner.
        XCTAssertEqual(hit(0.97, 0.95), ZoneHit(edge: .rightEdge, edgeGestures: trackpad, corner: .topRight))
        // Inside the corner but not the edge or the top strip.
        XCTAssertEqual(hit(0.88, 0.89), ZoneHit(corner: .topRight))
        // Corner is 15% each way.
        XCTAssertNil(hit(0.84, 0.95).corner)
        XCTAssertNil(hit(0.95, 0.84).corner)
    }

    func testTopEdge() {
        XCTAssertEqual(hit(0.5, 0.95), ZoneHit(edge: .topEdge, edgeGestures: trackpad))
        // The same height as the bottom strip, measured down from the top: 0.1 at the default width...
        XCTAssertEqual(hit(0.5, 0.901).edge, .topEdge)
        XCTAssertNil(hit(0.5, 0.899).edge)
        // ...0.05 at a thin edge...
        XCTAssertNil(hit(0.5, 0.94, edgeWidth: 0.04).edge)
        XCTAssertEqual(hit(0.5, 0.96, edgeWidth: 0.04).edge, .topEdge)
        // ...and never taller than 0.12.
        XCTAssertEqual(hit(0.5, 0.881, edgeWidth: 0.15).edge, .topEdge)
        XCTAssertNil(hit(0.5, 0.879, edgeWidth: 0.15).edge)
        // The side edges win over it, as they do over the bottom strip.
        XCTAssertEqual(hit(0.03, 0.97).edge, .leftEdge)
        XCTAssertEqual(hit(0.97, 0.97).edge, .rightEdge)
    }

    func testAllFourCorners() {
        // Each corner overlaps the side edge and the strip it touches.
        XCTAssertEqual(hit(0.03, 0.97), ZoneHit(edge: .leftEdge, edgeGestures: trackpad, corner: .topLeft))
        XCTAssertEqual(hit(0.12, 0.97), ZoneHit(edge: .topEdge, edgeGestures: trackpad, corner: .topLeft))
        XCTAssertEqual(hit(0.12, 0.89), ZoneHit(corner: .topLeft))
        XCTAssertEqual(hit(0.03, 0.03), ZoneHit(edge: .leftEdge, edgeGestures: trackpad, corner: .bottomLeft))
        XCTAssertEqual(hit(0.12, 0.03), ZoneHit(edge: .bottomEdge, edgeGestures: trackpad, corner: .bottomLeft))
        XCTAssertEqual(hit(0.12, 0.12), ZoneHit(corner: .bottomLeft))
        XCTAssertEqual(hit(0.97, 0.03), ZoneHit(edge: .rightEdge, edgeGestures: trackpad, corner: .bottomRight))
        XCTAssertEqual(hit(0.88, 0.03), ZoneHit(edge: .bottomEdge, edgeGestures: trackpad, corner: .bottomRight))
        XCTAssertEqual(hit(0.88, 0.12), ZoneHit(corner: .bottomRight))
        // Outside every corner.
        XCTAssertNil(hit(0.16, 0.03).corner)
        XCTAssertNil(hit(0.03, 0.16).corner)
        XCTAssertNil(hit(0.84, 0.97).corner)
        XCTAssertTrue(hit(0.5, 0.5).isMiss)
    }

    /// The corners stay 15% whatever the edge width; only the edges under them change.
    func testCornersIgnoreEdgeWidth() {
        XCTAssertEqual(hit(0.12, 0.5, edgeWidth: 0.04).edge, nil)
        XCTAssertEqual(hit(0.12, 0.03, edgeWidth: 0.15), ZoneHit(edge: .leftEdge, edgeGestures: trackpad,
                                                                corner: .bottomLeft))
        XCTAssertEqual(hit(0.14, 0.14, edgeWidth: 0.04), ZoneHit(corner: .bottomLeft))
    }

    func testCornerTapFallsThroughToTheEdge() {
        let bottomLeft = hit(0.12, 0.03)
        // A bound corner takes the tap.
        XCTAssertEqual(bottomLeft.tapZone { $0 == .bottomLeft || $0 == .bottomEdge }, .bottomLeft)
        // An unbound corner passes it to the strip under it...
        XCTAssertEqual(bottomLeft.tapZone { $0 == .bottomEdge }, .bottomEdge)
        // ...and with neither bound, nobody gets it.
        XCTAssertNil(bottomLeft.tapZone { _ in false })
        // A corner off every edge has nothing to fall through to.
        XCTAssertNil(hit(0.12, 0.12).tapZone { $0 == .bottomEdge })
        // The default layout: the top-right corner mutes, the bottom corners play from the strip.
        let layout = Layout.default
        let bound: (Zone) -> Bool = { zone in
            zone.isCorner ? layout.corner(zone) != .none : layout.edge(zone).tap != .none
        }
        XCTAssertEqual(hit(0.97, 0.95).tapZone(isBound: bound), .topRight)
        XCTAssertEqual(hit(0.12, 0.03).tapZone(isBound: bound), .bottomEdge)
        XCTAssertEqual(hit(0.88, 0.03).tapZone(isBound: bound), .bottomEdge)
        XCTAssertNil(hit(0.12, 0.97).tapZone(isBound: bound))
        XCTAssertNil(hit(0.5, 0.95).tapZone(isBound: bound))
        // The side edges have no tap in the default layout, so their bottom corners stay quiet.
        XCTAssertNil(hit(0.03, 0.03).tapZone(isBound: bound))
    }

    /// Magic Mouse touches never become taps, so they never fall through.
    func testMouseHasNoTapZone() {
        XCTAssertNil(hit(0.2, 0.7, mouse: true).tapZone { _ in true })
    }

    func testBottomQuarterOnly() {
        XCTAssertNil(hit(0.03, 0.5, bottomQuarterOnly: true).edge)
        XCTAssertNil(hit(0.97, 0.26, bottomQuarterOnly: true).edge)
        XCTAssertEqual(hit(0.03, 0.24, bottomQuarterOnly: true).edge, .leftEdge)
        XCTAssertEqual(hit(0.5, 0.05, bottomQuarterOnly: true).edge, .bottomEdge)
        // The top edge is above the lower quarter, so it goes too.
        XCTAssertNil(hit(0.5, 0.95, bottomQuarterOnly: true).edge)
        // The corners aren't affected, as the mute corner wasn't in v1.2; only the edge under them is dropped.
        XCTAssertEqual(hit(0.97, 0.95, bottomQuarterOnly: true), ZoneHit(corner: .topRight))
        XCTAssertEqual(hit(0.12, 0.97, bottomQuarterOnly: true), ZoneHit(corner: .topLeft))
        XCTAssertEqual(hit(0.12, 0.03, bottomQuarterOnly: true),
                       ZoneHit(edge: .bottomEdge, edgeGestures: trackpad, corner: .bottomLeft))
    }

    func testMagicMouse() {
        let slideOnly: Set<GestureKind> = [.slide]
        // Mouse edges are at least 22% wide and only in the top half.
        XCTAssertEqual(hit(0.2, 0.7, mouse: true), ZoneHit(edge: .leftEdge, edgeGestures: slideOnly))
        XCTAssertEqual(hit(0.8, 0.7, mouse: true), ZoneHit(edge: .rightEdge, edgeGestures: slideOnly))
        XCTAssertTrue(hit(0.2, 0.4, mouse: true).isMiss)
        XCTAssertTrue(hit(0.5, 0.7, mouse: true).isMiss)
        // No corners and no top or bottom strip on the mouse, and bottomQuarterOnly doesn't apply.
        XCTAssertEqual(hit(0.95, 0.95, mouse: true), ZoneHit(edge: .rightEdge, edgeGestures: slideOnly))
        XCTAssertEqual(hit(0.05, 0.05, mouse: true), .miss)
        XCTAssertTrue(hit(0.5, 0.05, mouse: true).isMiss)
        XCTAssertTrue(hit(0.5, 0.97, mouse: true).isMiss)
        XCTAssertEqual(hit(0.2, 0.7, bottomQuarterOnly: true, mouse: true).edge, .leftEdge)
        // A wider trackpad setting widens the mouse edges too.
        XCTAssertEqual(hit(0.28, 0.7, edgeWidth: 0.3, mouse: true).edge, .leftEdge)
    }
}
