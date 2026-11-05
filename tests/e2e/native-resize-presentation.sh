#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Deterministic production owner/coordinator with injected native boundaries.
set -eu
cd "$(dirname "$0")/../.."
mkdir -p target/resize
. scripts/native-includes.sh
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror $native_includes \
  native/app/CompositorMode/DWNativeResizePresentation.m native/app/CompositorMode/DWNativeTransition.m \
  native/app/Navigation/DWResizeCoordinator.m tests/native/app/CompositorMode/DWNativeResizePresentationTests.m \
  -framework AppKit -framework CoreGraphics -framework ScreenCaptureKit -framework QuartzCore -framework CoreVideo \
  -o target/resize/native-presentation-regression
./target/resize/native-presentation-regression
