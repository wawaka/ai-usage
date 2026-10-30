#!/usr/bin/env bash
# Fast edit → run loop: builds for this Mac only (no universal binary, no zip), updates
# build/AI Usage.app in place, quits any running AI Usage (wherever it was launched from) and relaunches.
#
#   Scripts/dev.sh                     # debug build (fastest incremental)
#   CONFIG=release Scripts/dev.sh      # optimized
#   SIGN_IDENTITY="AI Usage Dev" Scripts/dev.sh   # stable signature → fewer Keychain prompts
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-debug}"
APP="build/AI Usage.app"

swift build -c "$CONFIG" --product AIUsage
BIN="$(swift build -c "$CONFIG" --show-bin-path)/AIUsage"

mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
sed -e "s/__VERSION__/$(cat VERSION)-dev/" -e "s/__BUILD__/1/" Packaging/Info.plist > "$APP/Contents/Info.plist"
if [[ ! -f "$APP/Contents/Resources/AppIcon.icns" ]]; then
  swift Scripts/make_icon.swift build/AppIcon.iconset
  iconutil -c icns build/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
fi

# Quit the running copy (e.g. the one from an unpacked zip) before replacing the binary.
if pgrep -x AIUsage >/dev/null; then
  pkill -x AIUsage || true
  for _ in $(seq 50); do pgrep -x AIUsage >/dev/null || break; sleep 0.1; done
fi

cp "$BIN" "$APP/Contents/MacOS/AIUsage"
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP" 2>/dev/null
open "$APP"
echo "✓ relaunched $APP ($CONFIG)"
