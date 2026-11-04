import Foundation

/// The user's own trackpad settings from System Settings, read so the zone editor can warn about
/// clashes.
public enum TrackpadSettings {
    /// The built-in trackpad's domain, then the Magic Trackpad's. System Settings usually writes
    /// both, but they can differ.
    public static let domains = ["com.apple.AppleMultitouchTrackpad",
                                 "com.apple.driver.AppleBluetoothMultitouch.trackpad"]
    static let cornerSecondaryClickKey = "TrackpadCornerSecondaryClick"

    /// The corner a `TrackpadCornerSecondaryClick` value turns into a right-click corner:
    /// 1 is bottom left, 2 is bottom right, and 0 or anything else is none.
    public static func rightClickCorner(cornerSecondaryClick value: Any?) -> Zone? {
        switch (value as? NSNumber)?.intValue {
        case 1: .bottomLeft
        case 2: .bottomRight
        default: nil
        }
    }

    /// Every bottom corner set as a right-click corner on any trackpad. `read` returns the
    /// `TrackpadCornerSecondaryClick` value from a defaults domain.
    public static func rightClickCorners(read: (String) -> Any?) -> Set<Zone> {
        Set(domains.compactMap { rightClickCorner(cornerSecondaryClick: read($0)) })
    }

    /// Reads the live settings. Synchronises first, so a change made in System Settings while
    /// Margin is running is seen.
    public static func rightClickCorners() -> Set<Zone> {
        rightClickCorners { domain in
            CFPreferencesAppSynchronize(domain as CFString)
            return CFPreferencesCopyAppValue(cornerSecondaryClickKey as CFString, domain as CFString)
        }
    }
}
