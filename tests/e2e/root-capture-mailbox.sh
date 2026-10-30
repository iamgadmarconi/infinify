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
# Extracts the production code under test from native/app/Desktop (and DWNativeTransition.m) into .inc files.
# argv: OUTPUT_DIR [APP_DESKTOP_DIR] [NATIVE_TRANSITION_M]
from pathlib import Path
import sys

output = Path(sys.argv[1])
app = Path(sys.argv[2] if len(sys.argv) > 2 else "native/app/Desktop")
transition_path = Path(sys.argv[3] if len(sys.argv) > 3 else "native/app/CompositorMode/DWNativeTransition.m")
mailbox_h = (app / "DWRootCaptureMailbox.h").read_text()
mailbox_m = (app / "DWRootCaptureMailbox.m").read_text()
live_m = (app / "LiveSource.m").read_text()
private_h = (app / "Desktop+Private.h").read_text()
view_m = (app / "DesktopView.m").read_text()
input_m = (app / "Desktop+Input.m").read_text()
captured_m = (app / "Desktop+CapturedInput.m").read_text()
titles_m = (app / "Desktop+NativeTitles.m").read_text()
windows_m = (app / "Desktop+Windows.m").read_text()
navigation_m = (app / "Desktop+Navigation.m").read_text()
fill_m = (app / "Desktop+Fill.m").read_text()

def one(source, marker):
    if source.count(marker) != 1:
        raise SystemExit(f"Expected one production definition: {marker}")
    return source.index(marker)
def function(source, marker):
    start = one(source, marker)
    return source[start:source.index("\n}\n", start) + len("\n}\n")]

for source, marker, name in (
    (mailbox_h, "@interface DWRootCaptureMailbox :", "root-capture-mailbox-interface.inc"),
    (mailbox_m, "@implementation DWRootCaptureMailbox {", "root-capture-mailbox-implementation.inc"),
):
    start = one(source, marker)
    end = source.index("\n@end", start) + len("\n@end")
    (output / name).write_text(source[start:end] + "\n")
start = live_m.index("- (BOOL)acceptCapturedSample:", live_m.index("@implementation LiveSource"))
end = live_m.index("\n- (BOOL)installPixels:(CVPixelBufferRef)pixels {", start)
(output / "root-capture-source-acceptance.inc").write_text(live_m[start:end] + "\n")
(output / "root-capture-crop.inc").write_text(function(mailbox_h, "static inline BOOL DWRootCaptureCrop("))
transition = transition_path.read_text()
geometry = []
for marker in ("static BOOL validRect(", "static BOOL roundedEdgesMatch(", "static BOOL captureImageGeometry("):
    start = transition.index(marker)
    end = transition.index("\n}\n", start) + len("\n}\n")
    geometry.append(transition[start:end])
(output / "native-transition-capture-geometry.inc").write_text("\n".join(geometry))
start = one(private_h, "static inline BOOL DWCapturedInputAvailable(")
end = private_h.index("\n}", start) + len("\n}")
(output / "root-capture-input-availability.inc").write_text(private_h[start:end] + "\n")
(output / "native-chrome-geometry.inc").write_text(
    function(titles_m, "static BOOL DWNativeChromeFrameMatches(")
    + function(windows_m, "static NSDictionary *DWNativeMovedButtons(")
    + function(titles_m, "static NSDictionary *DWNativeButtonsAfterRefresh("))
start = one(private_h, "static inline NSDictionary *DWFocusedStandIn(")
end = private_h.index("\n}\n", one(private_h, "static inline BOOL sameInputTarget(")) + len("\n}\n")
(output / "captured-input-target-functions.inc").write_text(
    private_h[start:end] + function(view_m, "static BOOL DWCapturedRootFocusCurrent("))
start = input_m.index("    // Native Fill owns temporary geometry.", input_m.index("- (BOOL)nativeInput:"))
end = input_m.index("    // A shell-owned decoration/action pair", start)
(output / "captured-input-fill-blocker.inc").write_text(input_m[start:end])
def method(source, after, marker):
    start = source.index(marker, source.index(after))
    ends = [i for i in (source.find("\n- (", start + len(marker)), source.find("\n@end", start + len(marker))) if i >= 0]
    return source[start:min(ends)] + "\n"
(output / "captured-input-view-consumers.inc").write_text("\n".join(method(view_m, "@implementation DesktopView", marker) for marker in (
    "- (NSDictionary *)inputIntentForHit:", "- (void)deliverHeld {",
    "- (BOOL)forward:(CGEventRef)e at:(CGPoint)p output:(NSNumber *)output {",
    "- (BOOL)forward:(CGEventRef)e at:(CGPoint)p output:(NSNumber *)output expected:",
    "- (BOOL)forwardCaptured:", "- (void)mouseDragged:", "- (void)releasePressed {",
    "- (void)released:(CGPoint)p at:(NSTimeInterval)time",
)))
(output / "captured-input-desktop-consumers.inc").write_text("\n".join(method(source, "@implementation Desktop (", marker) for source, marker in (
    (captured_m, "- (NSDictionary *)resolveCapturedPointer:"), (captured_m, "- (BOOL)forwardCapturedPointer:"), (captured_m, "- (BOOL)forwardTabletTail:"),
    (navigation_m, "- (void)cancelNativeTitleClick {"), (navigation_m, "- (void)deferNativeTitleClick:"), (navigation_m, "- (void)fireNativeTitleClick:"),
    (fill_m, "- (BOOL)nativeFillCurrent:"), (fill_m, "- (NSDictionary *)nativeFillBackground:"),
)))
PY
. scripts/native-includes.sh
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -O2 -fobjc-arc -Wall -Wextra -Werror $native_includes \
  -I"$task_dir" tests/native/app/Desktop/DWRootCaptureMailboxTests.m \
  -framework Foundation -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo -framework CoreGraphics \
  -o "$task_dir/root-capture-mailbox"
"$task_dir/root-capture-mailbox"
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -O2 -fobjc-arc -Wall -Wextra -Werror $native_includes \
  -I"$task_dir" tests/native/app/Desktop/DesktopCapturedInputTests.m \
  native/app/CompositorMode/DWNativePointerGrab.m native/app/CompositorMode/DWNativeTabletRouter.m native/app/Input/DWHotKeys.m \
  -framework AppKit -framework Carbon -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo -framework QuartzCore \
  -o "$task_dir/captured-input"
"$task_dir/captured-input"
