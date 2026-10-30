#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Deterministic recovery lifecycle only; no native windows, capture or input.
set -eu
cd "$(dirname "$0")/../.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/infinify-family-recovery.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT HUP INT TERM
. scripts/native-includes.sh
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror $native_includes \
  tests/native/app/CompositorMode/DWNativeReplicaFamiliesTests.m \
  -framework AppKit -framework ApplicationServices -framework ScreenCaptureKit \
  -framework QuartzCore -framework CoreVideo -framework CoreMedia -o "$task_dir/native-family-recovery"
INFINIFY_DEBUG_FAMILIES=1 "$task_dir/native-family-recovery" 2>"$task_dir/lifecycle.log" || { cat "$task_dir/lifecycle.log"; exit 1; }
rg -q 'reason=first_frame_timeout_no_callback ' "$task_dir/lifecycle.log"
rg -q 'reason=first_frame_timeout_no_valid_frame ' "$task_dir/lifecycle.log"
