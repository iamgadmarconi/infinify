#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
mkdir -p target/surfaces
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror \
  native/surfaces/surfaces.m -framework AppKit -framework QuartzCore \
  -framework ScreenCaptureKit -o target/surfaces/surfaces
printf '%s\n' 'Built arm64 macOS 26+ cooperative surface probe; nothing launched.'
