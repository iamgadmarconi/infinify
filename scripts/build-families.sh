#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
mkdir -p target/native-families
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror \
  native/families/families.m -framework AppKit -framework ScreenCaptureKit \
  -framework CoreMedia -framework CoreVideo -framework CoreImage \
  -o target/native-families/native-families
printf '%s\n' 'Built arm64 macOS 26+ native-family gate; nothing launched.'
