#!/usr/bin/env bash
# Builds Margin.app into ./build.
#   ./build.sh           build and sign
#   ./build.sh install   also copy to /Applications and launch it
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
codesign --force --options runtime --sign "${IDENTITY:--}" "$APP"
echo "Signed with: ${IDENTITY:-ad-hoc}"
echo "Built $APP"

if [[ "${1:-}" == "install" ]]; then
    pkill -x Margin 2>/dev/null || true
    rm -rf /Applications/Margin.app
    cp -R "$APP" /Applications/
    open /Applications/Margin.app
    echo "Installed and launched /Applications/Margin.app"
fi
