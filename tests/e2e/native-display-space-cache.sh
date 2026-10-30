#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Deterministic display-query CLI scenarios only; no native reads or mutations.
set -eu
cd "$(dirname "$0")/../.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/infinify-display-space-cache.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT HUP INT TERM
. scripts/native-includes.sh
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror $native_includes \
  tests/native/app/CompositorMode/DWNativeDisplaySpaceTests.m \
  -framework Foundation -framework CoreGraphics -o "$task_dir/native-display-space-cache"
"$task_dir/native-display-space-cache"
"$task_dir/native-display-space-cache" --registration-failed
