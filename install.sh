#!/usr/bin/env bash
# Installs (or updates) Margin from GitHub Releases.
#
#   curl -fsSL https://raw.githubusercontent.com/AbdullahKhanASI/margin-mac-app/main/install.sh | bash
#
# Options (pass after `bash -s --` when piping, e.g. `| bash -s -- --uninstall`):
#   --version <tag>   install a specific release instead of the newest one (betas included)
#   --uninstall       remove Margin, its settings and its Accessibility entry
#
# Files downloaded with curl aren't quarantined, so macOS doesn't block this un-notarized build
# the way it blocks a browser download. If the repository is private, the script falls back to
# the GitHub CLI (`gh`), which works for anyone who has been invited to the repo.
set -euo pipefail

REPO="AbdullahKhanASI/margin-mac-app"
APP_NAME="Margin.app"
BUNDLE_ID="com.abdullahkhan.Margin"
VERSION=""
UNINSTALL=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --version) VERSION="${2:?--version needs a tag, e.g. v1.1.0-beta}"; shift 2 ;;
        --uninstall) UNINSTALL=1; shift ;;
        -h|--help) echo "Usage: install.sh [--version <tag>] [--uninstall]"; exit 0 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
fail() { printf '\033[31mError:\033[0m %s\n' "$*" >&2; exit 1; }

[[ "$(uname -s)" == "Darwin" ]] || fail "Margin only runs on macOS."
MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
(( MACOS_MAJOR >= 14 )) || fail "Margin needs macOS 14 or later (this Mac has $(sw_vers -productVersion))."

# Where an existing copy lives, if any.
existing_app() {
    for dir in /Applications "$HOME/Applications"; do
        [[ -d "$dir/$APP_NAME" ]] && { echo "$dir/$APP_NAME"; return; }
    done
}

quit_margin() {
    if pgrep -x Margin >/dev/null 2>&1; then
        info "Quitting the running copy of Margin…"
        osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
        for _ in {1..25}; do pgrep -x Margin >/dev/null 2>&1 || break; sleep 0.2; done
        pkill -x Margin 2>/dev/null || true
    fi
}

if (( UNINSTALL )); then
    bold "Uninstalling Margin"
    quit_margin
    APP="$(existing_app || true)"
    if [[ -n "$APP" ]]; then rm -rf "$APP" && info "Removed $APP"; else info "Margin.app wasn't found."; fi
    tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 && info "Removed its Accessibility permission." || true
    defaults delete "$BUNDLE_ID" >/dev/null 2>&1 && info "Removed its settings." || true
    bold "Done."
    exit 0
fi

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

bold "Downloading Margin${VERSION:+ $VERSION}"
ZIP=""
if [[ -n "$VERSION" ]]; then
    API="https://api.github.com/repos/$REPO/releases/tags/$VERSION"
else
    API="https://api.github.com/repos/$REPO/releases?per_page=1"
fi
if RELEASE_JSON="$(curl -fsSL -H 'Accept: application/vnd.github+json' "$API" 2>/dev/null)"; then
    URL="$(printf '%s' "$RELEASE_JSON" \
        | grep -o '"browser_download_url": *"[^"]*\.zip"' | head -1 | sed 's/.*"\(https[^"]*\)"/\1/')"
    [[ -n "$URL" ]] || fail "That release has no .zip download attached."
    info "$URL"
    ZIP="$TMP/Margin.zip"
    curl -fL --progress-bar -o "$ZIP" "$URL"
elif command -v gh >/dev/null 2>&1 && gh auth status >/dev/null 2>&1; then
    info "Repository isn't public; downloading with the GitHub CLI…"
    # `gh release download` without a tag skips pre-releases, so look up the newest tag first.
    [[ -n "$VERSION" ]] || VERSION="$(gh release list --repo "$REPO" --limit 1 --json tagName -q '.[0].tagName')"
    gh release download "$VERSION" --repo "$REPO" --pattern '*.zip' --dir "$TMP" \
        || fail "Couldn't download the release. Have you accepted the invitation to $REPO?"
    ZIP="$(ls "$TMP"/*.zip | head -1)"
else
    fail "Couldn't reach $REPO. If it's private, install the GitHub CLI (brew install gh), run \`gh auth login\`, and try again."
fi

ditto -x -k "$ZIP" "$TMP/unzipped"
NEW_APP="$(find "$TMP/unzipped" -maxdepth 2 -name "$APP_NAME" -type d | head -1)"
[[ -n "$NEW_APP" ]] || fail "The download didn't contain $APP_NAME."

# Install into /Applications, or ~/Applications when /Applications isn't writable (non-admin users).
DEST_DIR="/Applications"
if [[ ! -w "$DEST_DIR" ]]; then
    DEST_DIR="$HOME/Applications"
    mkdir -p "$DEST_DIR"
fi
DEST="$DEST_DIR/$APP_NAME"

bold "Installing to $DEST"
OLD_APP="$(existing_app || true)"
OLD_REQ=""
[[ -n "$OLD_APP" ]] && OLD_REQ="$(codesign -d -r- "$OLD_APP" 2>/dev/null | grep designated || true)"
NEW_REQ="$(codesign -d -r- "$NEW_APP" 2>/dev/null | grep designated || true)"

quit_margin
[[ -n "$OLD_APP" ]] && rm -rf "$OLD_APP"
ditto "$NEW_APP" "$DEST"
xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true

# A build with a different signature leaves an Accessibility entry that's switched on but no
# longer honoured. Clearing it means the app asks once, cleanly, instead of silently failing.
if [[ -n "$OLD_APP" && "$OLD_REQ" != "$NEW_REQ" ]]; then
    tccutil reset Accessibility "$BUNDLE_ID" >/dev/null 2>&1 || true
    info "The signature changed, so Margin will ask for Accessibility access again."
fi

open "$DEST"
bold "Margin is installed and running. Look for it in the menu bar."
info "Follow the setup guide to allow Accessibility access and try each gesture."
