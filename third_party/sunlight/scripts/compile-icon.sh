#!/bin/bash
# Compiles the Icon Composer icon, Resources/Sunlight.icon, with Xcode's actool:
#   scripts/compile-icon.sh <dir>   # writes <dir>/Assets.car and <dir>/Sunlight.icns
# Assets.car holds the Liquid Glass icon in every appearance (default, dark, clear and tinted) for macOS 26
# and later; Sunlight.icns is the default look as one picture, for macOS 15 and the copy kept in Resources/.
# actool's .icns stops at 256 px, so it's redone up to 1024 from Icon Composer's own render (its ictool).
# Needs Xcode 26 or later (the command-line tools have no actool); exits 2 without it, so callers can fall
# back to the checked-in Resources/Sunlight.icns.
set -euo pipefail
cd "$(dirname "$0")/.."
OUT=${1:?usage: scripts/compile-icon.sh <dir>}

if ! xcrun --find actool >/dev/null 2>&1; then
  echo "No actool (it comes with Xcode 26 or later), so the icon isn't compiled" >&2
  exit 2
fi
mkdir -p "$OUT"
OUT=$(cd "$OUT" && pwd)   # absolute: actool's daemon resolves relative paths against its own directory
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
xcrun actool Resources/Sunlight.icon --compile "$OUT" \
  --app-icon Sunlight --platform macosx --target-device mac --minimum-deployment-target 15.0 \
  --output-partial-info-plist "$TMP/Info.plist" --output-format human-readable-text \
  --errors --warnings --notices
test -s "$OUT/Assets.car" || { echo "actool wrote no $OUT/Assets.car" >&2; exit 1; }
test -s "$OUT/Sunlight.icns" || { echo "actool wrote no $OUT/Sunlight.icns" >&2; exit 1; }

ICTOOL="$(dirname "$(xcode-select -p)")/Applications/Icon Composer.app/Contents/Executables/ictool"
if [[ -x "$ICTOOL" ]]; then
  "$ICTOOL" Resources/Sunlight.icon --export-image --output-file "$TMP/render.png" --platform macOS \
    --rendition Default --width 1024 --height 1024 --scale 1
  swift scripts/make-icns.swift "$TMP/render.png" "$OUT/Sunlight.icns"
else
  echo "No Icon Composer in Xcode, so Sunlight.icns stays actool's (up to 256 px)" >&2
fi
