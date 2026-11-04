import MarginCore
import XCTest

final class ProfileTests: XCTestCase {
    private let chromeTabs = AppProfile(
        bundleID: "com.google.Chrome", name: "Chrome",
        overrides: PartialLayout(
            edges: [.bottomEdge: PartialEdgeBinding(slide: .stepper(.tabs))],
            corners: [.topRight: .missionControl]
        )
    )

    func testNoFrontmostAppOrNoProfileUsesGlobal() {
        XCTAssertEqual(Layout.effective(global: .default, profiles: [chromeTabs], frontmostBundleID: nil), .default)
        XCTAssertEqual(Layout.effective(global: .default, profiles: [], frontmostBundleID: "com.google.Chrome"),
                       .default)
        XCTAssertEqual(Layout.effective(global: .default, profiles: [chromeTabs],
                                        frontmostBundleID: "com.apple.Safari"), .default)
    }

    func testMatchingProfileOverridesOnlyItsZones() {
        let result = Layout.effective(global: .default, profiles: [chromeTabs], frontmostBundleID: "com.google.Chrome")
        XCTAssertEqual(result.edge(.bottomEdge).slide, .stepper(.tabs))
        // The bottom tap wasn't overridden, so it stays global ("use global").
        XCTAssertEqual(result.edge(.bottomEdge).tap, .media(.play))
        XCTAssertEqual(result.corner(.topRight), .missionControl)
        XCTAssertEqual(result.edge(.rightEdge), Layout.default.edge(.rightEdge))
        XCTAssertEqual(result.edge(.leftEdge), Layout.default.edge(.leftEdge))
        XCTAssertEqual(result.corner(.bottomLeft), Command.none)
    }

    func testDisabledProfileIsIgnored() {
        var disabled = chromeTabs
        disabled.enabled = false
        XCTAssertEqual(Layout.effective(global: .default, profiles: [disabled],
                                        frontmostBundleID: "com.google.Chrome"), .default)
    }

    func testFirstEnabledProfileForTheAppWins() {
        var disabled = chromeTabs
        disabled.enabled = false
        disabled.overrides = PartialLayout(corners: [.topRight: .lockScreen])
        let result = Layout.effective(global: .default, profiles: [disabled, chromeTabs],
                                      frontmostBundleID: "com.google.Chrome")
        XCTAssertEqual(result.corner(.topRight), .missionControl)
    }

    func testOverrideCanUnbindAZone() {
        let profile = AppProfile(bundleID: "com.example.Game", name: "Game",
                                 overrides: PartialLayout(edges: [.rightEdge: PartialEdgeBinding(slide: SlideAction.none)],
                                                          corners: [.topRight: Command.none]))
        let result = Layout.effective(global: .default, profiles: [profile], frontmostBundleID: "com.example.Game")
        XCTAssertEqual(result.edge(.rightEdge).slide, SlideAction.none)
        XCTAssertEqual(result.corner(.topRight), Command.none)
    }

    func testAllNilOverridesChangeNothing() {
        let profile = AppProfile(bundleID: "a", name: "A",
                                 overrides: PartialLayout(edges: [.bottomEdge: PartialEdgeBinding()]))
        XCTAssertEqual(Layout.effective(global: .default, profiles: [profile], frontmostBundleID: "a"), .default)
    }

    /// A corner listed under edges, or an edge under corners, is malformed and ignored.
    func testMismatchedZonesAreIgnored() {
        let profile = AppProfile(bundleID: "a", name: "A",
                                 overrides: PartialLayout(edges: [.topRight: PartialEdgeBinding(tap: .lockScreen)],
                                                          corners: [.leftEdge: .lockScreen]))
        XCTAssertEqual(Layout.effective(global: .default, profiles: [profile], frontmostBundleID: "a"), .default)
    }

    func testProfileAppliesOnTopOfACustomGlobal() {
        var global = Layout.default
        global.sidesSwapped = true
        let result = Layout.effective(global: global, profiles: [chromeTabs], frontmostBundleID: "com.google.Chrome")
        XCTAssertTrue(result.sidesSwapped)
        XCTAssertEqual(result.edge(.bottomEdge).slide, .stepper(.tabs))
    }
}
