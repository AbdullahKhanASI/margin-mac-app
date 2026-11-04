import MarginCore
import XCTest

final class CodableTests: XCTestCase {
    private func roundTrip<T: Codable & Equatable>(_ value: T, file: StaticString = #filePath, line: UInt = #line) {
        do {
            let data = try JSONEncoder().encode(value)
            let decoded = try JSONDecoder().decode(T.self, from: data)
            XCTAssertEqual(decoded, value, String(decoding: data, as: UTF8.self), file: file, line: line)
        } catch {
            XCTFail("\(value): \(error)", file: file, line: line)
        }
    }

    static let allCommands: [Command] = {
        var commands: [Command] = [
            .none,
            .toggleOutputMute, .toggleInputMute,
            .lockScreen, .screenshotRegion, .missionControl, .appWindows, .showDesktop,
            .startScreenSaver, .sleepDisplay,
            .timerStart(minutes: 25), .timerPauseResume, .timerCancel,
            .launchApp(bundleID: "com.apple.Safari"),
            .keystroke(KeyCombo(keyCode: 40, modifiers: 0x100000 | 0x20000)),
        ]
        let keys: [MediaKey] = [.soundUp, .soundDown, .brightnessUp, .brightnessDown, .mute, .play, .next, .previous]
        commands += keys.map(Command.media)
        commands += WindowAction.allCases.map(Command.window)
        return commands
    }()

    func testEveryCommandRoundTrips() {
        for command in Self.allCommands { roundTrip(command) }
    }

    func testEverySlideActionRoundTrips() {
        let actions: [SlideAction] = [
            .none,
            .level(.outputVolume), .level(.inputVolume), .level(.brightness),
            .stepper(.undoRedo), .stepper(.tabs), .stepper(.spaces), .stepper(.arrowKeys),
            .flick(forward: .media(.next), back: .media(.previous)),
            .flick(forward: .window(.nextDisplay), back: .keystroke(KeyCombo(keyCode: 123))),
            .timer,
        ]
        for action in actions { roundTrip(action) }
    }

    func testLayoutAndProfileRoundTrip() {
        roundTrip(Layout.default)
        var layout = Layout.default
        layout.edges[.topEdge] = EdgeBinding(slide: .timer, swipeIn: .window(.maximize), tap: .missionControl)
        layout.corners[.bottomLeft] = .lockScreen
        roundTrip(layout)

        let profile = AppProfile(
            bundleID: "com.google.Chrome", name: "Chrome", enabled: false,
            overrides: PartialLayout(edges: [.bottomEdge: PartialEdgeBinding(slide: .stepper(.tabs))],
                                     corners: [.topRight: .none])
        )
        roundTrip(profile)
        roundTrip([profile])
    }

    /// Zone-keyed dictionaries should save as JSON objects keyed by zone name, not as
    /// alternating arrays, so the settings stay readable in `defaults read`.
    func testZoneDictionariesEncodeAsObjects() throws {
        let data = try JSONEncoder().encode(Layout.default)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let edges = try XCTUnwrap(json["edges"] as? [String: Any])
        XCTAssertEqual(Set(edges.keys), ["leftEdge", "rightEdge", "topEdge", "bottomEdge"])
    }
}
