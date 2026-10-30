#!/usr/bin/env bash
# Builds AI Usage.app (universal) and zips it into dist/.
#
#   Scripts/package_app.sh                 # ad-hoc signed
#   SIGN_IDENTITY="Developer ID Application: …" NOTARY_PROFILE=<notarytool keychain profile> Scripts/package_app.sh
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="$(cat VERSION)"
BUILD="${BUILD_NUMBER:-$(git rev-list --count HEAD 2>/dev/null || echo 1)}"
ARCHS="${ARCHS:-arm64 x86_64}"
APP="build/AI Usage.app"
ZIP="dist/AIUsage-${VERSION}.zip"

arch_flags=()
for a in $ARCHS; do arch_flags+=(--arch "$a"); done

echo "▸ Building AIUsage ${VERSION} (${ARCHS})"
swift build -c release "${arch_flags[@]}" --product AIUsage
swift build -c release "${arch_flags[@]}" --product ai-usage-cli
BIN_DIR="$(swift build -c release "${arch_flags[@]}" --show-bin-path)"

echo "▸ Assembling ${APP}"
rm -rf "$APP" && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Helpers"
cp "$BIN_DIR/AIUsage" "$APP/Contents/MacOS/AIUsage"
cp "$BIN_DIR/ai-usage-cli" "$APP/Contents/Helpers/ai-usage-cli"
sed -e "s/__VERSION__/${VERSION}/" -e "s/__BUILD__/${BUILD}/" Packaging/Info.plist > "$APP/Contents/Info.plist"

ICONSET="build/AppIcon.iconset"
rm -rf "$ICONSET"
swift Scripts/make_icon.swift "$ICONSET"
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"

echo "▸ Signing"
if [[ -n "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP/Contents/Helpers/ai-usage-cli"
  codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$APP"
else
  codesign --force --sign - "$APP/Contents/Helpers/ai-usage-cli"
  codesign --force --sign - "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

mkdir -p dist
rm -f "$ZIP"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

if [[ -n "${NOTARY_PROFILE:-}" && -n "${SIGN_IDENTITY:-}" ]]; then
  echo "▸ Notarizing"
  xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
fi

echo "✓ ${ZIP}"
