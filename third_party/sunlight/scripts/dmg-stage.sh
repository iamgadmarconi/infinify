#!/bin/bash
# Fills a folder with what goes on the DMG: the app, the Applications shortcut, the window's background
# (the 1x and 2x PNGs joined into one HiDPI TIFF) and the volume icon. scripts/package.sh turns the
# folder into the disk image and adds the window layout on the mounted volume.
#   scripts/dmg-stage.sh <folder>        # needs build/Sunlight.app (make app)
set -euo pipefail
cd "$(dirname "$0")/.."
STAGE=${1:?usage: scripts/dmg-stage.sh <folder>}
test -d build/Sunlight.app || { echo "No build/Sunlight.app; run make app first" >&2; exit 1; }

ditto build/Sunlight.app "$STAGE/Sunlight.app"
ln -s /Applications "$STAGE/Applications"
mkdir -p "$STAGE/.background"
tiffutil -cathidpicheck packaging/dmg/background.png packaging/dmg/background@2x.png \
  -out "$STAGE/.background/background.tiff"
cp Resources/Sunlight.icns "$STAGE/.VolumeIcon.icns"
