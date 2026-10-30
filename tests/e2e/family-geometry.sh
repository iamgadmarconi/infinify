#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Production renderer queries only; no Metal device/window/capture/input.
set -eu
cd "$(dirname "$0")/../.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/infinify-family-geometry.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT HUP INT TERM
python3 - "$task_dir" <<'PY'
from pathlib import Path
import sys
source = Path("native/app/Canvas/DWCanvasRenderer.m").read_text()
methods = []
for marker in ("- (BOOL)hasGeometryTransitions {", "- (BOOL)hasFamilyGeometryTransitions {"):
    if source.count(marker) != 1:
        raise SystemExit(f"Expected one production query: {marker}")
    start = source.index(marker)
    end = source.index("\n- (", start + len(marker))
    methods.append(source[start:end])
(Path(sys.argv[1]) / "family-geometry-queries.inc").write_text("\n".join(methods) + "\n")
PY
native_includes='-Icrates/desktop/include -Inative/app -Inative/app/Desktop -Inative/app/Canvas -Inative/app/Windows -Inative/app/Input -Inative/app/CompositorMode -Inative/app/Navigation -Inative/app/System -Inative/app/Support -Inative/dock-helper/Client -Inative/dock-helper/Daemon -Inative/dock-helper/Loader -Inative/dock-helper/Payload'
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror $native_includes \
  -I"$task_dir" tests/native/app/Canvas/DWCanvasRendererTests.m \
  -framework Foundation -framework CoreGraphics -o "$task_dir/family-geometry"
"$task_dir/family-geometry"
