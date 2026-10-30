#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# In-memory regression: the real controller's {"hit": null} answer through the shell's hit-reply helper. No window, tap or native call.
set -eu
cd "$(dirname "$0")/../.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
cargo build -p driftwm-desktop --release
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/infinify-controller-hit.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT HUP INT TERM
. scripts/native-includes.sh
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror $native_includes \
  tests/native/app/CompositorMode/DWControllerHitTests.m \
  target/release/libdriftwm_desktop.a -framework Foundation -framework CoreGraphics -framework CoreMedia -framework CoreVideo -framework ScreenCaptureKit -framework Security -framework SystemConfiguration \
  -o "$task_dir/controller-hit"
"$task_dir/controller-hit"
