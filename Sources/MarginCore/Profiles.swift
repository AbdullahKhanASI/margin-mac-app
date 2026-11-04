extension Layout {
    /// This layout with a profile's overrides on top. Anything the profile leaves nil keeps the
    /// global binding ("use global").
    public func applying(_ overrides: PartialLayout) -> Layout {
        var result = self
        for (zone, partial) in overrides.edges where zone.isEdge {
            var binding = edge(zone)
            if let slide = partial.slide { binding.slide = slide }
            if let swipeIn = partial.swipeIn { binding.swipeIn = swipeIn }
            if let tap = partial.tap { binding.tap = tap }
            result.edges[zone] = binding
        }
        for (zone, command) in overrides.corners where zone.isCorner {
            result.corners[zone] = command
        }
        return result
    }

    /// The layout the engine should use while `frontmostBundleID` is the active app: the global
    /// layout plus the first enabled profile for that app, if any.
    public static func effective(global: Layout, profiles: [AppProfile], frontmostBundleID: String?) -> Layout {
        guard let profile = AppProfile.active(in: profiles, frontmostBundleID: frontmostBundleID) else { return global }
        return global.applying(profile.overrides)
    }
}

extension AppProfile {
    /// The profile in charge while `frontmostBundleID` is the active app: the first enabled one
    /// for that bundle ID. Matching is by bundle ID only (decision 4).
    public static func active(in profiles: [AppProfile], frontmostBundleID: String?) -> AppProfile? {
        guard let frontmostBundleID else { return nil }
        return profiles.first { $0.enabled && $0.bundleID == frontmostBundleID }
    }
}

// MARK: - Editing a profile

/// The zone editor, opened from a profile, reads and writes one field at a time. Setting a field
/// to nil is "Use global".
extension PartialLayout {
    public func slide(_ zone: Zone) -> SlideAction? { edges[zone]?.slide }

    public func tap(_ zone: Zone) -> Command? {
        zone.isCorner ? corners[zone] : edges[zone]?.tap
    }

    public mutating func setSlide(_ slide: SlideAction?, for zone: Zone) {
        guard zone.isEdge else { return }
        editEdge(zone) { $0.slide = slide }
    }

    public mutating func setTap(_ command: Command?, for zone: Zone) {
        if zone.isCorner {
            corners[zone] = command
        } else {
            editEdge(zone) { $0.tap = command }
        }
    }

    /// Whether the profile changes anything about this zone, which the diagram tints.
    public func overrides(_ zone: Zone) -> Bool {
        if zone.isCorner { return corners[zone] != nil }
        guard let partial = edges[zone] else { return false }
        return partial.slide != nil || partial.swipeIn != nil || partial.tap != nil
    }

    /// An edge with nothing left overridden is dropped, so a profile set back to "Use global"
    /// saves the same as one that was never changed.
    private mutating func editEdge(_ zone: Zone, _ body: (inout PartialEdgeBinding) -> Void) {
        var partial = edges[zone] ?? PartialEdgeBinding()
        body(&partial)
        edges[zone] = partial == PartialEdgeBinding() ? nil : partial
    }
}

/// How the diagram draws a zone. On the main page every zone is `normal`; in a profile, the zones
/// it changes are tinted and the rest are faded, so the profile's changes stand out.
public enum ZoneEmphasis: Sendable {
    case normal, changed, faded

    public init(zone: Zone, profileOverrides: PartialLayout?) {
        guard let profileOverrides else {
            self = .normal
            return
        }
        self = profileOverrides.overrides(zone) ? .changed : .faded
    }
}

// MARK: - The profile list

extension Array where Element == AppProfile {
    /// Adds an empty profile for an app, unless it already has one.
    public mutating func addProfile(bundleID: String, name: String) {
        guard !contains(where: { $0.bundleID == bundleID }) else { return }
        append(AppProfile(bundleID: bundleID, name: name))
    }

    public mutating func removeProfile(bundleID: String) {
        removeAll { $0.bundleID == bundleID }
    }

    /// The stored name is what the menu shows when the app isn't running, so it's brought up to
    /// date whenever the app is seen. Returns whether anything changed, so an unchanged name
    /// doesn't rewrite the settings.
    @discardableResult
    public mutating func refreshName(bundleID: String, name: String) -> Bool {
        guard !name.isEmpty else { return false }
        var changed = false
        for i in indices where self[i].bundleID == bundleID && self[i].name != name {
            self[i].name = name
            changed = true
        }
        return changed
    }
}

// MARK: - Following the frontmost app

/// Decides what layout the trackpads get as apps come and go. It lives on the main thread, in
/// `Preferences`; the engine only ever sees the result.
public struct ProfileTracker: Sendable {
    public private(set) var frontmostBundleID: String?
    /// The trackpad layout last handed to the engine.
    public private(set) var applied: Layout?
    private let ownBundleID: String?

    /// `ownBundleID` is Margin's: opening its menu or a panel it shows mustn't switch the
    /// trackpad back to the global layout, so its activations are ignored.
    public init(ownBundleID: String?, frontmostBundleID: String? = nil) {
        self.ownBundleID = ownBundleID
        self.frontmostBundleID = frontmostBundleID == ownBundleID ? nil : frontmostBundleID
    }

    /// Records a newly active app. Returns whether the frontmost app changed.
    @discardableResult
    public mutating func activate(_ bundleID: String?) -> Bool {
        guard let bundleID, bundleID != ownBundleID, bundleID != frontmostBundleID else { return false }
        frontmostBundleID = bundleID
        return true
    }

    public func effective(global: Layout, profiles: [AppProfile]) -> Layout {
        Layout.effective(global: global, profiles: profiles, frontmostBundleID: frontmostBundleID)
    }

    public func activeProfile(in profiles: [AppProfile]) -> AppProfile? {
        AppProfile.active(in: profiles, frontmostBundleID: frontmostBundleID)
    }

    /// The trackpad layout to hand the engine now, or nil when it already has it. Switching
    /// between apps with no profile changes nothing, so the engine isn't disturbed.
    public mutating func layoutToApply(global: Layout, profiles: [AppProfile]) -> Layout? {
        let layout = effective(global: global, profiles: profiles)
        guard layout != applied else { return nil }
        applied = layout
        return layout
    }

    /// Records a layout handed to the engine some other way, such as with a settings change.
    public mutating func didApply(_ layout: Layout) {
        applied = layout
    }
}
