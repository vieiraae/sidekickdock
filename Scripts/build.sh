#!/bin/bash
# Builds SidekickDock and assembles a runnable .app bundle in ./build.
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$PWD"
CONFIG="${1:-release}"
APP="$ROOT/build/SidekickDock.app"

echo "==> Compiling ($CONFIG)"
swift build -c "$CONFIG"
BIN="$(swift build -c "$CONFIG" --show-bin-path)/SidekickDock"

echo "==> Assembling bundle"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/SidekickDock"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

if [ -f "$ROOT/Resources/AppIcon.icns" ]; then
  cp "$ROOT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"
  /usr/libexec/PlistBuddy -c "Add :CFBundleIconFile string AppIcon" "$APP/Contents/Info.plist" 2>/dev/null || true
fi

# Release builds override these: a Developer ID identity and a real secure timestamp are
# both required for notarisation. See Scripts/release.sh.
IDENTITY="${SIGN_IDENTITY:-SidekickDock Self-Signed}"
TIMESTAMP="${SIGN_TIMESTAMP:---timestamp=none}"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY"; then
  echo "==> Signing with '$IDENTITY'"
  codesign --force --sign "$IDENTITY" \
    --identifier com.sidekickdock.app \
    --options runtime \
    "$TIMESTAMP" "$APP"
else
  echo "==> Signing ad-hoc — macOS will re-ask for permissions after every rebuild."
  echo "    Run ./Scripts/create-signing-identity.sh once to avoid that."
  codesign --force --sign - --identifier com.sidekickdock.app "$APP"
fi

echo "==> Built $APP"
