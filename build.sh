#!/usr/bin/env bash
# Builds Margin.app into ./build.
#   ./build.sh           build and sign
#   ./build.sh install   also copy to /Applications and launch it
#   ./build.sh release   also zip it as build/Margin-v<version><$MARGIN_VERSION_SUFFIX>.zip (CI does this on a tag)
#
# Signing uses $MARGIN_SIGN_IDENTITY, else the first "Apple Development" identity, else ad-hoc.
# A stable identity matters: macOS ties the Accessibility grant to the signature, so ad-hoc
# builds have to be re-approved after every rebuild.
set -euo pipefail
cd "$(dirname "$0")"

APP=build/Margin.app

swift build -c release
BIN="$(swift build -c release --show-bin-path)/Margin"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Margin"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

IDENTITY="${MARGIN_SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Apple Development[^"]*\)".*/\1/p' | head -1)"
fi
SIGN_FLAGS=(--force --options runtime)
# Notarization needs a secure timestamp, which only a Developer ID signature gets.
[[ "$IDENTITY" == "Developer ID Application"* ]] && SIGN_FLAGS+=(--timestamp)
codesign "${SIGN_FLAGS[@]}" --sign "${IDENTITY:--}" "$APP"
echo "Signed with: ${IDENTITY:-ad-hoc}"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
    pkill -x Margin 2>/dev/null || true
    rm -rf /Applications/Margin.app
    cp -R "$APP" /Applications/
    open /Applications/Margin.app
    echo "Installed and launched /Applications/Margin.app"
fi

if [[ "${1:-}" == "release" ]]; then
    VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' Resources/Info.plist)"
    ZIP="build/Margin-v${VERSION}${MARGIN_VERSION_SUFFIX:-}.zip"
    rm -f "$ZIP"
    ditto -c -k --keepParent "$APP" "$ZIP"
    echo "Zipped $ZIP"
fi
