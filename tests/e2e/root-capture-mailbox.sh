#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Actual mailbox/acceptance code with in-memory samples and deferred dispatch.
# No stream, window, capture permission request or native input is created.
set -eu
cd "$(dirname "$0")/../.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/infinify-root-capture.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT HUP INT TERM
python3 - "$task_dir" <<'PY'
from pathlib import Path
import sys

source = Path("native/desktop/main.m").read_text()
output = Path(sys.argv[1])
for marker, name in (
    ("@interface DWRootCaptureMailbox :", "root-capture-mailbox-interface.inc"),
    ("@implementation DWRootCaptureMailbox {", "root-capture-mailbox-implementation.inc"),
):
    if source.count(marker) != 1:
        raise SystemExit(f"Expected one production definition: {marker}")
    start = source.index(marker)
    end = source.index("\n@end", start) + len("\n@end")
    (output / name).write_text(source[start:end] + "\n")
start = source.index("- (BOOL)acceptCapturedSample:", source.index("@implementation LiveSource"))
end = source.index("\n- (BOOL)installSample:", start)
(output / "root-capture-source-acceptance.inc").write_text(source[start:end] + "\n")
start = source.index("static BOOL DWRootCaptureCrop(")
end = source.index("\n}\n", start) + len("\n}\n")
(output / "root-capture-crop.inc").write_text(source[start:end])
transition = Path("native/desktop/native-transition.m").read_text()
geometry = []
for marker in ("static BOOL validRect(", "static BOOL roundedEdgesMatch(", "static BOOL captureImageGeometry("):
    start = transition.index(marker)
    end = transition.index("\n}\n", start) + len("\n}\n")
    geometry.append(transition[start:end])
(output / "native-transition-capture-geometry.inc").write_text("\n".join(geometry))
start = source.index("static BOOL DWCapturedInputAvailable(")
end = source.index("\n}", start) + len("\n}")
(output / "root-capture-input-availability.inc").write_text(source[start:end] + "\n")
start = source.index("static BOOL DWNativeChromeFrameMatches(")
end = source.index("// A child press may activate", start)
(output / "native-chrome-geometry.inc").write_text(source[start:end])
start = source.index("static NSDictionary *DWFocusedStandIn(")
end = source.index("// A provisional click recipient", start)
(output / "captured-input-target-functions.inc").write_text(source[start:end])
def method(marker):
    start = source.index(marker, source.index("@implementation DesktopView"))
    end = source.index("\n- (", start + len(marker))
    return source[start:end] + "\n"
(output / "captured-input-view-consumers.inc").write_text("\n".join(method(marker) for marker in (
    "- (NSDictionary *)inputIntentForHit:", "- (void)deliverHeld {",
    "- (BOOL)forward:(CGEventRef)e at:(CGPoint)p output:(NSNumber *)output activate:(BOOL)activate {",
    "- (BOOL)forward:(CGEventRef)e at:(CGPoint)p output:(NSNumber *)output activate:(BOOL)activate expected:",
    "- (BOOL)forwardCaptured:", "- (void)releasePressed {",
    "- (void)released:(CGPoint)p at:(NSTimeInterval)time",
)))
(output / "captured-input-desktop-consumers.inc").write_text("\n".join(method(marker) for marker in (
    "- (NSDictionary *)resolveCapturedPointer:", "- (BOOL)forwardCapturedPointer:", "- (BOOL)forwardTabletTail:",
    "- (void)cancelNativeTitleClick {", "- (void)deferNativeTitleClick:", "- (void)fireNativeTitleClick:",
)))
PY
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -O2 -fobjc-arc -Wall -Wextra -Werror \
  -I"$task_dir" native/desktop/root-capture-mailbox-regression.m \
  -framework Foundation -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo -framework CoreGraphics \
  -o "$task_dir/root-capture-mailbox"
"$task_dir/root-capture-mailbox"
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -O2 -fobjc-arc -Wall -Wextra -Werror \
  -I"$task_dir" native/desktop/captured-input-regression.m \
  native/desktop/native-pointer-grab.m native/desktop/native-tablet.m native/desktop/hotkeys.m \
  -framework AppKit -framework Carbon -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo -framework QuartzCore \
  -o "$task_dir/captured-input"
"$task_dir/captured-input"
