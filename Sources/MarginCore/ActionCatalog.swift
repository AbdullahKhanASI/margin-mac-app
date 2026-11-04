// What the zone editor offers: which actions fit which zone and gesture, how they're grouped,
// and what they're called. The app decides what it can run; everything here is filtered by that,
// so when a later phase teaches `Actions` a new command, the pickers list it with no change here.

extension Zone {
    public var title: String {
        switch self {
        case .leftEdge: "Left Edge"
        case .rightEdge: "Right Edge"
        case .topEdge: "Top Edge"
        case .bottomEdge: "Bottom Edge"
        case .topLeft: "Top-Left Corner"
        case .topRight: "Top-Right Corner"
        case .bottomLeft: "Bottom-Left Corner"
        case .bottomRight: "Bottom-Right Corner"
        }
    }
}

extension Layout {
    /// A zone's double-tap command: a corner's only binding, or an edge's tap.
    public func tap(_ zone: Zone) -> Command {
        zone.isCorner ? corner(zone) : edge(zone).tap
    }

    public mutating func setTap(_ command: Command, for zone: Zone) {
        if zone.isCorner {
            corners[zone] = command
        } else {
            edges[zone, default: .unbound].tap = command
        }
    }

    public mutating func setSlide(_ slide: SlideAction, for zone: Zone) {
        guard zone.isEdge else { return }
        edges[zone, default: .unbound].slide = slide
    }
}

/// One entry in a picker.
public struct CatalogOption<Choice: Hashable & Sendable>: Hashable, Identifiable, Sendable {
    public var id: Choice { choice }
    public let choice: Choice
    public let label: String
    public let symbol: String
}

/// A titled run of entries. `None` sits above the groups, in no group.
public struct CatalogGroup<Choice: Hashable & Sendable>: Hashable, Identifiable, Sendable {
    public var id: String { title }
    public let title: String
    public let options: [CatalogOption<Choice>]
}

/// A picker entry for a slide. A flick's two commands are edited beside the picker, so the
/// picker only chooses "Flick".
public enum SlideChoice: Hashable, Sendable {
    case none
    case level(LevelSource)
    case stepper(Stepper)
    case flick
    case timer

    public init(_ action: SlideAction) {
        switch action {
        case .none: self = .none
        case .level(let source): self = .level(source)
        case .stepper(let stepper): self = .stepper(stepper)
        case .flick: self = .flick
        case .timer: self = .timer
        }
    }

    /// What choosing this entry binds. A flick starts as today's media skip.
    public var action: SlideAction {
        switch self {
        case .none: .none
        case .level(let source): .level(source)
        case .stepper(let stepper): .stepper(stepper)
        case .flick: .defaultFlick
        case .timer: .timer
        }
    }
}

/// A picker entry for a command. Commands that need more input (an app, a shortcut, a duration)
/// are one entry each; the editor asks for the rest once it's chosen.
public enum CommandChoice: Hashable, Sendable {
    case command(Command)
    case timerStart
    case launchApp
    case keystroke

    public init(_ command: Command) {
        switch command {
        case .timerStart: self = .timerStart
        case .launchApp: self = .launchApp
        case .keystroke: self = .keystroke
        default: self = .command(command)
        }
    }

    /// A command of this kind, for asking whether the app can run it. The parameters are
    /// placeholders: the editor fills in the real ones.
    public var sample: Command {
        switch self {
        case .command(let command): command
        case .timerStart: .timerStart(minutes: 25)
        case .launchApp: .launchApp(bundleID: "com.apple.finder")
        case .keystroke: .keystroke(KeyCombo(keyCode: KeyCombo.Key.z, modifiers: KeyCombo.Modifier.command))
        }
    }
}

public enum ActionCatalog {
    // MARK: Slides

    /// The slide entries for an edge, grouped as Levels, Dials, Flick and Timer. Corners don't
    /// slide, so they get none.
    public static func slideGroups(for zone: Zone, canRun: (SlideAction) -> Bool) -> [CatalogGroup<SlideChoice>] {
        guard zone.isEdge else { return [] }
        let groups: [(String, [SlideChoice])] = [
            ("Levels", [.level(.outputVolume), .level(.inputVolume), .level(.brightness)]),
            ("Dials", [.stepper(.undoRedo), .stepper(.tabs), .stepper(.spaces), .stepper(.arrowKeys)]),
            ("Flick", [.flick]),
            ("Timer", [.timer]),
        ]
        return filtered(groups, runnable: { canRun($0.action) }, option: slideOption)
    }

    public static func slideOption(_ choice: SlideChoice) -> CatalogOption<SlideChoice> {
        let (label, symbol): (String, String) = switch choice {
        case .none: ("None", "circle.dashed")
        case .level(.outputVolume): ("Volume", "speaker.wave.2.fill")
        case .level(.inputVolume): ("Microphone", "mic.fill")
        case .level(.brightness): ("Brightness", "sun.max.fill")
        case .stepper(.undoRedo): ("Undo and Redo", "arrow.uturn.backward")
        case .stepper(.tabs): ("Switch Tabs", "square.on.square")
        case .stepper(.spaces): ("Switch Spaces", "rectangle.split.3x1")
        case .stepper(.arrowKeys): ("Arrow Keys", "arrow.up.and.down.and.arrow.left.and.right")
        case .flick: ("Flick", "arrow.left.and.right")
        case .timer: ("Timer", "timer")
        }
        return CatalogOption(choice: choice, label: label, symbol: symbol)
    }

    // MARK: Commands

    /// The double-tap entries for a zone. Corners are hot corners, so they list the system
    /// commands first; edges start with media.
    public static func tapGroups(for zone: Zone, canRun: (Command) -> Bool) -> [CatalogGroup<CommandChoice>] {
        commandGroups(systemFirst: zone.isCorner, canRun: canRun)
    }

    /// The entries for a flick's forward and back commands: any command, media first.
    public static func flickGroups(canRun: (Command) -> Bool) -> [CatalogGroup<CommandChoice>] {
        commandGroups(systemFirst: false, canRun: canRun)
    }

    private static func commandGroups(systemFirst: Bool, canRun: (Command) -> Bool) -> [CatalogGroup<CommandChoice>] {
        let media: (String, [CommandChoice]) = ("Media", [.command(.media(.play)), .command(.media(.next)),
                                                          .command(.media(.previous))])
        let sound: (String, [CommandChoice]) = ("Sound", [.command(.toggleOutputMute), .command(.toggleInputMute)])
        let system: (String, [CommandChoice]) = ("System", [
            .command(.lockScreen), .command(.screenshotRegion), .command(.missionControl), .command(.appWindows),
            .command(.showDesktop), .command(.startScreenSaver), .command(.sleepDisplay),
        ])
        let timer: (String, [CommandChoice]) = ("Timer", [.timerStart, .command(.timerPauseResume),
                                                          .command(.timerCancel)])
        let rest: [(String, [CommandChoice])] = [("Apps", [.launchApp]), ("Keystroke", [.keystroke])]
        let groups = (systemFirst ? [system, timer, media, sound] : [media, sound, system, timer]) + rest
        return filtered(groups, runnable: { canRun($0.sample) }, option: commandOption)
    }

    public static func commandOption(_ choice: CommandChoice) -> CatalogOption<CommandChoice> {
        let (label, symbol): (String, String) = switch choice {
        case .command(let command): commandNames(command)
        case .timerStart: ("Start Timer…", "timer")
        case .launchApp: ("Launch App…", "app.dashed")
        case .keystroke: ("Keystroke…", "keyboard")
        }
        return CatalogOption(choice: choice, label: label, symbol: symbol)
    }

    private static func commandNames(_ command: Command) -> (String, String) {
        switch command {
        case .none: ("None", "circle.dashed")
        case .media(.play): ("Play or Pause", "playpause.fill")
        case .media(.next): ("Next Track", "forward.fill")
        case .media(.previous): ("Previous Track", "backward.fill")
        case .media: ("Media Key", "music.note")
        case .toggleOutputMute: ("Mute", "speaker.slash")
        case .toggleInputMute: ("Mute Microphone", "mic.slash")
        case .window(let action): (windowLabel(action), "rectangle.split.2x1")
        case .lockScreen: ("Lock Screen", "lock")
        case .screenshotRegion: ("Screenshot", "camera.viewfinder")
        case .missionControl: ("Mission Control", "rectangle.3.group")
        case .appWindows: ("App Windows", "macwindow.on.rectangle")
        case .showDesktop: ("Show Desktop", "menubar.dock.rectangle")
        case .startScreenSaver: ("Screen Saver", "sparkles.tv")
        case .sleepDisplay: ("Sleep Display", "moon.zzz")
        case .timerStart(let minutes): ("Start \(minutes)-Minute Timer", "timer")
        case .timerPauseResume: ("Pause or Resume Timer", "playpause")
        case .timerCancel: ("Cancel Timer", "xmark.circle")
        case .launchApp: ("Launch App", "app.dashed")
        case .keystroke: ("Keystroke", "keyboard")
        }
    }

    private static func windowLabel(_ action: WindowAction) -> String {
        switch action {
        case .leftHalf: "Left Half"
        case .rightHalf: "Right Half"
        case .topHalf: "Top Half"
        case .bottomHalf: "Bottom Half"
        case .maximize: "Maximize"
        case .center: "Center"
        case .restore: "Restore"
        case .nextDisplay: "Next Display"
        }
    }

    // MARK: Shared

    /// Keeps the runnable entries and drops groups left empty, so nothing is ever shown that
    /// can't be used.
    private static func filtered<Choice>(_ groups: [(String, [Choice])], runnable: (Choice) -> Bool,
                                         option: (Choice) -> CatalogOption<Choice>) -> [CatalogGroup<Choice>] {
        groups.compactMap { title, choices in
            let options = choices.filter(runnable).map(option)
            return options.isEmpty ? nil : CatalogGroup(title: title, options: options)
        }
    }
}

extension SlideAction {
    public var label: String { ActionCatalog.slideOption(SlideChoice(self)).label }
    public var symbol: String { ActionCatalog.slideOption(SlideChoice(self)).symbol }
}

extension Command {
    /// The command's own name, such as "Mute" or "Start 25-Minute Timer". The editor names a
    /// launched app and a keystroke itself, because it needs the app's name and the keyboard layout.
    public var label: String { ActionCatalog.commandOption(.command(self)).label }
    public var symbol: String { ActionCatalog.commandOption(.command(self)).symbol }
}
