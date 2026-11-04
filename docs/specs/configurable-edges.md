# Spec: Configurable edges, app profiles, window snapping, hot corners and the timer dial

Status: draft · Target: v1.3.0-beta · Author: Abdullah Khan

## Summary

Today every zone of the trackpad has a fixed job: left and right edges slide volume and brightness, the bottom
strip skips and plays, and the top-right corner mutes. The jobs are wired into `TouchEngine` through
`role: LevelKind?`, `isStrip` and `isCorner`, and switched on or off by booleans in `EngineConfig`.

This change separates the *zones* (where a touch lands) from the *actions* (what happens). The user picks an action for
each zone in the menu. Optionally, a different set of actions can apply while a particular app is frontmost.

Three features are built on the new model:

- **Window snapping:** swipe inward from an edge to tile the frontmost window.
- **Hot corners on the trackpad:** all four corners become double-tap targets for system commands, apps or keystrokes.
- **Timer dial:** slide an edge to set a countdown. When it ends, the trackpad buzzes as a silent alarm.

The first release keeps today's behaviour as the default layout, so nobody's trackpad changes on update.

## Goals

- Any zone can be given any action that suits its gesture, picked from the menu bar panel.
- Add the unused zones: the top edge and the other three corners.
- Add a new gesture, the **inward swipe** from any edge, and use it for window snapping.
- Make all four corners usable as hot corners without catching physical clicks by mistake.
- Add the timer dial: set the time, count down in the menu bar, and buzz the trackpad at the end.
- Add app profiles: per-zone overrides that apply while a chosen app is frontmost.
- Keep the engine's current feel: dropout recovery, cursor freeze, haptic notches and suppressing tap-to-click.

## Non-goals (for this spec)

- Long-press and triple-tap.
- Clipboard history, Shortcuts with live values, Night Shift, keyboard backlight and DDC brightness. Each of these
  becomes a new action later, with no further changes to the model.
- Turning on a Focus mode directly; macOS has no public API for it. The timer can run a user-chosen Shortcut instead
  (see [Timer dial](#timer-dial)).
- Magic Mouse remapping. The mouse keeps its two top-edge level sliders, and app profiles don't apply to it.
- macOS's own window tiling. Snapping sets window frames through the Accessibility API on every macOS version (see
  [Decisions](#decisions)).
- Gestures with two or more fingers. The engine still rejects them.

## Model

### Zones and gestures

```swift
enum Zone: String, Codable, CaseIterable {
    case leftEdge, rightEdge, topEdge, bottomEdge
    case topLeft, topRight, bottomLeft, bottomRight
}
```

| Zone | Gesture | Motion |
|---|---|---|
| `leftEdge`, `rightEdge` | slide | along the edge, vertically |
| `topEdge`, `bottomEdge` | slide | along the edge, horizontally |
| any edge | swipe in | quickly away from the edge, toward the centre |
| any edge | double-tap | none |
| corners | double-tap | none |

Corners sit inside two edges. As today, a touch that starts in a corner is a candidate for both. If it slides, the edge
it slides along gets the gesture. If it taps, the corner gets it. A corner bound to `none` lets its taps fall through to
the edge's double-tap binding, if the edge has one. Inward swipes always belong to an edge, never to a corner.

### Bindings

Each edge has a *slide binding*, a *swipe-in binding* and a *tap binding*. Each corner has only a tap binding.

```swift
enum SlideAction: Codable, Equatable {
    case none
    case level(LevelSource)                    // continuous 0–1, follows the finger
    case stepper(Stepper)                      // one command per notch, with a haptic tick for each
    case flick(forward: Command, back: Command) // fires once when travel passes the threshold (today's skip)
    case timer                                 // sets the timer dial; starts the timer when the finger lifts
}

enum LevelSource: String, Codable { case outputVolume, inputVolume, brightness }

enum Stepper: String, Codable {
    case undoRedo       // ⌘Z / ⇧⌘Z
    case tabs           // ⌃⇧Tab / ⌃Tab
    case spaces         // ⌃← / ⌃→
    case arrowKeys      // ← → on horizontal edges, ↑ ↓ on vertical edges: caret nudge or frame stepping
}

enum WindowAction: String, Codable {
    case leftHalf, rightHalf, topHalf, bottomHalf
    case maximize, center, restore, nextDisplay
}

enum Command: Codable, Equatable {
    case none
    // Media and sound
    case media(MediaKey)                       // play, next, previous
    case toggleOutputMute
    case toggleInputMute
    // Windows
    case window(WindowAction)
    // System (hot-corner commands)
    case lockScreen
    case screenshotRegion
    case missionControl
    case appWindows                            // App Exposé
    case showDesktop
    case startScreenSaver
    case sleepDisplay
    // Timer
    case timerStart(minutes: Int)
    case timerPauseResume
    case timerCancel
    // Anything else
    case launchApp(bundleID: String)
    case keystroke(KeyCombo)                   // key code + modifier flags, recorded in the editor
}
```

Every action declares the gestures it fits. The editor lists only those, so a `level` can't be put on a corner. Any
`Command` can be used for a tap or an inward swipe. Window commands are listed first for swipes and system commands
first for corners.

The new `flick` keeps the media skip working exactly as it does now (`Tuning.swipeFire`, once per touch,
`reverseMediaSwipe` folded into the direction). The `stepper` and `timer` reuse the detent logic of `step()`: a notch
fires a command, or moves the dial, instead of moving a level.

### Layout and profiles

```swift
struct EdgeBinding: Codable, Equatable {
    var slide: SlideAction
    var swipeIn: Command
    var tap: Command
}

struct Layout: Codable, Equatable {
    var edges: [Zone: EdgeBinding]     // the four edge zones
    var corners: [Zone: Command]       // the four corner zones
}

struct AppProfile: Codable, Equatable, Identifiable {
    var id: String { bundleID }
    var bundleID: String
    var name: String                   // shown in the menu; refreshed when the app is next seen
    var enabled = true
    var overrides: PartialLayout       // only the zones this profile changes
}
```

`EngineConfig` gains `layout: Layout` and `profiles: [AppProfile]`. The engine never looks up profiles itself. On the
main thread, `Preferences` works out the *effective layout*: the global layout with the frontmost app's overrides on
top. Only that result goes into the `EngineConfig` copy handed to `TouchEngine.update`, so the engine keeps its rule of
never reading shared state from its own queue.

The frontmost app is tracked with `NSWorkspace.didActivateApplicationNotification`. When it changes, the effective
layout is recalculated, and `update` is called only if that layout actually differs. Profiles match on bundle ID
only. Chrome, for example, has one profile whichever site is open.

A layout switch must not cut off a gesture in progress. `update` stores the new config, but the gesture currently
running keeps the binding it started with until the finger lifts (`Gesture` stores its resolved binding).

### Default layout and migration

The default `Layout` reproduces today's behaviour. Inward swipes and the new corners start out unbound.

| Zone | Slide | Swipe in | Tap |
|---|---|---|---|
| right edge | `level(.outputVolume)` | none | none |
| left edge | `level(.brightness)` | none | none |
| bottom edge | `flick(next, previous)` | none | `media(.play)` |
| top edge | none | none | none |
| top-right | — | — | `toggleOutputMute` |
| other corners | — | — | none |

`EngineConfig.init(from:)` already decodes field by field. If `layout` is missing, it is built from the old booleans:

- `swapSides` swaps the left and right slide bindings.
- `quickMute == false` sets the top-right corner to `none`.
- `mediaStrip == false` sets the bottom slide to `none`.
- `mediaPlayPause == false` sets the bottom tap to `none`.
- `reverseMediaSwipe` swaps the `flick` commands.

After migration the old keys are no longer written. Until the zone editor ships in phase 3, the existing toggles stay
in the menu and edit the layout directly:

- Swap Sides swaps the left and right slide bindings.
- Quick Mute switches the top-right corner between `toggleOutputMute` and `none`.
- Media Strip and Tap to Play or Pause set the bottom slide and tap.
- Reverse Swipe swaps the `flick` commands.

Phase 3 removes these toggles, because the zone editor replaces them. `bottomQuarterOnly`, `requireModifier`, `freezeCursor`, the precise or fine
settings, `sensitivity`, `edgeWidth` and the device toggles stay global and stay where they are.

## Engine changes (`TouchEngine.swift`)

1. `begin()` decides the zone and looks up its binding in `config.layout` instead of setting `role`, `isStrip` and
   `isCorner`. `Gesture` keeps `zone` and the resolved `EdgeBinding` or corner `Command`.
2. The top edge joins the bottom strip logic. Its height comes from the same formula, `min(w * 1.25, 0.12)`, measured
   from the top.
3. The phases become `pending / sliding / swiping / maybeSwipeIn / rejected`. While a touch is `pending`:
   - Travel along the edge goes to the slide action: `sliding` for a level, stepper or timer, and `swiping` for a flick.
     The ratio tests stay as they are (`1.5×` for vertical edges, `2×` for horizontal ones).
   - Travel inward goes to `maybeSwipeIn` when the edge has a swipe-in binding. Otherwise it is `rejected`, as today.
     See [Inward swipe recognition](#inward-swipe-recognition).
4. While sliding, the engine dispatches on the action:
   - `level`: the current `step()`, with `inputVolume` added to `readLevel` and to the setter.
   - `stepper`: detent counting as in `step()`, using `fire(command)` for each notch, with no level stored.
   - `flick`: the current swipe branch.
   - `timer`: detent counting along the dial's scale, shown in the overlay. When the finger lifts, the engine posts
     `.marginTimerSet(minutes)` to the main thread.
5. `finish()` handles a double-tap for any zone whose `tap != .none`. Each zone keeps its own last-tap time (a
   dictionary keyed by `Zone`), replacing `lastCornerTap` and `lastStripTap`. A tap is ignored if a physical click
   happened during it (see [Hot corners](#hot-corners)).
6. `InputGate.setTapCandidate` is set when the zone has a tap binding, the same as today.
7. Every finished gesture posts `.marginGestureCompleted` with `object: (Zone, GestureKind)`, replacing
   `CompletedGesture`.

### Inward swipe recognition

An inward swipe begins exactly like ordinary pointer movement away from the edge. That makes it the riskiest gesture in
this spec. **An inward swipe only counts while ⌥ is held**, so ordinary pointing can never set it off. Because ⌥
already rules out accidents, the shape rules below only need to tell a swipe from a slow ⌥-drag.

| Rule | Value (to tune) | Why |
|---|---|---|
| ⌥ is held | checked when the swipe would fire (`NSEvent.modifierFlags`) | Ordinary pointing never fires it |
| Starts in the edge zone | within `edgeWidth` of the border | The same zone as the edge's other gestures |
| Inward travel before it fires | `≥ 0.15` | Clearly longer than a tap or a nudge |
| Direction | inward travel `≥ 2×` the travel along the edge | Rules out diagonal movement |
| Speed | reaches the threshold within `0.35 s` | A deliberate swipe, not a slow drag |
| Fingers | one; a second finger cancels it | Same as all Margin gestures |

⌥ is checked when the swipe would fire rather than when the touch begins. That way, pressing ⌥ a moment late still
works. It doesn't clash with Fine Control (⇧⌥): Fine Control only affects slides along an edge, and an inward swipe
moves across it. When the global **Require fn or ⌥** setting is on, ⌥ meets both requirements.

The pointer is **not** frozen while the engine is unsure, because most touches here are ordinary pointing. Once the
swipe fires, the engine warps the pointer back to the `anchor` recorded when the touch began, so the pointer seems not
to have moved. Then it fires the command and gives a forced haptic tick. If any rule fails, the touch goes to
`rejected` and behaves as pointing for the rest of the touch.

`Tuning.rejectTravel` (0.05) normally rejects a touch before travel can reach 0.15. `maybeSwipeIn` is therefore its own
phase with its own exit conditions: it ends when the time limit passes, the direction breaks, or the swipe fires.

The rules are written as a pure function (`classifyInwardSwipe(start:samples:edge:)`) in `MarginCore`, so they can be
tested with recorded touch paths.

## Running actions (`SystemControls.swift`, new `Actions.swift`)

`Actions.fire(_ command: Command)` runs on the main queue.

| Command | Implementation |
|---|---|
| `media` | the existing `SystemControls.press` |
| `toggleOutputMute` | the existing mute path, with the buzz |
| `toggleInputMute`, `inputVolume` | CoreAudio on `kAudioHardwarePropertyDefaultInputDevice` with `kAudioDevicePropertyScopeInput`. If the device has no settable volume, the level can't be set and the menu shows the binding as unavailable. If mute isn't supported either, the input volume is set to 0 and the previous value is restored. |
| `window` | `WindowManager` (see [Window snapping](#window-snapping)) |
| `keystroke`, the stepper commands | `CGEvent(keyboardEventSource:virtualKey:keyDown:)` with flags, posted to `.cghidEventTap`. This is covered by the Accessibility permission Margin already has. |
| `lockScreen` | the ⌃⌘Q keystroke |
| `screenshotRegion` | the ⇧⌘4 keystroke |
| `missionControl` | `NSWorkspace.open` on `/System/Applications/Mission Control.app` |
| `appWindows` | the ⌃↓ keystroke |
| `showDesktop` | the Show Desktop keystroke if one is set in Keyboard Shortcuts, otherwise ⌘F3. It ships only if this works on macOS 14–16 without the user setting anything up; otherwise it is dropped from v1, and users can bind a keystroke themselves. |
| `startScreenSaver` | `NSWorkspace.open` on `ScreenSaverEngine.app` |
| `sleepDisplay` | `/usr/bin/pmset displaysleepnow` |
| `timer*` | `TimerService` (see [Timer dial](#timer-dial)) |
| `launchApp` | `NSWorkspace.openApplication(at:configuration:)` |

Synthesized keystrokes go to the frontmost app. While a stepper runs, the cursor freeze keeps focus where it was.

## Window snapping

**Gesture.** Hold ⌥ and swipe in from an edge, using the rules above. Snapping is off by default. The zone editor has
a **Window Snapping** preset that binds all four inward swipes at once:

| Swipe in from | Default action |
|---|---|
| left edge | `leftHalf` |
| right edge | `rightHalf` |
| top edge | `maximize` |
| bottom edge | `restore` |

The rule is that the window goes to the side you swipe from, the same way dragging a window to the left of the screen
tiles it to the left. Each inward swipe can still be set separately, to `nextDisplay`, `center` or any other command.

**Which window.** The focused window of the frontmost app: `AXUIElementCreateSystemWide()` →
`kAXFocusedApplicationAttribute` → `kAXFocusedWindowAttribute`. The menu bar panel and Margin's own overlays are never
targets. Windows in full screen (`AXFullScreen == true`) are skipped, with a short "Full screen" message in the overlay.

**Frame calculations (`WindowManager`).**

- The target area is the `visibleFrame` of the screen the window mostly sits on, so it leaves out the menu bar and the
  Dock.
- `nextDisplay` moves the window to the next screen in `NSScreen.screens` order and keeps its relative frame.
- AX uses global coordinates with the origin at the top left of the primary screen. AppKit puts the origin at the
  bottom left. The conversion is `axY = primaryHeight − (y + height)`, and it lives in one place, `MarginCore`, where it
  is tested.
- Each window is set with position, then size, then position again. This settles windows that limit their own size or
  clamp their position.
- `restore`: before its first snap, a window's frame is saved in a small LRU list of 20 entries, matched with
  `CFEqual` on the AX element. `restore` puts that frame back. If nothing is saved, it does `center` (two thirds of the
  visible area).

**Feedback.** The overlay shows a small tile icon and a label, such as "Left half" or "Restored". If AX refuses, for
example because the app doesn't allow its window to be resized, the overlay shows "Can't resize this window" and a
light tick.

## Hot corners

All four corners can carry a double-tap command. The defaults leave only top-right bound (mute), as today. In the
editor, corners list the system commands first: Lock Screen, Screenshot, Mission Control, App Windows, Show Desktop,
Screen Saver, Sleep Display, Start Timer…, then Launch App… and Keystroke….

**Physical clicks in a corner.** A press on the trackpad is also a short touch that stays still, so two quick clicks in a
corner, such as a double-click on a file, would look like a double-tap. This matters most in the bottom corners, where
people click. To prevent it:

- `InputGate` already sees physical `leftMouseDown` and `rightMouseDown` events while a finger is down. It records the
  time of the last one: `lastPhysicalClick`.
- `finish()` ignores a tap if `lastPhysicalClick` falls inside the touch, from `startTime` to lift. A double-tap needs
  two clean taps in a row.
- This also fixes the same, rarer, problem with today's top-right mute corner.

**Right-click corners.** If the user has set a bottom corner as a right-click corner in System Settings (read
`TrackpadCornerSecondaryClick` from the `com.apple.AppleMultitouchTrackpad` and `com.apple.driver.AppleBluetoothMultitouch.trackpad`
defaults), the editor shows "This corner is your right-click corner" on that corner. It still allows a binding, because
taps and clicks are now told apart.

**Corner size.** `Tuning.cornerSize` stays at 0.15 of the trackpad in each direction. The bottom corners overlap the
bottom strip. A tap there goes to the corner if the corner is bound, and to the strip's tap otherwise, following the
fall-through rule.

## Timer dial

**Setting it.** An edge bound to `timer` works as a dial:

- **Scale.** 1-minute notches from 1 to 10 minutes, then 5-minute notches up to 90 minutes. That is 26 notches, close
  to the Default feel, so a full sweep feels like the volume edge.
- **Starting point.** If a timer is running, the dial starts at the time remaining, so sliding adjusts it. Otherwise it
  starts at the last duration used, which defaults to 25 minutes.
- **Overlay.** It shows "25 min" with a clock symbol. While the finger is down it adds "Lift to start", or
  "Lift to cancel" when the dial is at zero.
- **Lifting.** This starts the timer, or changes or cancels a running one, and gives a forced haptic tick.

**Commands.** `timerStart(minutes:)` starts a fixed-length timer from a tap, for example a corner set to a 25-minute
focus block. `timerPauseResume` and `timerCancel` work on the running timer.

**`TimerService`** (main thread, `@Observable`):

- States: `idle`, `running(endsAt)`, `paused(remaining)` and `ringing(since)`.
- Times come from the wall clock (`Date`), so sleep doesn't lose time. If the end time passes while the Mac is asleep,
  the timer rings on wake.
- `endsAt` or `remaining` is saved in `UserDefaults`, so the timer survives Margin quitting or the Mac restarting.
- The clock is injected, so the state machine can be tested in `MarginCore`.

**Menu bar.** While the timer runs, the status item switches from `squareLength` to `variableLength` and shows the time
remaining next to the icon, such as "24:12". It updates every second, or every minute when more than an hour is left.
The main page gets a timer row with the time left, a pause or resume button and a cancel button.

**Alarm.** The trackpad's haptic motor can only be felt while a finger is on the glass, so the haptic alarm works with
the visual one rather than replacing it.

1. When the timer ends, it moves to `ringing`. The overlay shows "Time's up · tap to dismiss" and stays until the timer
   is dismissed. The menu bar icon pulses.
2. While ringing, the engine repeats the chosen alarm pattern (below), but only while a finger rests on the
   trackpad. The pulses go to the device the timer was set on, or to the built-in trackpad. The engine knows whether a
   finger is down. `TimerService` tells it it's ringing through `TouchEngine.setAlarm(active:pattern:device:)`, which
   keeps the rule that the engine never reads shared state.
3. A single tap anywhere on the trackpad, or a click on the overlay or the timer row, dismisses the alarm. While
   ringing, that tap is swallowed the same way gesture taps are.
4. When the pattern's time limit runs out, the alarm stops by itself and leaves the menu bar showing "Timer done".

**Alarm intensity** is a user setting. Each pattern is plain data (`AlarmPattern`, in `MarginCore`), so it can be tuned
without touching the engine:

| Intensity | Pulse | Repeats every | Stops after |
|---|---|---|---|
| Gentle | one medium pulse | 4 s | 1 min |
| Normal (default) | three strong pulses, 120 ms apart | 4 s | 2 min |
| Insistent | five strong pulses, 100 ms apart | 2 s | 5 min |

**Settings → Timer:**

- **Alarm:** Gentle / Normal / Insistent, a segmented picker set to Normal by default. Next to it is a **Try** button.
  It plays the pattern for 6 seconds so there's time to rest a finger on the trackpad and feel it.
- **Play a sound** (off by default): an `NSSound` chime played once at the end.
- **Show a notification** (off by default): `UNUserNotificationCenter`, which asks for notification permission the
  first time it is turned on.
- **Run a Shortcut on start / end** (optional): pick from `shortcuts list` and run it with `shortcuts run <name>`. This
  is the way to turn a Focus mode on and off.

## Feedback

`LevelOverlay` becomes a general overlay with four content types:

- **level:** today's pill, with `mic.fill` / `mic.slash.fill` symbols for input volume.
- **stepper / dial:** symbol, label and a running count or value, such as "Undo ×3", "Tab →2" or "25 min". The count
  resets when the finger lifts.
- **command:** symbol and label, such as "Mic muted", "Left half" or "Mission Control", shown briefly. A setting,
  "Show feedback for taps and swipes", controls this and is on by default.
- **alarm:** "Time's up", which stays until dismissed. It is the only overlay that takes clicks.

Haptics: one tick per stepper or dial notch at the current strength, a forced tick when a flick, inward swipe or timer
start fires, the buzz when either mute toggles, and the alarm pattern.

## Menu UI (`MenuView.swift`)

- **Main page.** `TrackpadDiagram` becomes interactive. Each zone draws its action's symbol, and the zone under the
  pointer is highlighted on hover. Clicking a zone opens the zone editor. Edges with an inward swipe bound show a small
  inward arrow. The existing level meters stay on any edge bound to `level`. A timer row appears while a timer exists.
- **Zone editor.** A third page, using the same drill-in pattern as Settings, so there are no popovers inside the
  panel. It has:
  - a header with the zone's name and a back button;
  - a **Slide** picker (edges only), grouped as Levels, Dials, Flick and Timer;
  - a **Swipe in** picker (edges only), with Window first, then the other commands, captioned "Hold ⌥ and swipe in
    from this edge";
  - a **Double-tap** picker, grouped as Media, Sound, System, Timer, Apps and Keystroke. On the left and right edges,
    a binding shows the caption "May interfere with clicking near the sides";
  - for **Keystroke**, a recorder row: click it, press the keys, and it shows the shortcut (for example ⌘⇧K);
  - for **Launch App**, an app chooser (`NSOpenPanel` limited to `/Applications`);
  - for **Start Timer**, a minutes stepper.

  The editor also offers a **Window Snapping** preset button (any edge) and the right-click corner warning (bottom
  corners). When the editor is opened from inside a profile, each picker also has an "Use global" entry.
- **Settings → App Profiles.** A section listing profiles, each with its app icon, name and an on/off switch.
  - The **+** button lists running apps that have a normal activation policy.
  - Clicking a profile shows the diagram in profile mode: changed zones are tinted and the rest are faded.
  - **Reset Layout** in the Edges section restores the default layout.
- **Settings → Timer.** The sound, notification and Shortcut options above.
- **Status line.** When a profile is active, the main page shows "Using <App> profile" under the header, so a changed
  binding never comes as a surprise.

## Permissions

There are no new permissions for anything except the optional timer notification. Window snapping uses the same
Accessibility access that Margin already needs, and keystrokes are covered by it too. `shortcuts run` needs no
permission.

## Setup guide

The guide's steps come from the global layout: one step for each zone and gesture that has a binding, up to six, in the
order of the default layout. It listens for `.marginGestureCompleted` with a `(Zone, GestureKind)` payload. With the
default layout, the guide looks exactly the same as today.

## Testing

Add a `MarginCore` library target containing the model types and pure logic, so they can be tested without the app.
Then add `MarginTests`, covering:

- migration from every combination of the old booleans;
- profile merging, including disabled profiles and "Use global";
- `Codable` round-trips of every `Command` and `SlideAction` case;
- zone lookup at the edges and corners, with `edgeWidth` and `bottomQuarterOnly` applied;
- `classifyInwardSwipe` with recorded paths: real swipes with ⌥ held, the same swipes without ⌥ (they must never fire),
  ⌥ pressed partway through, slow drags, diagonal movement, and starts just outside the edge zone;
- `AlarmPattern`: each intensity's pulse timing, repeat interval and time limit;
- window frames: each `WindowAction` against several screen layouts, including a secondary screen above or to the left
  of the primary, a Dock on the side, and AX/AppKit coordinate conversion;
- the timer: the dial scale (notch ↔ minutes), and the state machine with an injected clock, covering start, pause,
  resume, adjusting while running, expiring during sleep, auto-stop and restoring after relaunch.

Engine behaviour (detents, flicks, double-tap timing, the alarm pattern) is checked by hand. A `--preview-timer` flag
runs a 10-second timer to try out the alarm.

## Phases

1. **Model and migration, with no change in behaviour.** Add the types, `MarginCore`, the tests, and an engine refactor
   that dispatches on bindings. Ship it only once the default layout behaves exactly like v1.2.
2. **New zones, hot corners and the simple actions.** Top edge, all four corners, the physical-click guard,
   right-click corner detection, `inputVolume` and `toggleInputMute`, the `undoRedo` and `tabs` steppers, the system
   commands and `keystroke`.
3. **Zone editor UI.** The interactive diagram, the editor page and the keystroke recorder.
4. **App profiles.** Tracking the frontmost app, merging, the Settings section and the status line.
5. **Timer dial.** `TimerService`, the dial slide action and the timer commands, the countdown in the menu bar, the
   alarm with its three intensities, and the timer settings.
6. **Window snapping.** The inward swipe phase and classifier, `WindowManager` and the preset. It comes last because it
   adds a new gesture phase to the engine, and the swipe thresholds need time with testers to tune.

Each phase can be released on its own. Phases 1 and 2 can ship before the editor, with the new actions available only
by editing defaults, as an internal test.

## Decisions

Settled on 2026-11-04.

| # | Question | Decision |
|---|---|---|
| 1 | Double-tap on the left and right edges? | Allowed. The editor warns "May interfere with clicking near the sides". |
| 2 | How to trigger Show Desktop? | Ship it only if the keystroke works on macOS 14–16 without setup. Otherwise drop it from v1. |
| 3 | Should profiles apply to the Magic Mouse? | No. Profiles apply to trackpads only. |
| 4 | How are profiles matched? | By bundle ID only. |
| 5 | Should window snapping need a modifier? | Yes, always. An inward swipe only counts while ⌥ is held. |
| 6 | Native tiling on macOS 15+, or AX? | AX on every version, for exact Restore and Next Display and the same behaviour on 14–16. |
| 7 | What alarm pattern? | User-adjustable: Gentle, Normal (default) or Insistent, with a Try button. |

## Open questions

None at the moment. The swipe thresholds and alarm timings are values to tune during phases 5 and 6, not open design
questions.
