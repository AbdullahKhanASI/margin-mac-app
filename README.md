# Margin

> **Beta (v1.2.0-beta).** Margin works day to day, but expect rough edges. Please report problems in
> [Issues](https://github.com/AbdullahKhanASI/margin-mac-app/issues).

A menu bar app that turns the edges of a Mac trackpad into controls.

- **Right edge**: slide up or down for volume. **Left edge**: brightness. Swap Sides reverses them.
- **Top-right corner**: double-tap to mute.
- **Bottom edge**: swipe to skip tracks, double-tap to play or pause.
- Volume and brightness follow your finger continuously (no 1/16 steps), with a minimal overlay in the centre of the screen.
- Haptic notches as you slide, the pointer frozen while sliding, and slower, finer control with ⇧⌥ (or Precise Sliding).
- Bottom Quarter Only, Require fn or ⌥, Reverse Swipe, Light / Dark, Open at Login.
- Optional Magic Mouse support: slide on the mouse's top edges (scrolling is held off while you do).
- A setup guide on first launch that ticks off each gesture as you try it (Settings → Setup Guide… to reopen).

## Requirements

- macOS 14 (Sonoma) or later
- A built-in trackpad or Magic Trackpad (Magic Mouse optional)
- To build from source: Xcode 15.3+ or the Xcode Command Line Tools (Swift 5.10+)

## Installation

### Option A: one-line install (recommended)

Open **Terminal** and paste:

```bash
curl -fsSL https://raw.githubusercontent.com/AbdullahKhanASI/margin-mac-app/main/install.sh | bash
```

This downloads the newest release (betas included), installs it into `/Applications` (or `~/Applications` if you
aren't an admin), and opens it. Run the same command again to update. You can read the script first:
[`install.sh`](install.sh).

- Install a particular release: `curl -fsSL …/install.sh | bash -s -- --version v1.2.0-beta`
- If the repository is private and you've been invited to it, install the [GitHub CLI](https://cli.github.com)
  (`brew install gh`) and run `gh auth login` first. The script then downloads through it.

### Option B: download the zip

1. Download the `.zip` from the newest release on the
   [Releases page](https://github.com/AbdullahKhanASI/margin-mac-app/releases), unzip it, and open **Margin.app**.
2. The beta isn't notarized yet, so macOS blocks the first launch with a warning that it can't check the app.
   Click **Done** (not Move to Trash), then:
   - **macOS 15 (Sequoia) or later:** open **System Settings → Privacy & Security**, scroll to the
     "Margin was blocked" message and click **Open Anyway**, then confirm with your password.
   - **macOS 14 (Sonoma):** right-click Margin.app, choose **Open**, then **Open** again.
3. If Margin isn't in Applications yet, it offers to move itself there. Click **Move to Applications**.

If you're comfortable in Terminal, `xattr -dr com.apple.quarantine /path/to/Margin.app` skips step 2.

### Option C: build from source

```bash
git clone https://github.com/AbdullahKhanASI/margin-mac-app.git
cd margin-mac-app
./build.sh install    # builds, signs, copies to /Applications and launches
```

`./build.sh` on its own builds and signs `build/Margin.app` without installing it.

Signing uses `$MARGIN_SIGN_IDENTITY` if set, otherwise your first "Apple Development" identity, otherwise ad-hoc.
macOS ties the Accessibility grant to the signature, so ad-hoc builds need to be re-approved after every rebuild.
To use a specific identity:

```bash
MARGIN_SIGN_IDENTITY="Apple Development: Your Name (TEAMID)" ./build.sh install
```

### First launch: the setup guide

Margin needs Accessibility access to change volume and brightness and to hold the pointer still while you slide.
On first launch a setup guide walks you through it:

1. **Allow Accessibility access.** Click **Open Settings**, then turn on **Margin** in
   **System Settings → Privacy & Security → Accessibility**. The step ticks off by itself once access comes through.
2. **Try each gesture.** Slide the volume and brightness edges, double-tap the mute corner, and swipe the bottom
   edge. Each one ticks off as Margin recognises it.
3. **Open at login.** Click **Turn On** so Margin starts with your Mac.

Reopen the guide any time from Settings → Setup Guide….

**Margin is switched on in Accessibility but still doesn't work?** That's an old entry left behind by a previous
version. Margin spots this and shows a **Reset** button in the setup guide and the menu: click it, then switch
Margin on again when macOS asks. The install script does this for you when it updates Margin.

### Uninstall

```bash
curl -fsSL https://raw.githubusercontent.com/AbdullahKhanASI/margin-mac-app/main/install.sh | bash -s -- --uninstall
```

This quits Margin, deletes the app, and removes its Accessibility permission and settings. To do it by hand: quit
Margin, delete `Margin.app`, remove it from **System Settings → Privacy & Security → Accessibility**, and run
`defaults delete com.abdullahkhan.Margin`.

## Development

To cut a release, run `MARGIN_VERSION_SUFFIX=.0-beta ./build.sh release` (the version comes from
`Resources/Info.plist`) and attach the resulting `build/Margin-v….zip` to a GitHub release. `install.sh` picks up the
newest release automatically.

`Margin --preview-menu` opens the menu's contents in a regular window, and `Margin --preview-overlay` sweeps the overlay
up and down without changing the real levels. Both are handy when working on the UI. `Margin --preview-timer` starts a
10-second timer, to try the alarm.

The app icon artwork is `Resources/AppIcon-source.png`. `Scripts/make-icon.swift` cuts it out onto
transparency and writes `Resources/AppIcon.icns`; rerun it after changing the artwork.

## How it works

| Piece | File |
|---|---|
| Raw finger positions from `MultitouchSupport.framework` (private, loaded with `dlopen`) | `Sources/CMultitouch/CMultitouch.c` |
| Gesture recognition: edge zones, slides, swipes, double-taps, dropout recovery | `Sources/Margin/TouchEngine.swift` |
| Volume (CoreAudio) and brightness (DisplayServices) set directly; media keys for play / skip; haptics | `Sources/Margin/SystemControls.swift` |
| Centred level overlay | `Sources/Margin/LevelOverlay.swift` |
| Event tap that pins the pointer during a slide and swallows tap-to-click from gesture taps | `Sources/Margin/InputGate.swift` |
| Settings model | `Sources/Margin/Preferences.swift` |
| Menu bar UI | `Sources/Margin/MenuView.swift` |
| App lifecycle: device start, wake / reconnect, permission polling | `Sources/Margin/MarginApp.swift` |

Because it uses private APIs and needs Accessibility access, Margin can't be sandboxed or sold on the Mac App Store.
It can be distributed directly as a Developer ID–signed, notarized app.

## License

Copyright (C) 2026 Abdullah Khan

Margin is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 3 of the License, or (at your option) any later version. See [LICENSE](LICENSE) for the full text.
