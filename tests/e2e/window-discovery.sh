#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# In-memory metadata and scheduling only; no windows, AX, helper or input.
set -eu
cd "$(dirname "$0")/../.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/infinify-window-discovery.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT HUP INT TERM
. scripts/native-includes.sh
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror $native_includes \
  tests/native/app/Windows/DWWindowManagerTests.m -framework AppKit -framework ApplicationServices \
  -framework ScreenCaptureKit -framework QuartzCore -o "$task_dir/window-discovery"
"$task_dir/window-discovery"
