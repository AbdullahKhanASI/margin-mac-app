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
        guard let frontmostBundleID,
              let profile = profiles.first(where: { $0.enabled && $0.bundleID == frontmostBundleID })
        else { return global }
        return global.applying(profile.overrides)
    }
}
