#!/usr/bin/env bash
# Build a release binary and wrap it in a proper Notchboard.app bundle.
set -euo pipefail

cd "$(dirname "$0")/.."

swift build -c release

APP="Notchboard.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp ".build/release/Notchboard" "$APP/Contents/MacOS/Notchboard"
cp "scripts/Info.plist" "$APP/Contents/Info.plist"

# Bundled images: logos (.png) and tab icons (.svg).
if compgen -G "Resources/*.png" > /dev/null; then
  cp Resources/*.png "$APP/Contents/Resources/"
fi
if compgen -G "Resources/*.svg" > /dev/null; then
  cp Resources/*.svg "$APP/Contents/Resources/"
fi

# Ad-hoc code signature so launchd / Gatekeeper are happy locally.
codesign --force --sign - "$APP" >/dev/null 2>&1 || true

# Register the bundle's exported UTType (used for internal drag reordering).
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$APP" >/dev/null 2>&1 || true

echo "Built $APP — launch with: open $APP"
