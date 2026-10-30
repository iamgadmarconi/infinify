#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Crafted TIFF files (malformed, truncated, huge, zero-sized, multi-page, CMYK, 16-bit, compressed) through the real tile source and the
# real background program, then a fixed-seed mutation run: every one is a picture or an error and a dot grid, never a crash or a hang.
# The files are written to a directory of this run's own. No window, tap, event or native call; the program checks use a Metal device.
set -eu
cd "$(dirname "$0")/../.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/infinify-background-tiff.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT HUP INT TERM
native_includes='-Icrates/desktop/include -Inative/app -Inative/app/Desktop -Inative/app/Canvas -Inative/app/Windows -Inative/app/Input -Inative/app/CompositorMode -Inative/app/Navigation -Inative/app/System -Inative/app/Support -Inative/dock-helper/Client -Inative/dock-helper/Daemon -Inative/dock-helper/Loader -Inative/dock-helper/Payload'
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -O1 -fobjc-arc -Wall -Wextra -Werror $native_includes \
  tests/native/app/Canvas/IFBGTiffSourceTests.m native/app/Canvas/IFBackgroundProgram.m native/app/Canvas/IFBGDeviceResources.m native/app/Canvas/DWBackgroundGLSLTranslation.m native/app/Canvas/DWBackgroundFiles.m native/app/Canvas/IFBGChunk.m native/app/Canvas/IFBGShaderChunks.m native/app/Canvas/IFBGTileChunks.m native/app/Canvas/IFBGTiffSource.m \
  -framework AppKit -framework Metal -framework QuartzCore -framework CoreGraphics -framework CoreText -framework IOSurface \
  -framework ImageIO -framework Accelerate -lz -o "$task_dir/background-tiff"
"$task_dir/background-tiff"
