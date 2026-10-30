#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Production CPU lifetime fence only; no renderer, GPU or native window is used.
set -eu
cd "$(dirname "$0")/../.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/infinify-compositor-lifetime.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT HUP INT TERM
. scripts/native-includes.sh
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -O2 -fno-objc-arc -Wall -Wextra -Werror $native_includes \
  -c tests/native/app/Canvas/IFCompositorRendererTests.m -o "$task_dir/lifetime.o"
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -O2 -fobjc-arc -Wall -Wextra -Werror $native_includes \
  native/app/Canvas/IFCDeviceResources.m native/app/Canvas/IFCompositorFrame.m native/app/Canvas/DWCompositorRasterizers.m native/app/Canvas/IFCompositorRenderer.m native/app/Canvas/IFCompositorRenderer+Draw.m native/app/Canvas/IFCompositorRenderer+Blur.m native/app/Canvas/IFCompositorLayer.m native/app/Canvas/IFBackgroundProgram.m native/app/Canvas/IFBGDeviceResources.m native/app/Canvas/DWBackgroundGLSLTranslation.m native/app/Canvas/IFBGShaderDecl.m native/app/Canvas/DWBackgroundFiles.m native/app/Canvas/IFBGChunk.m native/app/Canvas/IFBGShaderChunks.m native/app/Canvas/IFBGTileChunks.m native/app/Canvas/IFBGTiffSource.m "$task_dir/lifetime.o" \
  -framework AppKit -framework Metal -framework QuartzCore -framework CoreVideo \
  -framework CoreGraphics -framework CoreText -framework IOSurface -framework ImageIO -framework Accelerate \
  -o "$task_dir/compositor-lifetime"
"$task_dir/compositor-lifetime"
