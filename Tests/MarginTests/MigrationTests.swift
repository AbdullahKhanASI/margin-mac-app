import MarginCore
import XCTest

final class MigrationTests: XCTestCase {
    /// All 32 combinations of v1.2's booleans, each checked against a layout written out by hand
    /// from the v1.2 engine's rules rather than through the same setters migration uses.
    func testEveryCombinationOfOldBooleans() {
        for bits in 0..<32 {
            let swap = bits & 1 != 0
            let mute = bits & 2 != 0
            let strip = bits & 4 != 0
            let play = bits & 8 != 0
            let reverse = bits & 16 != 0
            let label = "swap=\(swap) mute=\(mute) strip=\(strip) play=\(play) reverse=\(reverse)"

            let layout = Layout.migrated(swapSides: swap, quickMute: mute, mediaStrip: strip,
                                         mediaPlayPause: play, reverseMediaSwipe: reverse)

            let flick: SlideAction = reverse
                ? .flick(forward: .media(.previous), back: .media(.next))
                : .flick(forward: .media(.next), back: .media(.previous))
            let expected = Layout(
                edges: [
                    .rightEdge: EdgeBinding(slide: .level(swap ? .brightness : .outputVolume)),
                    .leftEdge: EdgeBinding(slide: .level(swap ? .outputVolume : .brightness)),
                    // v1.2 only recognised strip taps while the strip was on.
                    .bottomEdge: EdgeBinding(slide: strip ? flick : .none,
                                             tap: strip && play ? .media(.play) : .none),
                    .topEdge: .unbound,
                ],
                corners: [
                    .topLeft: .none,
                    .topRight: mute ? .toggleOutputMute : .none,
                    .bottomLeft: .none,
                    .bottomRight: .none,
                ]
            )
            XCTAssertEqual(layout, expected, label)

            // The menu toggles read the same values back.
            XCTAssertEqual(layout.sidesSwapped, swap, label)
            XCTAssertEqual(layout.quickMute, mute, label)
            XCTAssertEqual(layout.mediaStrip, strip, label)
            XCTAssertEqual(layout.mediaPlayPause, strip && play, label)
            XCTAssertEqual(layout.reverseMediaSwipe, strip && reverse, label)
        }
    }

    func testV12DefaultsMigrateToDefaultLayout() {
        let layout = Layout.migrated(swapSides: false, quickMute: true, mediaStrip: true, mediaPlayPause: true,
                                     reverseMediaSwipe: false)
        XCTAssertEqual(layout, .default)
    }

    func testDefaultLayoutMatchesSpecTable() {
        let d = Layout.default
        XCTAssertEqual(d.edge(.rightEdge), EdgeBinding(slide: .level(.outputVolume)))
        XCTAssertEqual(d.edge(.leftEdge), EdgeBinding(slide: .level(.brightness)))
        XCTAssertEqual(d.edge(.bottomEdge),
                       EdgeBinding(slide: .flick(forward: .media(.next), back: .media(.previous)), tap: .media(.play)))
        XCTAssertEqual(d.edge(.topEdge), .unbound)
        XCTAssertEqual(d.corner(.topRight), .toggleOutputMute)
        for corner in [Zone.topLeft, .bottomLeft, .bottomRight] { XCTAssertEqual(d.corner(corner), Command.none) }
        for edge in Zone.edges { XCTAssertEqual(d.edge(edge).swipeIn, Command.none) }
    }

    // MARK: Menu toggles editing the layout

    func testSwapSidesTogglesBackAndForth() {
        var layout = Layout.default
        layout.sidesSwapped = true
        XCTAssertEqual(layout.edge(.leftEdge).slide, .level(.outputVolume))
        XCTAssertEqual(layout.edge(.rightEdge).slide, .level(.brightness))
        layout.sidesSwapped = true   // setting it again changes nothing
        XCTAssertEqual(layout.edge(.leftEdge).slide, .level(.outputVolume))
        layout.sidesSwapped = false
        XCTAssertEqual(layout, .default)
    }

    func testMediaStripOffAndOnRestoresDefaults() {
        var layout = Layout.default
        layout.mediaStrip = false
        XCTAssertEqual(layout.edge(.bottomEdge), .unbound)
        XCTAssertFalse(layout.mediaPlayPause)
        layout.mediaStrip = true
        XCTAssertEqual(layout, .default)
    }

    func testReverseSwipeDoesNothingWithoutAFlick() {
        var layout = Layout.default
        layout.mediaStrip = false
        layout.reverseMediaSwipe = true
        XCTAssertFalse(layout.reverseMediaSwipe)
        XCTAssertEqual(layout.edge(.bottomEdge).slide, SlideAction.none)
    }

    func testReverseSwipeKeepsTheTap() {
        var layout = Layout.default
        layout.reverseMediaSwipe = true
        XCTAssertEqual(layout.edge(.bottomEdge).tap, .media(.play))
        XCTAssertEqual(layout.edge(.bottomEdge).slide, .flick(forward: .media(.previous), back: .media(.next)))
        layout.reverseMediaSwipe = false
        XCTAssertEqual(layout, .default)
    }

    func testQuickMuteAndPlayPauseToggles() {
        var layout = Layout.default
        layout.quickMute = false
        XCTAssertEqual(layout.corner(.topRight), Command.none)
        layout.mediaPlayPause = false
        XCTAssertEqual(layout.edge(.bottomEdge).tap, Command.none)
        XCTAssertTrue(layout.mediaStrip)
        layout.quickMute = true
        layout.mediaPlayPause = true
        XCTAssertEqual(layout, .default)
    }
}
