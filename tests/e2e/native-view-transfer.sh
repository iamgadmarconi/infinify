#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# In-memory presenter/transfer regression; no native windows, getters or input.
set -eu
cd "$(dirname "$0")/../.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/infinify-view-transfer.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT HUP INT TERM
native_includes='-Icrates/desktop/include -Inative/app -Inative/app/Desktop -Inative/app/Canvas -Inative/app/Windows -Inative/app/Input -Inative/app/CompositorMode -Inative/app/Navigation -Inative/app/System -Inative/app/Support -Inative/dock-helper/Client -Inative/dock-helper/Daemon -Inative/dock-helper/Loader -Inative/dock-helper/Payload'
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror $native_includes \
  native/app/CompositorMode/DWNativeViews.m tests/native/app/CompositorMode/DWNativeViewsTests.m \
  -framework AppKit -framework ApplicationServices -framework Security \
  -o "$task_dir/native-view-transfer"
"$task_dir/native-view-transfer"
