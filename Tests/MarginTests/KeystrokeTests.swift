import MarginCore
import XCTest

final class DetentCounterTests: XCTestCase {
    func testSpacingMatchesTheLevelEdges() {
        // The Default feel: 25 notches across 0.7 of travel at sensitivity 1.
        XCTAssertEqual(DetentCounter.spacing(fullRange: 0.7, sensitivity: 1, notches: 25), 0.028, accuracy: 1e-12)
        // Higher sensitivity packs them closer, as it speeds up a level.
        XCTAssertEqual(DetentCounter.spacing(fullRange: 0.7, sensitivity: 2, notches: 25), 0.014, accuracy: 1e-12)
    }

    func testCountsNotchesBothWays() {
        var counter = DetentCounter(origin: 0.5, spacing: 0.1)
        XCTAssertEqual(counter.move(to: 0.52), 0)
        // Notches sit on a grid centred on the origin, so the first one is half a spacing away.
        XCTAssertEqual(counter.move(to: 0.56), 1)
        XCTAssertEqual(counter.notch, 1)
        XCTAssertEqual(counter.move(to: 0.6), 0)
        // A fast move can cross several in one frame; each fires a command.
        XCTAssertEqual(counter.move(to: 0.86), 3)
        XCTAssertEqual(counter.notch, 4)
        // Back past the origin.
        XCTAssertEqual(counter.move(to: 0.3), -6)
        XCTAssertEqual(counter.notch, -2)
    }

    func testNoHysteresis() {
        // Like a level's detents, crossing a notch back undoes it straight away.
        var counter = DetentCounter(origin: 0, spacing: 0.1)
        XCTAssertEqual(counter.move(to: 0.051), 1)
        XCTAssertEqual(counter.move(to: 0.049), -1)
    }

    func testShiftKeepsTheCountAcrossADropout() {
        var counter = DetentCounter(origin: 0.5, spacing: 0.1)
        XCTAssertEqual(counter.move(to: 0.71), 2)
        // The finger comes back 0.03 further along; shifting the origin by that much means no jump.
        counter.shift(by: 0.03)
        XCTAssertEqual(counter.move(to: 0.74), 0)
        XCTAssertEqual(counter.move(to: 0.84), 1)
    }
}

final class StepperTests: XCTestCase {
    typealias M = KeyCombo.Modifier

    func testUndoRedo() {
        let keys = Stepper.undoRedo.shortcuts(slidingVertically: true)
        XCTAssertEqual(keys.back, KeyCombo(keyCode: 6, modifiers: M.command))              // ⌘Z
        XCTAssertEqual(keys.forward, KeyCombo(keyCode: 6, modifiers: M.shift | M.command)) // ⇧⌘Z
    }

    func testTabs() {
        let keys = Stepper.tabs.shortcuts(slidingVertically: false)
        XCTAssertEqual(keys.forward, KeyCombo(keyCode: 48, modifiers: M.control))           // ⌃Tab
        XCTAssertEqual(keys.back, KeyCombo(keyCode: 48, modifiers: M.control | M.shift))    // ⌃⇧Tab
    }

    func testSpacesGoRightWhicheverWayTheEdgeRuns() {
        for vertical in [true, false] {
            let keys = Stepper.spaces.shortcuts(slidingVertically: vertical)
            XCTAssertEqual(keys.forward, KeyCombo(keyCode: 124, modifiers: M.control))      // ⌃→
            XCTAssertEqual(keys.back, KeyCombo(keyCode: 123, modifiers: M.control))         // ⌃←
            // Posted as a real arrow key, or Mission Control ignores it.
            XCTAssertEqual(keys.forward.postedFlags, M.control | M.numericPad | M.function)
        }
    }

    func testArrowKeysFollowTheEdge() {
        let side = Stepper.arrowKeys.shortcuts(slidingVertically: true)
        XCTAssertEqual(side.forward, KeyCombo(keyCode: 126))   // ↑
        XCTAssertEqual(side.back, KeyCombo(keyCode: 125))      // ↓
        let bottom = Stepper.arrowKeys.shortcuts(slidingVertically: false)
        XCTAssertEqual(bottom.forward, KeyCombo(keyCode: 124)) // →
        XCTAssertEqual(bottom.back, KeyCombo(keyCode: 123))    // ←
    }

    func testLabels() {
        XCTAssertEqual(Stepper.undoRedo.label(count: -3, slidingVertically: true), "Undo ×3")
        XCTAssertEqual(Stepper.undoRedo.label(count: 1, slidingVertically: true), "Redo ×1")
        XCTAssertEqual(Stepper.undoRedo.label(count: 0, slidingVertically: true), "Undo")
        XCTAssertEqual(Stepper.tabs.label(count: 2, slidingVertically: false), "Tab →2")
        XCTAssertEqual(Stepper.tabs.label(count: -1, slidingVertically: false), "Tab ←1")
        XCTAssertEqual(Stepper.tabs.label(count: 0, slidingVertically: false), "Tab")
        XCTAssertEqual(Stepper.spaces.label(count: 2, slidingVertically: true), "Space →2")
        XCTAssertEqual(Stepper.spaces.label(count: -1, slidingVertically: false), "Space ←1")
        XCTAssertEqual(Stepper.arrowKeys.label(count: 3, slidingVertically: true), "Arrow ↑3")
        XCTAssertEqual(Stepper.arrowKeys.label(count: -2, slidingVertically: true), "Arrow ↓2")
        XCTAssertEqual(Stepper.arrowKeys.label(count: -1, slidingVertically: false), "Arrow ←1")
        XCTAssertEqual(Stepper.arrowKeys.label(count: 0, slidingVertically: false), "Arrow")
    }

    /// The modifier constants must be CGEventFlags' bits (and NSEvent's, which match).
    func testModifierBits() {
        XCTAssertEqual(M.shift, 1 << 17)
        XCTAssertEqual(M.control, 1 << 18)
        XCTAssertEqual(M.option, 1 << 19)
        XCTAssertEqual(M.command, 1 << 20)
        XCTAssertEqual(M.numericPad, 1 << 21)
        XCTAssertEqual(M.function, 1 << 23)
    }
}

final class SystemShortcutTests: XCTestCase {
    typealias M = KeyCombo.Modifier

    func testFixedShortcuts() {
        XCTAssertEqual(Command.lockScreen.shortcut, KeyCombo(keyCode: 12, modifiers: M.control | M.command))
        XCTAssertEqual(Command.screenshotRegion.shortcut, KeyCombo(keyCode: 21, modifiers: M.shift | M.command))
        XCTAssertEqual(Command.appWindows.shortcut, KeyCombo(keyCode: 125, modifiers: M.control))
        let combo = KeyCombo(keyCode: 40, modifiers: M.command | M.shift)
        XCTAssertEqual(Command.keystroke(combo).shortcut, combo)
        // Commands that aren't keystrokes.
        XCTAssertNil(Command.missionControl.shortcut)
        XCTAssertNil(Command.showDesktop.shortcut)
        XCTAssertNil(Command.media(.play).shortcut)
    }

    func testArrowKeysPostWithKeyboardFlags() {
        // ⌃↓ only matches App Exposé with the numeric-pad and fn bits a real arrow key carries.
        XCTAssertEqual(Command.appWindows.shortcut?.postedFlags, M.control | M.numericPad | M.function)
        // Other keys are posted as recorded.
        XCTAssertEqual(Command.lockScreen.shortcut?.postedFlags, M.control | M.command)
    }

    func testShowDesktopUsesTheUsersShortcut() {
        let hotKeys: [String: Any] = [
            // Changed to ⌃⌥D.
            "36": ["enabled": true, "value": ["parameters": [100, 2, 786432], "type": "standard"]],
        ]
        XCTAssertEqual(ShowDesktopShortcut.resolve(symbolicHotKeys: hotKeys),
                       KeyCombo(keyCode: 2, modifiers: M.control | M.option))
    }

    func testShowDesktopFallsBackToTheF11Default() {
        // macOS's own default, recorded as F11 with the fn bit.
        let fallback = KeyCombo(keyCode: 103, modifiers: M.function)
        XCTAssertEqual(ShowDesktopShortcut.resolve(symbolicHotKeys: nil), fallback)
        XCTAssertEqual(ShowDesktopShortcut.resolve(symbolicHotKeys: [String: Any]()), fallback)
        // Switched off in Keyboard Shortcuts.
        let off: [String: Any] = [
            "36": ["enabled": false, "value": ["parameters": [65535, 103, 8388608], "type": "standard"]],
        ]
        XCTAssertEqual(ShowDesktopShortcut.resolve(symbolicHotKeys: off), fallback)
        // Malformed.
        let short: [String: Any] = ["36": ["enabled": true, "value": ["parameters": [65535]]]]
        XCTAssertEqual(ShowDesktopShortcut.resolve(symbolicHotKeys: short), fallback)
    }
}
