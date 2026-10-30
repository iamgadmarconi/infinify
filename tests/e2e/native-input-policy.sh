#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# In-memory adapter regression only. No taps, windows, event posting, native
# transforms, access requests, clipboard reads or application launches.
set -eu
cd "$(dirname "$0")/../.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/infinify-native-input.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT HUP INT TERM
. scripts/native-includes.sh
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror $native_includes \
  tests/native/app/Input/DWNativeInputTests.m native/app/CompositorMode/DWNativeTabletRouter.m native/app/Input/DWTrackpadGestures.m \
  -framework AppKit -framework ApplicationServices -framework Carbon -framework QuartzCore -o "$task_dir/native-input-policy"
"$task_dir/native-input-policy"
