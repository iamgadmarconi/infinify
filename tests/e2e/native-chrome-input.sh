#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Actual early chrome consumer and tap pair ownership; substituted native/controller reads.
# No windows, event taps or posted events. Not optical/third-party compositing proof.
set -eu
cd "$(dirname "$0")/../.."
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/infinify-chrome-input.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT HUP INT TERM
python3 - "$task_dir" <<'PY'
import pathlib, sys
text = pathlib.Path("native/app/Desktop/Desktop+NativeTitles.m").read_text()
def block(start, end):
    assert text.count(start) == 1 and text.count(end) == 1
    return text[text.index(start):text.index(end)]
out = pathlib.Path(sys.argv[1])
(out / "ChromeGeometry.inc").write_text(block("static BOOL DWNativeChromeFrameMatches(", "// Failed AX refresh"))
(out / "ChromeConsumer.inc").write_text(block("- (BOOL)earlyNativeTitle:", "// Is a mouse-moved packet"))
PY
. scripts/native-includes.sh
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror $native_includes -I"$task_dir" \
  tests/native/app/Desktop/DesktopNativeChromeTests.m native/app/CompositorMode/DWNativeTabletRouter.m native/app/Input/DWTrackpadGestures.m \
  -framework AppKit -framework ApplicationServices -framework QuartzCore -framework Carbon -o "$task_dir/chrome-input"
"$task_dir/chrome-input"
