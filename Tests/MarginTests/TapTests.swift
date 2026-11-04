import MarginCore
import XCTest

final class TapGuardTests: XCTestCase {
    func testNoClickIsClean() {
        XCTAssertTrue(TapGuard.isClean(touchStart: 10, lift: 10.15, lastPhysicalClick: nil))
    }

    func testClickDuringTheTouchSpoilsIt() {
        XCTAssertFalse(TapGuard.isClean(touchStart: 10, lift: 10.15, lastPhysicalClick: 10.08))
        // Both ends count as inside.
        XCTAssertFalse(TapGuard.isClean(touchStart: 10, lift: 10.15, lastPhysicalClick: 10))
        XCTAssertFalse(TapGuard.isClean(touchStart: 10, lift: 10.15, lastPhysicalClick: 10.15))
    }

    func testClickOutsideTheTouchDoesNot() {
        // An earlier click, for example the first half of a double-click on the previous touch.
        XCTAssertTrue(TapGuard.isClean(touchStart: 10, lift: 10.15, lastPhysicalClick: 9.8))
        XCTAssertTrue(TapGuard.isClean(touchStart: 10, lift: 10.15, lastPhysicalClick: 10.2))
    }
}

final class DoubleTapTrackerTests: XCTestCase {
    func testTwoQuickTapsMakeADoubleTap() {
        var taps = DoubleTapTracker(window: 0.4)
        XCTAssertFalse(taps.tap(in: .topRight, at: 1.0))
        XCTAssertTrue(taps.tap(in: .topRight, at: 1.3))
        // The pair is used up: a third tap starts a new one.
        XCTAssertFalse(taps.tap(in: .topRight, at: 1.5))
    }

    func testSlowTapsDont() {
        var taps = DoubleTapTracker(window: 0.4)
        XCTAssertFalse(taps.tap(in: .topRight, at: 1.0))
        XCTAssertFalse(taps.tap(in: .topRight, at: 1.5))
        XCTAssertTrue(taps.tap(in: .topRight, at: 1.8))
    }

    func testZonesDontPair() {
        var taps = DoubleTapTracker(window: 0.4)
        XCTAssertFalse(taps.tap(in: .bottomLeft, at: 1.0))
        XCTAssertFalse(taps.tap(in: .bottomEdge, at: 1.2))
        XCTAssertTrue(taps.tap(in: .bottomLeft, at: 1.3))
    }

    /// A double-click on a file in a corner: both touches have a physical click in them, so
    /// neither counts, and a clean tap right after can't pair with either.
    func testClicksNeverMakeADoubleTap() {
        var taps = DoubleTapTracker(window: 0.4)
        XCTAssertFalse(taps.tap(in: .bottomRight, at: 1.0, clean: false))
        XCTAssertFalse(taps.tap(in: .bottomRight, at: 1.2, clean: false))
        XCTAssertFalse(taps.tap(in: .bottomRight, at: 1.4))
        // A clean tap, then a click: the click breaks the pair.
        XCTAssertFalse(taps.tap(in: .bottomRight, at: 3.0))
        XCTAssertFalse(taps.tap(in: .bottomRight, at: 3.2, clean: false))
        XCTAssertFalse(taps.tap(in: .bottomRight, at: 3.4))
        XCTAssertTrue(taps.tap(in: .bottomRight, at: 3.6))
    }
}

final class TrackpadSettingsTests: XCTestCase {
    func testCornerValues() {
        XCTAssertNil(TrackpadSettings.rightClickCorner(cornerSecondaryClick: nil))
        XCTAssertNil(TrackpadSettings.rightClickCorner(cornerSecondaryClick: 0))
        XCTAssertEqual(TrackpadSettings.rightClickCorner(cornerSecondaryClick: 1), .bottomLeft)
        XCTAssertEqual(TrackpadSettings.rightClickCorner(cornerSecondaryClick: 2), .bottomRight)
        XCTAssertNil(TrackpadSettings.rightClickCorner(cornerSecondaryClick: 3))
        XCTAssertNil(TrackpadSettings.rightClickCorner(cornerSecondaryClick: "2"))
        // CFPreferences hands back NSNumbers.
        XCTAssertEqual(TrackpadSettings.rightClickCorner(cornerSecondaryClick: NSNumber(value: 2)), .bottomRight)
    }

    func testEitherTrackpadCounts() {
        func corners(_ builtIn: Any?, _ bluetooth: Any?) -> Set<Zone> {
            TrackpadSettings.rightClickCorners { domain in
                domain == "com.apple.AppleMultitouchTrackpad" ? builtIn : bluetooth
            }
        }
        XCTAssertEqual(corners(nil, nil), [])
        XCTAssertEqual(corners(0, 0), [])
        XCTAssertEqual(corners(2, 2), [.bottomRight])
        XCTAssertEqual(corners(nil, 1), [.bottomLeft])
        XCTAssertEqual(corners(1, 2), [.bottomLeft, .bottomRight])
    }

    func testReadsBothDomains() {
        var asked: [String] = []
        _ = TrackpadSettings.rightClickCorners { asked.append($0); return nil }
        XCTAssertEqual(asked, ["com.apple.AppleMultitouchTrackpad", "com.apple.driver.AppleBluetoothMultitouch.trackpad"])
    }

    /// The live read shouldn't crash or invent a corner; on this Mac it's whatever System Settings says.
    func testLiveReadIsABottomCornerOrNothing() {
        XCTAssertTrue(TrackpadSettings.rightClickCorners().isSubset(of: [.bottomLeft, .bottomRight]))
    }
}
