#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Production CPU lifetime fence only; no renderer, GPU or native window is used.
set -eu
cd "$(dirname "$0")/../.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/infinify-compositor-lifetime.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT HUP INT TERM
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -O2 -fno-objc-arc -Wall -Wextra -Werror \
  -c native/desktop/compositor-lifetime-regression.m -o "$task_dir/lifetime.o"
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -O2 -fobjc-arc -Wall -Wextra -Werror \
  native/desktop/compositor.m native/desktop/background.m native/desktop/background-tiff.m "$task_dir/lifetime.o" \
  -framework AppKit -framework Metal -framework QuartzCore -framework CoreVideo \
  -framework CoreGraphics -framework CoreText -framework IOSurface -framework ImageIO -framework Accelerate \
  -o "$task_dir/compositor-lifetime"
"$task_dir/compositor-lifetime"
