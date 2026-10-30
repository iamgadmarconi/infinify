#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Production CPU lifetime fence only; no renderer, GPU or native window is used.
set -eu
cd "$(dirname "$0")/../.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/infinify-compositor-lifetime.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT HUP INT TERM
native_includes='-Icrates/desktop/include -Inative/app -Inative/app/Desktop -Inative/app/Canvas -Inative/app/Windows -Inative/app/Input -Inative/app/CompositorMode -Inative/app/Navigation -Inative/app/System -Inative/app/Support -Inative/dock-helper/Client -Inative/dock-helper/Daemon -Inative/dock-helper/Loader -Inative/dock-helper/Payload'
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -O2 -fno-objc-arc -Wall -Wextra -Werror $native_includes \
  -c tests/native/app/Canvas/IFCompositorRendererTests.m -o "$task_dir/lifetime.o"
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -O2 -fobjc-arc -Wall -Wextra -Werror $native_includes \
  native/app/Canvas/IFCompositorRenderer.m native/app/Canvas/IFBackgroundProgram.m native/app/Canvas/IFBGTiffSource.m "$task_dir/lifetime.o" \
  -framework AppKit -framework Metal -framework QuartzCore -framework CoreVideo \
  -framework CoreGraphics -framework CoreText -framework IOSurface -framework ImageIO -framework Accelerate \
  -o "$task_dir/compositor-lifetime"
"$task_dir/compositor-lifetime"
