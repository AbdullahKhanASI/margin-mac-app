import Foundation

// The gesture model: *zones* say where a touch lands, *actions* say what happens there.
// Every case the spec lists is defined now so the saved format stays stable as later phases
// teach the engine to run them. Phase 1 only runs the actions in `Layout.default`.

/// Where on the trackpad a gesture belongs.
public enum Zone: String, Codable, CaseIterable, CodingKeyRepresentable, Sendable {
    case leftEdge, rightEdge, topEdge, bottomEdge
    case topLeft, topRight, bottomLeft, bottomRight

    public static let edges: [Zone] = [.leftEdge, .rightEdge, .topEdge, .bottomEdge]
    public static let corners: [Zone] = [.topLeft, .topRight, .bottomLeft, .bottomRight]

    public var isEdge: Bool { Self.edges.contains(self) }
    public var isCorner: Bool { Self.corners.contains(self) }

    /// Left and right edges slide vertically; top and bottom slide horizontally.
    public var slidesVertically: Bool { self == .leftEdge || self == .rightEdge }
}

/// What a finished gesture was, reported alongside its zone.
public enum GestureKind: String, Codable, CaseIterable, Sendable {
    case slide      // along an edge: a level, stepper, flick or timer
    case swipeIn    // quickly away from an edge, toward the centre
    case doubleTap
}

/// Hardware key codes from IOKit's ev_keymap.h (NX_KEYTYPE_*).
public enum MediaKey: Int, Codable, Sendable {
    case soundUp = 0
    case soundDown = 1
    case brightnessUp = 2
    case brightnessDown = 3
    case mute = 7
    case play = 16
    case next = 17
    case previous = 18
}

public enum LevelSource: String, Codable, Sendable {
    case outputVolume, inputVolume, brightness
}

public enum Stepper: String, Codable, Sendable {
    case undoRedo       // ⌘Z / ⇧⌘Z
    case tabs           // ⌃⇧Tab / ⌃Tab
    case spaces         // ⌃← / ⌃→
    case arrowKeys      // ← → on horizontal edges, ↑ ↓ on vertical edges
}

public enum WindowAction: String, Codable, CaseIterable, Sendable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case maximize, center, restore, nextDisplay
}

/// A recorded shortcut. `modifiers` holds a `CGEventFlags` raw value; it's stored as a plain
/// integer so this module stays free of CoreGraphics.
public struct KeyCombo: Codable, Equatable, Sendable {
    public var keyCode: UInt16
    public var modifiers: UInt64

    public init(keyCode: UInt16, modifiers: UInt64 = 0) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }
}

/// A one-shot action, fired by a tap, an inward swipe, a flick or a stepper notch.
public enum Command: Codable, Equatable, Sendable {
    case none
    // Media and sound
    case media(MediaKey)
    case toggleOutputMute
    case toggleInputMute
    // Windows
    case window(WindowAction)
    // System (hot-corner commands)
    case lockScreen
    case screenshotRegion
    case missionControl
    case appWindows
    case showDesktop
    case startScreenSaver
    case sleepDisplay
    // Timer
    case timerStart(minutes: Int)
    case timerPauseResume
    case timerCancel
    // Anything else
    case launchApp(bundleID: String)
    case keystroke(KeyCombo)
}

/// What sliding along an edge does.
public enum SlideAction: Codable, Equatable, Sendable {
    case none
    case level(LevelSource)                      // continuous 0–1, follows the finger
    case stepper(Stepper)                        // one command per notch
    case flick(forward: Command, back: Command)  // fires once when travel passes the threshold
    case timer                                   // sets the timer dial
}

public struct EdgeBinding: Codable, Equatable, Sendable {
    public var slide: SlideAction
    public var swipeIn: Command
    public var tap: Command

    public init(slide: SlideAction = .none, swipeIn: Command = .none, tap: Command = .none) {
        self.slide = slide
        self.swipeIn = swipeIn
        self.tap = tap
    }

    public static let unbound = EdgeBinding()
}

public struct Layout: Codable, Equatable, Sendable {
    public var edges: [Zone: EdgeBinding]     // the four edge zones
    public var corners: [Zone: Command]       // the four corner zones

    public init(edges: [Zone: EdgeBinding], corners: [Zone: Command]) {
        self.edges = edges
        self.corners = corners
    }

    /// A missing entry reads as unbound, so a hand-edited or partial layout never crashes the engine.
    public func edge(_ zone: Zone) -> EdgeBinding { edges[zone] ?? .unbound }
    public func corner(_ zone: Zone) -> Command { corners[zone] ?? .none }

    /// Reproduces v1.2 exactly: volume on the right, brightness on the left, skip and play on the
    /// bottom, mute in the top-right corner. Inward swipes and the other zones start unbound.
    public static let `default` = Layout(
        edges: [
            .rightEdge: EdgeBinding(slide: .level(.outputVolume)),
            .leftEdge: EdgeBinding(slide: .level(.brightness)),
            .bottomEdge: EdgeBinding(slide: .defaultFlick, tap: .media(.play)),
            .topEdge: .unbound,
        ],
        corners: [
            .topLeft: .none,
            .topRight: .toggleOutputMute,
            .bottomLeft: .none,
            .bottomRight: .none,
        ]
    )
}

extension SlideAction {
    /// Today's media skip: swipe right for next, left for previous.
    public static let defaultFlick = SlideAction.flick(forward: .media(.next), back: .media(.previous))
}

/// A profile's changes on top of the global layout. A nil field, or a missing zone, means
/// "use global".
public struct PartialEdgeBinding: Codable, Equatable, Sendable {
    public var slide: SlideAction?
    public var swipeIn: Command?
    public var tap: Command?

    public init(slide: SlideAction? = nil, swipeIn: Command? = nil, tap: Command? = nil) {
        self.slide = slide
        self.swipeIn = swipeIn
        self.tap = tap
    }
}

public struct PartialLayout: Codable, Equatable, Sendable {
    public var edges: [Zone: PartialEdgeBinding]
    public var corners: [Zone: Command]

    public init(edges: [Zone: PartialEdgeBinding] = [:], corners: [Zone: Command] = [:]) {
        self.edges = edges
        self.corners = corners
    }
}

public struct AppProfile: Codable, Equatable, Identifiable, Sendable {
    public var id: String { bundleID }
    public var bundleID: String
    public var name: String                   // shown in the menu; refreshed when the app is next seen
    public var enabled: Bool
    public var overrides: PartialLayout       // only the zones this profile changes

    public init(bundleID: String, name: String, enabled: Bool = true, overrides: PartialLayout = PartialLayout()) {
        self.bundleID = bundleID
        self.name = name
        self.enabled = enabled
        self.overrides = overrides
    }
}
