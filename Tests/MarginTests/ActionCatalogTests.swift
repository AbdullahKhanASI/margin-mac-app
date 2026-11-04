import MarginCore
import XCTest

final class ActionCatalogTests: XCTestCase {
    /// What this build runs, as `Actions.canRun` has it in phase 3.
    private func canRun(_ command: Command) -> Bool {
        switch command {
        case .none, .window, .timerStart, .timerPauseResume, .timerCancel: false
        case .launchApp(let id): !id.isEmpty
        default: true
        }
    }

    private func canRun(_ slide: SlideAction) -> Bool {
        switch slide {
        case .none, .timer: false
        case .flick(let forward, let back): canRun(forward) || canRun(back)
        default: true
        }
    }

    private func titles<C>(_ groups: [CatalogGroup<C>]) -> [String] { groups.map(\.title) }
    private func choices<C>(_ groups: [CatalogGroup<C>]) -> [C] { groups.flatMap { $0.options.map(\.choice) } }

    func testCornersDontSlide() {
        for zone in Zone.corners {
            XCTAssertTrue(ActionCatalog.slideGroups(for: zone, canRun: canRun).isEmpty, zone.rawValue)
        }
    }

    func testEdgeSlidesAreGroupedAndFiltered() {
        for zone in Zone.edges {
            let groups = ActionCatalog.slideGroups(for: zone, canRun: canRun)
            // The timer can't run yet, so its group is left out rather than shown disabled.
            XCTAssertEqual(titles(groups), ["Levels", "Dials", "Flick"])
            XCTAssertEqual(choices(groups), [
                .level(.outputVolume), .level(.inputVolume), .level(.brightness),
                .stepper(.undoRedo), .stepper(.tabs), .stepper(.spaces), .stepper(.arrowKeys),
                .flick,
            ])
        }
    }

    func testAGroupAppearsOnceItCanRun() {
        // Phase 5 widens the check; the picker grows with no change to the catalogue.
        let groups = ActionCatalog.slideGroups(for: .topEdge) { _ in true }
        XCTAssertEqual(titles(groups), ["Levels", "Dials", "Flick", "Timer"])
        let taps = ActionCatalog.tapGroups(for: .topEdge) { _ in true }
        XCTAssertEqual(titles(taps), ["Media", "Sound", "System", "Timer", "Apps", "Keystroke"])
    }

    func testEdgeTapsStartWithMedia() {
        let groups = ActionCatalog.tapGroups(for: .bottomEdge, canRun: canRun)
        XCTAssertEqual(titles(groups), ["Media", "Sound", "System", "Apps", "Keystroke"])
        XCTAssertEqual(groups.first?.options.first?.choice, .command(.media(.play)))
        XCTAssertFalse(choices(groups).contains(.command(.none)), "None sits above the groups")
    }

    func testCornersStartWithSystemCommands() {
        let groups = ActionCatalog.tapGroups(for: .bottomLeft, canRun: canRun)
        XCTAssertEqual(titles(groups), ["System", "Media", "Sound", "Apps", "Keystroke"])
        XCTAssertEqual(groups[0].options.map(\.label), [
            "Lock Screen", "Screenshot", "Mission Control", "App Windows", "Show Desktop", "Screen Saver",
            "Sleep Display",
        ])
        XCTAssertEqual(choices(groups).suffix(2), [.launchApp, .keystroke])
    }

    func testFlicksOfferEveryRunnableCommand() {
        let groups = ActionCatalog.flickGroups(canRun: canRun)
        XCTAssertEqual(choices(groups), choices(ActionCatalog.tapGroups(for: .bottomEdge, canRun: canRun)))
    }

    func testChoicesRoundTrip() {
        XCTAssertEqual(SlideChoice(.defaultFlick), .flick)
        XCTAssertEqual(SlideChoice(.flick(forward: .lockScreen, back: .none)), .flick)
        XCTAssertEqual(SlideChoice.flick.action, .defaultFlick)
        XCTAssertEqual(SlideChoice(.stepper(.spaces)).action, .stepper(.spaces))
        XCTAssertEqual(CommandChoice(.launchApp(bundleID: "com.apple.Safari")), .launchApp)
        XCTAssertEqual(CommandChoice(.keystroke(KeyCombo(keyCode: 1))), .keystroke)
        XCTAssertEqual(CommandChoice(.timerStart(minutes: 5)), .timerStart)
        XCTAssertEqual(CommandChoice(.missionControl), .command(.missionControl))
        XCTAssertEqual(CommandChoice(.none), .command(.none))
    }

    func testEveryEntryHasALabelAndSymbol() {
        let all = ActionCatalog.slideGroups(for: .leftEdge) { _ in true }.flatMap(\.options).map { ($0.label, $0.symbol) }
            + ActionCatalog.tapGroups(for: .topLeft) { _ in true }.flatMap(\.options).map { ($0.label, $0.symbol) }
        for (label, symbol) in all {
            XCTAssertFalse(label.isEmpty)
            XCTAssertFalse(symbol.isEmpty, label)
        }
        XCTAssertEqual(Command.toggleOutputMute.label, "Mute")
        XCTAssertEqual(Command.timerStart(minutes: 25).label, "Start 25-Minute Timer")
        XCTAssertEqual(SlideAction.level(.brightness).symbol, "sun.max.fill")
        XCTAssertEqual(Zone.bottomRight.title, "Bottom-Right Corner")
    }

    func testTapAndSlideEditing() {
        var layout = Layout.default
        XCTAssertEqual(layout.tap(.topRight), .toggleOutputMute)
        XCTAssertEqual(layout.tap(.bottomEdge), .media(.play))
        layout.setTap(.lockScreen, for: .bottomLeft)
        layout.setTap(.missionControl, for: .topEdge)
        layout.setSlide(.stepper(.spaces), for: .topEdge)
        layout.setSlide(.level(.brightness), for: .topLeft)   // corners don't slide: ignored
        XCTAssertEqual(layout.corner(.bottomLeft), .lockScreen)
        XCTAssertEqual(layout.edge(.topEdge), EdgeBinding(slide: .stepper(.spaces), tap: .missionControl))
        XCTAssertNil(layout.edges[.topLeft])
        // Editing one zone leaves the others alone.
        XCTAssertEqual(layout.edge(.bottomEdge), Layout.default.edge(.bottomEdge))
    }
}

final class ShortcutDisplayTests: XCTestCase {
    typealias M = KeyCombo.Modifier
    private func letters(_ code: UInt16) -> String? { [40: "k", 6: "z", 18: "1", 43: ","][code] }

    func testModifiersInMenuOrder() {
        XCTAssertEqual(KeyCombo(keyCode: 40, modifiers: M.command | M.shift).displayString(character: letters), "⇧⌘K")
        XCTAssertEqual(KeyCombo(keyCode: 6, modifiers: M.command | M.shift | M.option | M.control)
            .displayString(character: letters), "⌃⌥⇧⌘Z")
        XCTAssertEqual(KeyCombo(keyCode: 43, modifiers: M.command).displayString(character: letters), "⌘,")
        XCTAssertEqual(KeyCombo(keyCode: 18).displayString(character: letters), "1")
    }

    func testKeysWithFixedNames() {
        XCTAssertEqual(KeyCombo(keyCode: 49, modifiers: M.command).displayString(character: letters), "⌘Space")
        XCTAssertEqual(KeyCombo(keyCode: 36).displayString(character: letters), "↩")
        XCTAssertEqual(KeyCombo(keyCode: 48, modifiers: M.control).displayString(character: letters), "⌃⇥")
        XCTAssertEqual(KeyCombo(keyCode: 96).displayString(character: letters), "F5")
        XCTAssertEqual(KeyCombo(keyCode: 90).displayString(character: letters), "F20")
        // A layout's own name for a fixed key is never used.
        XCTAssertEqual(KeyCombo(keyCode: 124).displayString { _ in "x" }, "→")
    }

    func testFnIsShownOnlyWhereItMatters() {
        // Every Apple keyboard sends fn with the arrows and F-keys.
        XCTAssertEqual(KeyCombo(keyCode: 123, modifiers: M.control | M.function).displayString(character: letters), "⌃←")
        XCTAssertEqual(KeyCombo(keyCode: 103, modifiers: M.function).displayString(character: letters), "F11")
        // With a letter it's a deliberate part of the shortcut.
        XCTAssertEqual(KeyCombo(keyCode: 40, modifiers: M.function).displayString(character: letters), "fn K")
    }

    func testUnknownKeys() {
        XCTAssertEqual(KeyCombo(keyCode: 200, modifiers: M.command).displayString { _ in nil }, "⌘Key 200")
    }
}

final class ShortcutRecordingTests: XCTestCase {
    typealias M = KeyCombo.Modifier

    func testRecordsAKey() {
        var r = ShortcutRecording()
        XCTAssertEqual(r.modifiersChanged(M.command, at: 0), .waiting)
        XCTAssertEqual(r.modifiersChanged(M.command | M.shift, at: 0.1), .waiting)
        XCTAssertEqual(r.keyDown(keyCode: 40, modifiers: M.command | M.shift), .recorded(KeyCombo(keyCode: 40, modifiers: M.command | M.shift)))
    }

    func testKeepsOnlyShortcutModifiers() {
        var r = ShortcutRecording()
        let capsLock: UInt64 = 0x10000
        XCTAssertEqual(r.keyDown(keyCode: 123, modifiers: M.control | M.numericPad | M.function | capsLock),
                       .recorded(KeyCombo(keyCode: 123, modifiers: M.control | M.function)))
    }

    func testEscapeCancelsUnlessItHasModifiers() {
        var r = ShortcutRecording()
        XCTAssertEqual(r.keyDown(keyCode: 53, modifiers: 0), .cancelled)
        XCTAssertEqual(r.keyDown(keyCode: 53, modifiers: M.function), .cancelled)
        XCTAssertEqual(r.keyDown(keyCode: 53, modifiers: M.option | M.command),
                       .recorded(KeyCombo(keyCode: 53, modifiers: M.option | M.command)))
    }

    func testModifiersLetGoWithNoKeyMeansMacOSKeptIt() {
        // ⌘Space: ⌘ goes down, Spotlight takes the space bar, ⌘ comes back up.
        var r = ShortcutRecording()
        XCTAssertEqual(r.modifiersChanged(M.command, at: 1.0), .waiting)
        XCTAssertEqual(r.modifiersChanged(0, at: 1.6), .keptBySystem)
        // The next attempt starts clean.
        XCTAssertEqual(r.modifiersChanged(M.command, at: 2.0), .waiting)
        XCTAssertEqual(r.keyDown(keyCode: 40, modifiers: M.command), .recorded(KeyCombo(keyCode: 40, modifiers: M.command)))
    }

    func testABriefTouchOfAModifierIsNotAnAttempt() {
        var r = ShortcutRecording()
        XCTAssertEqual(r.modifiersChanged(M.shift, at: 1.0), .waiting)
        XCTAssertEqual(r.modifiersChanged(0, at: 1.1), .waiting)
    }

    func testFnAloneIsNotAnAttempt() {
        var r = ShortcutRecording()
        XCTAssertEqual(r.modifiersChanged(M.function, at: 0), .waiting)
        XCTAssertEqual(r.modifiersChanged(0, at: 1), .waiting)
    }
}
