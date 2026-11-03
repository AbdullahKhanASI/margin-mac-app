# Margin

> **Beta (v1.1.0-beta).** Margin works day to day, but expect rough edges. Please report problems in
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

### Option A: download the beta

1. Download `Margin-v1.1.0-beta.zip` from the
   [Releases page](https://github.com/AbdullahKhanASI/margin-mac-app/releases).
2. Unzip it and drag **Margin.app** into `/Applications`.
3. The beta isn't notarized yet, so macOS will block the first launch. Either right-click Margin.app → **Open** →
   **Open**, or clear the quarantine flag in Terminal:

   ```bash
   xattr -dr com.apple.quarantine /Applications/Margin.app
   ```

4. Launch Margin. It lives in the menu bar (there's no Dock icon).

### Option B: build from source

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

### First launch: grant Accessibility access

Margin needs Accessibility access to change volume and brightness and to hold the pointer still while you slide.

1. On first launch the setup guide opens. Click **Open Settings**.
2. In **System Settings → Privacy & Security → Accessibility**, turn on **Margin**.
3. Go back to the setup guide and try each gesture; each one ticks off as it's recognised.

If gestures stop working after you rebuild or update, remove Margin from the Accessibility list (the **–** button),
then add it again.

### Uninstall

Quit Margin from its menu, delete `/Applications/Margin.app`, and remove it from
**System Settings → Privacy & Security → Accessibility**. To also clear its settings:

```bash
defaults delete com.abdullahkhan.Margin
```

## Development

`Margin --preview-menu` opens the menu's contents in a regular window, and `Margin --preview-overlay` sweeps the overlay
up and down without changing the real levels. Both are handy when working on the UI.

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
