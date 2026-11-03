#!/usr/bin/env bash
# Fast edit → run loop: builds for this Mac only (no universal binary, no zip), updates
# build/AI Usage.app in place, quits any running AI Usage (wherever it was launched from) and relaunches.
#
#   Scripts/dev_rebuild_and_relaunch.sh                    # debug build (fastest incremental)
#   CONFIG=release Scripts/dev_rebuild_and_relaunch.sh     # optimized
#   SIGN_IDENTITY="…" Scripts/dev_rebuild_and_relaunch.sh  # sign with another identity instead
#
# Signing: your Apple Development certificate when there is one (free with any Apple ID; Xcode → Settings →
# Accounts → Manage Certificates). It carries a Team ID, which is what lets Keychain's "Always Allow" survive
# rebuilds. Without one, it falls back to the self-signed certificate in .dev-signing/ (git-ignored; created on
# first run, recreate it with Scripts/dev_cert.sh): the build runs, but Keychain asks again after every rebuild,
# because for code without a Team ID it remembers each build's hash (cdhash), not the certificate.
#
# Toolchain: Xcode's, with the swiftbuild engine (requires /Applications/Xcode.app). Measured on an arm64 Mac
# (Nov 2026), app rebuild after a code change in one app file:
#   Xcode toolchain,     --build-system swiftbuild                    ~1.3 s   ← used here
#   Xcode toolchain,     --build-system native (deprecated)           ~0.9 s
#   Command Line Tools,  --build-system native (deprecated)           ~0.9 s
#   Command Line Tools,  --build-system swiftbuild (Swift 6.4 default) ~18 s, sometimes a full ~32 s
# The Command Line Tools ship no prebuilt SDK modules, so swiftbuild's explicit-module build re-scans and
# re-validates ~45 SDK modules (Swift, Foundation, AppKit, SwiftUI…) on every build. Xcode ships them.
# Switching toolchains invalidates the build cache, so the first build after a switch is a full one.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-debug}"
APP="build/AI Usage.app"
XCODE_DEVELOPER_DIR="/Applications/Xcode.app/Contents/Developer"
if [[ ! -d "$XCODE_DEVELOPER_DIR" ]]; then
  echo "error: Xcode not found at $XCODE_DEVELOPER_DIR (needed for fast rebuilds; see the header of $0)" >&2
  exit 1
fi
export DEVELOPER_DIR="$XCODE_DEVELOPER_DIR"
BUILD=(swift build --build-system swiftbuild -c "$CONFIG")

"${BUILD[@]}" --product AIUsage
BIN="$("${BUILD[@]}" --show-bin-path)/AIUsage"

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
if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  # SHA-1 of the first valid Apple Development identity (by hash, so several of them aren't ambiguous).
  SIGN_IDENTITY="$(security find-identity -v -p codesigning | awk '/"Apple Development: / && !h { h = $2 } END { print h }')"
fi
if [[ -n "$SIGN_IDENTITY" ]]; then
  codesign --force --sign "$SIGN_IDENTITY" "$APP"
else
  echo "note: no Apple Development certificate found; signing with the self-signed one, so Keychain will" >&2
  echo "      ask for access again after every rebuild (see docs/DEVELOPMENT.md)" >&2
  KEYCHAIN="$PWD/.dev-signing/dev.keychain-db"
  # Create the certificate on first run, and again if the existing one is missing or no longer valid.
  if [[ ! -f .dev-signing/identity ]] || ! security find-identity -v -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$(cat .dev-signing/identity)"; then
    Scripts/dev_cert.sh
  fi
  security unlock-keychain -p "$(cat .dev-signing/keychain-password)" "$KEYCHAIN"
  # codesign looks for identities in the user's keychain search list: add the dev keychain while signing.
  SEARCH_LIST=()
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"; line="${line#\"}"; line="${line%\"}"
    [[ -n "$line" ]] && SEARCH_LIST+=("$line")
  done < <(security list-keychains -d user)
  restore_keychains() { security list-keychains -d user -s ${SEARCH_LIST[@]+"${SEARCH_LIST[@]}"}; }
  trap restore_keychains EXIT
  security list-keychains -d user -s "$KEYCHAIN" ${SEARCH_LIST[@]+"${SEARCH_LIST[@]}"}
  codesign --force --keychain "$KEYCHAIN" --sign "$(cat .dev-signing/identity)" "$APP"
fi
open "$APP"
echo "✓ relaunched $APP ($CONFIG)"
