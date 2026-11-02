#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Stale capture frames after a native resize, live, in a disposable guest (capture overlay, no helper). A scoped windowed
# run captures the stale-frame fixture: a checkerboard with 40x40 point red and blue markers at its top-left and
# bottom-right corners. A read-only recorder captures Infinify's own canvas panel at 60 frames a second while the fixture
# grows from 400x300 to 600x450 and later shrinks back. Before each resize the live stream is interrupted through the scoped
# DebugCapture request, so the retained picture outlives the resize by the recovery delay. Checked in every recorded
# frame: neither marker is scaled (still 40 px at zoom 1), and a stale picture is drawn at its own size from the tile's
# top-left (cut off, not squeezed, after shrinking) where the new capture later puts it. Infinify's `msg screenshot` is not
# used: it takes fresh full-resolution snapshots, so it cannot show the retained picture. Exit 3 when no stale frame was
# recorded. See tests/e2e/live-guest-lib.sh for GUEST_SSH, GUEST_INFINIFY and the exit status.
set -eu
cd "$(dirname "$0")/../.."
. tests/e2e/live-guest-lib.sh
live_guest_begin capture-stale-frame 'stale capture frames: a self-resizing fixture under the capture overlay' "$@"
live_guest_build stale-frame -fobjc-arc tests/native/app/Desktop/StaleFrameFixture.m -framework AppKit
live_guest_build canvas-recorder -fobjc-arc tests/native/app/Desktop/CanvasRecorderFixture.m \
  -framework AppKit -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo -framework ImageIO -framework UniformTypeIdentifiers
live_guest_push "$evidence/bin/stale-frame" "$evidence/bin/canvas-recorder" tests/e2e/stability-guest-driver.py
if live_guest_drive stale-frame; then status=0; else status=$?; fi
echo "Result $status; evidence in $evidence"; exit "$status"
