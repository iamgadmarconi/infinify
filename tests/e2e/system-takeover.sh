#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Snapshot/restore of the Stage Manager and window-tiling takeover against an in-memory preferences store and a temporary
# directory: no preference, window, app or permission of the user's is read or written, and nothing is launched.
set -eu
cd "$(dirname "$0")/../.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/infinify-system-takeover.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT HUP INT TERM
native_includes='-Icrates/desktop/include -Inative/app -Inative/app/Desktop -Inative/app/Canvas -Inative/app/Windows -Inative/app/Input -Inative/app/CompositorMode -Inative/app/Navigation -Inative/app/System -Inative/app/Support -Inative/dock-helper/Client -Inative/dock-helper/Daemon -Inative/dock-helper/Loader -Inative/dock-helper/Payload'
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -O2 -fobjc-arc -Wall -Wextra -Werror $native_includes \
  tests/native/app/System/DWSystemTakeoverTests.m native/app/System/DWSystemTakeover.m \
  -framework Foundation -o "$task_dir/system-takeover"
"$task_dir/system-takeover"
