#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
cd "$(dirname "$0")/.."
out=${1:-target/native-performance}
mkdir -p "$out"
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -O2 -fobjc-arc -Wall -Wextra -Werror \
  native/performance/marker_fixture.m -framework AppKit -o "$out/marker-fixture"
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -O2 -fobjc-arc -Wall -Wextra -Werror \
  native/performance/display_observer.m -framework Foundation -framework ScreenCaptureKit \
  -framework CoreGraphics -framework CoreMedia -framework CoreVideo -o "$out/display-observer"
printf 'Built fixture and read-only display observer in %s; nothing launched.\n' "$out"
