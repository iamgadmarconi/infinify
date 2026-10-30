#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# In-memory regression only: synthetic MultitouchSupport contact records through the adapter into the
# recogniser, and the Dock-control decision on synthetic states. The source is never started and the tap
# never installed: no MultitouchSupport call, event tap, device, window, permission request or application
# launch. Passing does not show that the framework delivers such records, that its offsets are right on
# this machine, or that a system gesture is held back on a trackpad.
set -eu
cd "$(dirname "$0")/../.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/infinify-multitouch.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT HUP INT TERM
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror \
  native/desktop/multitouch-regression.m native/desktop/trackpad-gestures.m \
  -framework AppKit -framework ApplicationServices -framework QuartzCore -o "$task_dir/multitouch-source"
"$task_dir/multitouch-source"
