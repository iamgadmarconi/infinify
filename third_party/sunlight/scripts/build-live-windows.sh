#!/bin/bash
# Builds Sunlight's live-window pieces into build/live-windows/:
#   payload              the Dock add-on (arm64e, as the Dock is), from LiveWindows/osax/payload.m
#   loader               injects the add-on into the Dock (arm64e, to share the Dock's library addresses)
#   SunlightLiveWindows  the helper the app runs as root; carries both in its __TEXT segment
# scripts/package.sh copies the helper into Sunlight.app/Contents/Helpers.
set -euo pipefail
cd "$(dirname "$0")/.."

OUT=build/live-windows
SRC=LiveWindows
WARN="-Wall -Wextra -Wno-unused-parameter"
mkdir -p "$OUT"

xcrun clang "$SRC/osax/payload.m" $WARN -shared -fPIC -fobjc-arc -O2 -mmacosx-version-min=15.0 -arch arm64e -o "$OUT/payload" \
    -F/System/Library/PrivateFrameworks -framework SkyLight -framework Foundation -framework CoreGraphics
xcrun clang "$SRC/osax/loader.m" -O3 -mmacosx-version-min=15.0 -arch arm64e -o "$OUT/loader" -framework Cocoa
xcrun clang "$SRC/helper.m" $WARN -std=c11 -fobjc-arc -O2 -mmacosx-version-min=15.0 -arch arm64 \
    -o "$OUT/SunlightLiveWindows" -framework Cocoa -framework Security \
    -Wl,-sectcreate,__TEXT,__payload,"$OUT/payload" -Wl,-sectcreate,__TEXT,__loader,"$OUT/loader"
echo "Built $OUT/SunlightLiveWindows"
