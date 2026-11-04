// Swaps the saved layout for a test layout, to try zones and actions that have no menu yet.
// Run from the project root:
//
//   swift Scripts/try-layout.swift zones    # top edge flips tabs; corners: App Exposé, Screenshot, Spotlight
//   swift Scripts/try-layout.swift mic      # left edge mic level; top edge undo/redo, double-tap mutes the mic
//   swift Scripts/try-layout.swift system   # corners: Show Desktop, Screen Saver, Lock Screen, Sleep Display
//   swift Scripts/try-layout.swift reset    # back to the layout you had before the first preset
//   swift Scripts/try-layout.swift show     # print the saved layout
//
// Presets can be stacked; each changes only the zones it names. It quits Margin first, because a
// running Margin would write its own copy back, then relaunches it. Every other setting is kept.
// The zone editor in the menu sets all of these now; this stays as a quick way to load a test layout.
import Foundation

let domain = "com.abdullahkhan.Margin" as CFString
let key = "engineConfig" as CFString
// The layout from before the first preset, put back by `reset`. Margin never reads this key.
let backupKey = "tryLayoutBackup" as CFString

// The JSON Swift's synthesized Codable writes for each case.
func command(_ name: String, _ value: Any? = nil) -> [String: Any] { [name: value.map { ["_0": $0] } ?? [:]] }
let none = command("none")
func keystroke(_ keyCode: Int, _ modifiers: Int) -> [String: Any] {
    command("keystroke", ["keyCode": keyCode, "modifiers": modifiers])
}
let cmd = 0x100000
func edge(slide: [String: Any] = none, tap: [String: Any] = none) -> [String: Any] {
    ["slide": slide, "swipeIn": none, "tap": tap]
}
// Each preset changes only the zones it lists; the rest keep whatever the saved layout has.
let presets: [String: (edges: [String: Any], corners: [String: Any])] = [
    "zones": (
        edges: ["topEdge": edge(slide: command("stepper", "tabs"), tap: command("missionControl"))],
        corners: ["topLeft": command("appWindows"), "bottomLeft": command("screenshotRegion"),
                  "bottomRight": keystroke(49, cmd)]  // ⌘Space
    ),
    "mic": (
        edges: ["leftEdge": edge(slide: command("level", "inputVolume")),
                "topEdge": edge(slide: command("stepper", "undoRedo"), tap: command("toggleInputMute"))],
        corners: [:]
    ),
    "system": (
        edges: [:],
        corners: ["topLeft": command("showDesktop"), "topRight": command("startScreenSaver"),
                  "bottomLeft": command("lockScreen"), "bottomRight": command("sleepDisplay")]
    ),
]

// Layout.default, for an install that hasn't saved a layout yet.
let defaultLayout: [String: Any] = [
    "edges": ["rightEdge": edge(slide: command("level", "outputVolume")),
              "leftEdge": edge(slide: command("level", "brightness")),
              "topEdge": edge(),
              "bottomEdge": edge(slide: ["flick": ["forward": command("media", 17), "back": command("media", 18)]],
                                 tap: command("media", 16))],
    "corners": ["topLeft": none, "topRight": command("toggleOutputMute"), "bottomLeft": none, "bottomRight": none],
]

func run(_ path: String, _ args: [String]) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: path)
    p.arguments = args
    p.standardError = FileHandle.nullDevice
    try? p.run()
    p.waitUntilExit()
}

let choice = CommandLine.arguments.dropFirst().first ?? ""
guard choice == "reset" || choice == "show" || presets[choice] != nil else {
    print("usage: swift Scripts/try-layout.swift zones | mic | system | reset | show")
    exit(1)
}

CFPreferencesAppSynchronize(domain)
var config: [String: Any] = [:]
if let data = CFPreferencesCopyAppValue(key, domain) as? Data,
   let saved = try JSONSerialization.jsonObject(with: data) as? [String: Any] {
    config = saved
}

if choice == "show" {
    let layout = config["layout"].map { try! JSONSerialization.data(withJSONObject: $0, options: [.prettyPrinted, .sortedKeys]) }
    print(layout.map { String(decoding: $0, as: UTF8.self) } ?? "No saved layout: Margin uses the default.")
    exit(0)
}

if choice == "reset" {
    guard let backup = CFPreferencesCopyAppValue(backupKey, domain) as? Data else {
        print("No preset has been applied, so there's nothing to put back.")
        exit(0)
    }
    // An empty backup means there was no saved layout, so Margin goes back to the default.
    config["layout"] = backup.isEmpty ? nil : try JSONSerialization.jsonObject(with: backup)
    CFPreferencesSetAppValue(backupKey, nil, domain)
} else {
    let saved = config["layout"] as? [String: Any]
    if CFPreferencesCopyAppValue(backupKey, domain) == nil {
        let backup = try saved.map { try JSONSerialization.data(withJSONObject: $0) } ?? Data()
        CFPreferencesSetAppValue(backupKey, backup as CFData, domain)
    }
    var layout = saved ?? defaultLayout
    let preset = presets[choice]!
    layout["edges"] = (layout["edges"] as? [String: Any] ?? [:]).merging(preset.edges) { $1 }
    layout["corners"] = (layout["corners"] as? [String: Any] ?? [:]).merging(preset.corners) { $1 }
    config["layout"] = layout
}
// Quit Margin before writing, or it saves its own copy over this on the next settings change.
run("/usr/bin/killall", ["Margin"])
Thread.sleep(forTimeInterval: 0.5)
CFPreferencesSetAppValue(key, try JSONSerialization.data(withJSONObject: config) as CFData, domain)
CFPreferencesAppSynchronize(domain)

run("/usr/bin/open", ["-b", domain as String])
print(choice == "reset" ? "Your own layout is back; Margin relaunched." : "Preset '\(choice)' applied; Margin relaunched.")
