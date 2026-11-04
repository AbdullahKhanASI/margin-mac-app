import MarginCore
import XCTest

/// Stands in for `EngineConfig`, which lives in the app target: decodes only the layout, the way
/// `EngineConfig.init(from:)` does.
private struct LayoutProbe: Decodable {
    let layout: Layout
    init(from decoder: Decoder) throws { layout = try SettingsMigration.decodeLayout(from: decoder) }
}

final class SettingsMigrationTests: XCTestCase {
    private func decode(_ json: String) throws -> Layout {
        try JSONDecoder().decode(LayoutProbe.self, from: Data(json.utf8)).layout
    }

    /// Exactly what v1.2's synthesized encoder wrote for an untouched install.
    private let v12Defaults = """
    {"enabled":true,"haptics":true,"hapticStrength":"medium","hapticFeel":"standard","quickMute":true,
     "mediaStrip":true,"mediaPlayPause":true,"reverseMediaSwipe":false,"swapSides":false,
     "bottomQuarterOnly":false,"requireModifier":false,"freezeCursor":true,"preciseSliding":false,
     "fineControl":true,"includeExternal":true,"magicMouse":false,"sensitivity":1,"edgeWidth":0.08}
    """

    func testV12DefaultSettingsGiveDefaultLayout() throws {
        XCTAssertEqual(try decode(v12Defaults), .default)
    }

    func testV12CustomisedSettingsMigrate() throws {
        let json = """
        {"enabled":true,"haptics":false,"hapticStrength":"strong","hapticFeel":"rich","quickMute":false,
         "mediaStrip":true,"mediaPlayPause":false,"reverseMediaSwipe":true,"swapSides":true,
         "bottomQuarterOnly":true,"requireModifier":false,"freezeCursor":true,"preciseSliding":false,
         "fineControl":true,"includeExternal":true,"magicMouse":true,"sensitivity":1.4,"edgeWidth":0.1}
        """
        let expected = Layout.migrated(swapSides: true, quickMute: false, mediaStrip: true, mediaPlayPause: false,
                                       reverseMediaSwipe: true)
        XCTAssertEqual(try decode(json), expected)
        XCTAssertTrue(expected.sidesSwapped)
        XCTAssertTrue(expected.reverseMediaSwipe)
        XCTAssertFalse(expected.quickMute)
        XCTAssertFalse(expected.mediaPlayPause)
    }

    /// Settings from even older builds may lack some of the booleans; those take v1.2's defaults.
    func testMissingBooleansTakeV12Defaults() throws {
        XCTAssertEqual(try decode("{}"), .default)
        XCTAssertEqual(try decode(#"{"mediaStrip":false}"#),
                       Layout.migrated(swapSides: false, quickMute: true, mediaStrip: false, mediaPlayPause: true,
                                       reverseMediaSwipe: false))
    }

    /// Once a layout has been saved, stale booleans next to it are ignored.
    func testSavedLayoutWinsOverOldBooleans() throws {
        var layout = Layout.default
        layout.corners[.bottomLeft] = .lockScreen
        let layoutJSON = String(decoding: try JSONEncoder().encode(layout), as: UTF8.self)
        let json = #"{"swapSides":true,"quickMute":false,"layout":"# + layoutJSON + "}"
        XCTAssertEqual(try decode(json), layout)
    }
}
