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
start = source.index("static BOOL DWCapturedInputAvailable(")
end = source.index("\n}", start) + len("\n}")
(output / "root-capture-input-availability.inc").write_text(source[start:end] + "\n")
start = source.index("static NSNumber *liveHit(")
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
)))
(output / "captured-input-desktop-consumers.inc").write_text("\n".join(method(marker) for marker in (
    "- (NSDictionary *)resolveCapturedPointer:", "- (BOOL)forwardCapturedPointer:", "- (BOOL)forwardTabletTail:",
)))
PY
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -O2 -fobjc-arc -Wall -Wextra -Werror \
  -I"$task_dir" native/desktop/root-capture-mailbox-regression.m \
  -framework Foundation -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo \
  -o "$task_dir/root-capture-mailbox"
"$task_dir/root-capture-mailbox"
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -O2 -fobjc-arc -Wall -Wextra -Werror \
  -I"$task_dir" native/desktop/captured-input-regression.m \
  native/desktop/native-pointer-grab.m native/desktop/native-tablet.m \
  -framework AppKit -framework ScreenCaptureKit -framework CoreMedia -framework CoreVideo -framework QuartzCore \
  -o "$task_dir/captured-input"
"$task_dir/captured-input"
