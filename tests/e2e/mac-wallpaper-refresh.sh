#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Pure timing policy: no wallpaper queries, windows, capture or input.
set -eu
cd "$(dirname "$0")/../.."
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/infinify-wallpaper-refresh.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT HUP INT TERM
. scripts/native-includes.sh
cc -std=c11 -Wall -Wextra -Werror $native_includes tests/native/app/Canvas/DWMacWallpaperRefreshTests.c \
  -lm -o "$task_dir/mac-wallpaper-refresh"
"$task_dir/mac-wallpaper-refresh"
