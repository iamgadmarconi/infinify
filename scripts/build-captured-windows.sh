#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
mkdir -p target/captured-windows
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror \
  native/captured-windows/captured.m -framework AppKit -framework AVFoundation \
  -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo -framework QuartzCore \
  -o target/captured-windows/captured-windows
printf '%s\n' 'Built arm64 macOS 26+ live native-window capture probe; nothing launched.'
