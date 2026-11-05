#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Deterministic production owner/coordinator with injected native boundaries.
set -eu
cd "$(dirname "$0")/../.."
mkdir -p target/resize
. scripts/native-includes.sh
# Compile the actual thin adapter selector, not a reimplementation.
python3 - <<'PY'
from pathlib import Path
source=Path("native/app/Desktop/Desktop+Navigation.m").read_text()
start=source.index("static CGRect DWResizePresentationNativeBounds(")
end=source.index("\n}\n", start)+3
Path("target/resize/DWResizePresentationNativeBounds.inc").write_text(source[start:end])
PY
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror $native_includes -Itarget/resize \
  native/app/CompositorMode/DWNativeResizePresentation.m native/app/CompositorMode/DWNativeTransition.m \
  native/app/Navigation/DWResizeCoordinator.m tests/native/app/CompositorMode/DWNativeResizePresentationTests.m \
  -framework AppKit -framework CoreGraphics -framework ScreenCaptureKit -framework QuartzCore -framework CoreVideo \
  -o target/resize/native-presentation-regression
./target/resize/native-presentation-regression
