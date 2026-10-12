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
source = Path("native/desktop/canvas-renderer.m").read_text()
methods = []
for marker in ("- (BOOL)hasGeometryTransitions {", "- (BOOL)hasFamilyGeometryTransitions {"):
    if source.count(marker) != 1:
        raise SystemExit(f"Expected one production query: {marker}")
    start = source.index(marker)
    end = source.index("\n- (", start + len(marker))
    methods.append(source[start:end])
(Path(sys.argv[1]) / "family-geometry-queries.inc").write_text("\n".join(methods) + "\n")
PY
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror \
  -I"$task_dir" native/desktop/family-geometry-regression.m \
  -framework Foundation -framework CoreGraphics -o "$task_dir/family-geometry"
"$task_dir/family-geometry"
