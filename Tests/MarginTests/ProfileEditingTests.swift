import MarginCore
import XCTest

/// "Use global", the diagram's tint and fade, and the profile list.
final class ProfileEditingTests: XCTestCase {
    func testSettingAFieldOverridesOnlyThatField() {
        var partial = PartialLayout()
        partial.setTap(.lockScreen, for: .bottomEdge)
        XCTAssertEqual(partial.tap(.bottomEdge), .lockScreen)
        XCTAssertNil(partial.slide(.bottomEdge))
        let result = Layout.default.applying(partial)
        XCTAssertEqual(result.edge(.bottomEdge).tap, .lockScreen)
        XCTAssertEqual(result.edge(.bottomEdge).slide, .defaultFlick)
    }

    func testUseGlobalClearsTheFieldAndDropsAnEmptyEdge() {
        var partial = PartialLayout()
        partial.setSlide(.stepper(.tabs), for: .bottomEdge)
        partial.setTap(.lockScreen, for: .bottomEdge)
        partial.setSlide(nil, for: .bottomEdge)
        XCTAssertNil(partial.slide(.bottomEdge))
        XCTAssertEqual(partial.tap(.bottomEdge), .lockScreen)
        partial.setTap(nil, for: .bottomEdge)
        // Back to "never changed", so it saves the same as a fresh profile.
        XCTAssertEqual(partial, PartialLayout())
    }

    func testUseGlobalKeepsAnOverriddenSwipeIn() {
        var partial = PartialLayout(edges: [.leftEdge: PartialEdgeBinding(swipeIn: .window(.leftHalf))])
        partial.setTap(.lockScreen, for: .leftEdge)
        partial.setTap(nil, for: .leftEdge)
        XCTAssertEqual(partial.edges[.leftEdge], PartialEdgeBinding(swipeIn: .window(.leftHalf)))
    }

    func testCornerOverridesAndUseGlobal() {
        var partial = PartialLayout()
        partial.setTap(Command.none, for: .topRight)
        // Unbinding is an override, not "use global".
        XCTAssertEqual(partial.tap(.topRight), Command.none)
        XCTAssertEqual(Layout.default.applying(partial).corner(.topRight), Command.none)
        partial.setTap(nil, for: .topRight)
        XCTAssertNil(partial.tap(.topRight))
        XCTAssertEqual(Layout.default.applying(partial), .default)
    }

    func testCornersHaveNoSlide() {
        var partial = PartialLayout()
        partial.setSlide(.level(.outputVolume), for: .topLeft)
        XCTAssertEqual(partial, PartialLayout())
    }

    func testOverridesAndEmphasis() {
        var partial = PartialLayout()
        partial.setTap(.missionControl, for: .bottomLeft)
        partial.setSlide(.stepper(.undoRedo), for: .rightEdge)
        XCTAssertTrue(partial.overrides(.bottomLeft))
        XCTAssertTrue(partial.overrides(.rightEdge))
        XCTAssertFalse(partial.overrides(.leftEdge))
        XCTAssertFalse(partial.overrides(.topRight))
        // An all-nil edge entry, as an old file might hold, isn't a change.
        partial.edges[.topEdge] = PartialEdgeBinding()
        XCTAssertFalse(partial.overrides(.topEdge))

        XCTAssertEqual(ZoneEmphasis(zone: .rightEdge, profileOverrides: partial), .changed)
        XCTAssertEqual(ZoneEmphasis(zone: .bottomLeft, profileOverrides: partial), .changed)
        XCTAssertEqual(ZoneEmphasis(zone: .leftEdge, profileOverrides: partial), .faded)
        XCTAssertEqual(ZoneEmphasis(zone: .topEdge, profileOverrides: partial), .faded)
        for zone in Zone.allCases {
            XCTAssertEqual(ZoneEmphasis(zone: zone, profileOverrides: nil), .normal)
        }
    }

    func testAddingRemovingAndRenamingProfiles() {
        var profiles: [AppProfile] = []
        profiles.addProfile(bundleID: "com.apple.Safari", name: "Safari")
        profiles.addProfile(bundleID: "com.apple.Safari", name: "Safari again")
        XCTAssertEqual(profiles.map(\.name), ["Safari"])
        XCTAssertTrue(profiles[0].enabled)
        XCTAssertEqual(profiles[0].overrides, PartialLayout())

        XCTAssertFalse(profiles.refreshName(bundleID: "com.apple.Safari", name: "Safari"))
        XCTAssertFalse(profiles.refreshName(bundleID: "com.apple.Safari", name: ""))
        XCTAssertFalse(profiles.refreshName(bundleID: "com.other", name: "Other"))
        XCTAssertTrue(profiles.refreshName(bundleID: "com.apple.Safari", name: "Safari Technology"))
        XCTAssertEqual(profiles[0].name, "Safari Technology")

        profiles.removeProfile(bundleID: "com.apple.Safari")
        XCTAssertTrue(profiles.isEmpty)
    }

    func testActiveProfileSkipsDisabledOnes() {
        var off = AppProfile(bundleID: "a", name: "A")
        off.enabled = false
        XCTAssertNil(AppProfile.active(in: [off], frontmostBundleID: "a"))
        XCTAssertNil(AppProfile.active(in: [AppProfile(bundleID: "a", name: "A")], frontmostBundleID: nil))
        XCTAssertEqual(AppProfile.active(in: [off, AppProfile(bundleID: "a", name: "On")],
                                         frontmostBundleID: "a")?.name, "On")
    }
}

/// When the engine is handed a new trackpad layout as apps come and go.
final class ProfileTrackerTests: XCTestCase {
    private let chrome = AppProfile(bundleID: "com.google.Chrome", name: "Chrome",
                                    overrides: PartialLayout(corners: [.topRight: .missionControl]))

    func testNoProfilesNeverChangesTheLayout() {
        var tracker = ProfileTracker(ownBundleID: "margin")
        tracker.didApply(.default)
        for app in ["com.apple.Safari", "com.apple.Notes", "com.google.Chrome"] {
            XCTAssertTrue(tracker.activate(app))
            XCTAssertNil(tracker.layoutToApply(global: .default, profiles: []))
        }
    }

    func testSwitchingIntoAndOutOfAProfiledApp() {
        var tracker = ProfileTracker(ownBundleID: "margin", frontmostBundleID: "com.apple.Safari")
        XCTAssertEqual(tracker.layoutToApply(global: .default, profiles: [chrome]), .default)

        tracker.activate("com.google.Chrome")
        XCTAssertEqual(tracker.activeProfile(in: [chrome])?.name, "Chrome")
        XCTAssertEqual(tracker.layoutToApply(global: .default, profiles: [chrome])?.corner(.topRight),
                       .missionControl)
        // Asking again with nothing changed hands over nothing.
        XCTAssertNil(tracker.layoutToApply(global: .default, profiles: [chrome]))

        tracker.activate("com.apple.Notes")
        XCTAssertNil(tracker.activeProfile(in: [chrome]))
        XCTAssertEqual(tracker.layoutToApply(global: .default, profiles: [chrome]), .default)
    }

    func testTwoAppsWithIdenticalEffectLayoutsDoNotPush() {
        let safari = AppProfile(bundleID: "com.apple.Safari", name: "Safari", overrides: chrome.overrides)
        var tracker = ProfileTracker(ownBundleID: "margin", frontmostBundleID: "com.google.Chrome")
        XCTAssertNotNil(tracker.layoutToApply(global: .default, profiles: [chrome, safari]))
        tracker.activate("com.apple.Safari")
        XCTAssertNil(tracker.layoutToApply(global: .default, profiles: [chrome, safari]))
    }

    func testDisablingTheActiveProfileReturnsToGlobal() {
        var tracker = ProfileTracker(ownBundleID: "margin", frontmostBundleID: "com.google.Chrome")
        _ = tracker.layoutToApply(global: .default, profiles: [chrome])
        var off = chrome
        off.enabled = false
        XCTAssertEqual(tracker.layoutToApply(global: .default, profiles: [off]), .default)
        XCTAssertNil(tracker.activeProfile(in: [off]))
    }

    func testMarginItselfIsIgnored() {
        var tracker = ProfileTracker(ownBundleID: "margin", frontmostBundleID: "margin")
        XCTAssertNil(tracker.frontmostBundleID)
        tracker.activate("com.google.Chrome")
        XCTAssertFalse(tracker.activate("margin"))
        XCTAssertFalse(tracker.activate(nil))
        XCTAssertFalse(tracker.activate("com.google.Chrome"))
        XCTAssertEqual(tracker.frontmostBundleID, "com.google.Chrome")
    }

    func testDidApplyRecordsALayoutPushedWithASettingsChange() {
        var tracker = ProfileTracker(ownBundleID: "margin", frontmostBundleID: "com.google.Chrome")
        tracker.didApply(tracker.effective(global: .default, profiles: [chrome]))
        XCTAssertNil(tracker.layoutToApply(global: .default, profiles: [chrome]))
    }
}
