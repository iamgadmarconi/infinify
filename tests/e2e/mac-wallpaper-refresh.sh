#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Pure timing policy: no wallpaper queries, windows, capture or input.
set -eu
cd "$(dirname "$0")/../.."
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/infinify-wallpaper-refresh.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT HUP INT TERM
native_includes='-Icrates/desktop/include -Inative/app -Inative/app/Desktop -Inative/app/Canvas -Inative/app/Windows -Inative/app/Input -Inative/app/CompositorMode -Inative/app/Navigation -Inative/app/System -Inative/app/Support -Inative/dock-helper/Client -Inative/dock-helper/Daemon -Inative/dock-helper/Loader -Inative/dock-helper/Payload'
cc -std=c11 -Wall -Wextra -Werror $native_includes tests/native/app/Canvas/DWMacWallpaperRefreshTests.c \
  -lm -o "$task_dir/mac-wallpaper-refresh"
"$task_dir/mac-wallpaper-refresh"
