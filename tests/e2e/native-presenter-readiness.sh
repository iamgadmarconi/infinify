#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# In-memory presenter/ACK regression only; no helper, native windows or input.
set -eu
cd "$(dirname "$0")/../.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/infinify-presenter-readiness.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT HUP INT TERM
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror \
  -I native/privileged native/desktop/native-presenter-regression.m \
  -framework AppKit -framework ApplicationServices -framework Security \
  -o "$task_dir/native-presenter-readiness"
"$task_dir/native-presenter-readiness"
