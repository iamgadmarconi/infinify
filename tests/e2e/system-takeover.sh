#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Snapshot/restore of the Stage Manager, window-tiling and title-bar double-click takeover against an in-memory preferences store and a temporary
# directory: no preference, window, app or permission of the user's is read or written, and nothing is launched.
set -eu
cd "$(dirname "$0")/../.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/infinify-system-takeover.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT HUP INT TERM
. scripts/native-includes.sh
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -O2 -fobjc-arc -Wall -Wextra -Werror $native_includes \
  tests/native/app/System/DWSystemTakeoverTests.m native/app/System/DWSystemTakeover.m \
  -framework Foundation -o "$task_dir/system-takeover"
"$task_dir/system-takeover"
