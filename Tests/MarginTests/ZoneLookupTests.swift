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
        // Inside the corner but not the edge.
        XCTAssertEqual(hit(0.88, 0.9), ZoneHit(corner: .topRight))
        // Corner is 15% each way.
        XCTAssertNil(hit(0.84, 0.95).corner)
        XCTAssertNil(hit(0.95, 0.84).corner)
        // The other corners aren't zones until phase 2.
        XCTAssertNil(hit(0.03, 0.95).corner)
        XCTAssertNil(hit(0.03, 0.03).corner)
        XCTAssertNil(hit(0.97, 0.03).corner)
        XCTAssertTrue(hit(0.5, 0.97).isMiss)
    }

    func testBottomQuarterOnly() {
        XCTAssertNil(hit(0.03, 0.5, bottomQuarterOnly: true).edge)
        XCTAssertNil(hit(0.97, 0.26, bottomQuarterOnly: true).edge)
        XCTAssertEqual(hit(0.03, 0.24, bottomQuarterOnly: true).edge, .leftEdge)
        XCTAssertEqual(hit(0.5, 0.05, bottomQuarterOnly: true).edge, .bottomEdge)
        // The mute corner isn't affected, as in v1.2; only the edge under it is dropped.
        XCTAssertEqual(hit(0.97, 0.95, bottomQuarterOnly: true), ZoneHit(corner: .topRight))
    }

    func testMagicMouse() {
        let slideOnly: Set<GestureKind> = [.slide]
        // Mouse edges are at least 22% wide and only in the top half.
        XCTAssertEqual(hit(0.2, 0.7, mouse: true), ZoneHit(edge: .leftEdge, edgeGestures: slideOnly))
        XCTAssertEqual(hit(0.8, 0.7, mouse: true), ZoneHit(edge: .rightEdge, edgeGestures: slideOnly))
        XCTAssertTrue(hit(0.2, 0.4, mouse: true).isMiss)
        XCTAssertTrue(hit(0.5, 0.7, mouse: true).isMiss)
        // No corner and no bottom strip on the mouse, and bottomQuarterOnly doesn't apply.
        XCTAssertEqual(hit(0.95, 0.95, mouse: true), ZoneHit(edge: .rightEdge, edgeGestures: slideOnly))
        XCTAssertTrue(hit(0.5, 0.05, mouse: true).isMiss)
        XCTAssertEqual(hit(0.2, 0.7, bottomQuarterOnly: true, mouse: true).edge, .leftEdge)
        // A wider trackpad setting widens the mouse edges too.
        XCTAssertEqual(hit(0.28, 0.7, edgeWidth: 0.3, mouse: true).edge, .leftEdge)
    }
}
