import Foundation

/// Reads the layout out of saved engine settings. Settings written by v1.2 have no `layout` key,
/// only the five booleans, so the layout is rebuilt from those. Lives here rather than in
/// `EngineConfig.init(from:)` so it can be tested against real v1.2 data.
public enum SettingsMigration {
    private enum Keys: String, CodingKey {
        case layout
        // v1.2's booleans. Read for migration only; never written again.
        case swapSides, quickMute, mediaStrip, mediaPlayPause, reverseMediaSwipe
    }

    public static func decodeLayout(from decoder: Decoder) throws -> Layout {
        let c = try decoder.container(keyedBy: Keys.self)
        // A layout this build can't read, such as one saved by a newer build with a command this
        // one doesn't know, falls back like a missing one instead of failing the whole config,
        // which would reset every other setting too.
        if let layout = try? c.decodeIfPresent(Layout.self, forKey: .layout) { return layout }
        // Missing keys take v1.2's defaults, which together give `Layout.default`.
        return Layout.migrated(
            swapSides: try c.decodeIfPresent(Bool.self, forKey: .swapSides) ?? false,
            quickMute: try c.decodeIfPresent(Bool.self, forKey: .quickMute) ?? true,
            mediaStrip: try c.decodeIfPresent(Bool.self, forKey: .mediaStrip) ?? true,
            mediaPlayPause: try c.decodeIfPresent(Bool.self, forKey: .mediaPlayPause) ?? true,
            reverseMediaSwipe: try c.decodeIfPresent(Bool.self, forKey: .reverseMediaSwipe) ?? false
        )
    }
}
