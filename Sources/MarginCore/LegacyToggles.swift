// The five v1.2 booleans, expressed as views onto a `Layout`. Migration builds a layout by setting
// them, so a v1.2 user's saved switches still turn into the layout they had. The menu's toggles
// that also used them are gone now the zone editor replaces them; migration still needs the
// setters, and the tests read the getters back.

extension Layout {
    /// Builds the layout a v1.2 user had from their saved booleans.
    public static func migrated(swapSides: Bool, quickMute: Bool, mediaStrip: Bool, mediaPlayPause: Bool,
                                reverseMediaSwipe: Bool) -> Layout {
        var layout = Layout.default
        layout.sidesSwapped = swapSides
        layout.quickMute = quickMute
        layout.reverseMediaSwipe = reverseMediaSwipe
        // In v1.2 the play/pause tap only worked while the strip itself was on.
        layout.mediaPlayPause = mediaPlayPause
        layout.mediaStrip = mediaStrip
        return layout
    }

    /// Swap Sides: volume on the left, brightness on the right.
    public var sidesSwapped: Bool {
        get { edge(.leftEdge).slide == .level(.outputVolume) }
        set {
            guard newValue != sidesSwapped else { return }
            var left = edge(.leftEdge), right = edge(.rightEdge)
            swap(&left.slide, &right.slide)
            edges[.leftEdge] = left
            edges[.rightEdge] = right
        }
    }

    /// Quick Mute: double-tap the top-right corner.
    public var quickMute: Bool {
        get { corner(.topRight) == .toggleOutputMute }
        set { corners[.topRight] = newValue ? .toggleOutputMute : Command.none }
    }

    /// Media Strip: the bottom edge's flick. Switching it off also switches off the bottom
    /// double-tap, because v1.2 only recognised strip taps while the strip was on; switching it
    /// back on restores both with today's defaults.
    public var mediaStrip: Bool {
        get { if case .flick = edge(.bottomEdge).slide { true } else { false } }
        set {
            guard newValue != mediaStrip else { return }
            var bottom = edge(.bottomEdge)
            bottom.slide = newValue ? .defaultFlick : .none
            bottom.tap = newValue ? .media(.play) : Command.none
            edges[.bottomEdge] = bottom
        }
    }

    /// Tap to Play or Pause: double-tap the bottom edge.
    public var mediaPlayPause: Bool {
        get { edge(.bottomEdge).tap == .media(.play) }
        set {
            var bottom = edge(.bottomEdge)
            bottom.tap = newValue ? .media(.play) : Command.none
            edges[.bottomEdge] = bottom
        }
    }

    /// Reverse Swipe: the bottom flick's commands swapped. Does nothing while there's no flick.
    public var reverseMediaSwipe: Bool {
        get {
            if case .flick(let forward, _) = edge(.bottomEdge).slide { forward == .media(.previous) } else { false }
        }
        set {
            guard newValue != reverseMediaSwipe, case .flick(let forward, let back) = edge(.bottomEdge).slide
            else { return }
            var bottom = edge(.bottomEdge)
            bottom.slide = .flick(forward: back, back: forward)
            edges[.bottomEdge] = bottom
        }
    }
}
