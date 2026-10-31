#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Title-region classifier over recorded Accessibility shapes (Chrome with horizontal and with vertical tabs, TextEdit, Finder, Aside's sign-in
# window and Aside's tab-sidebar window) with the AX calls substituted by a table. No process, window, tap, event, permission prompt or
# native session is touched; a pass is not proof that a press on a third-party window is routed.
set -eu
cd "$(dirname "$0")/../.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/infinify-native-decorations.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT HUP INT TERM
. scripts/native-includes.sh
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror $native_includes -Itests/native/app/CompositorMode \
  tests/native/app/CompositorMode/DWNativeDecorationsTests.m \
  -framework AppKit -framework ApplicationServices -framework QuartzCore -o "$task_dir/native-decorations"
"$task_dir/native-decorations"
