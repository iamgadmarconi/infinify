#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# In-memory presenter/transfer regression; no native windows, getters or input.
set -eu
cd "$(dirname "$0")/../.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/infinify-view-transfer.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT HUP INT TERM
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror \
  -I native/privileged native/desktop/native-views.m native/desktop/native-views-regression.m \
  -framework AppKit -framework ApplicationServices -framework Security \
  -o "$task_dir/native-view-transfer"
"$task_dir/native-view-transfer"
