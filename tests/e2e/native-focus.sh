#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Headless regression of the shipped focus adapter (native/focus/focus.m) through its C ABI: an identity that is not a live
# window of the process it names is never owned, selection refuses it before its guard runs, and nothing is changed for it.
# Read-only: no window is launched or activated, no Accessibility message is sent, no permission is requested, no input is posted.
set -eu
cd "$(dirname "$0")/../.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/infinify-native-focus.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT HUP INT TERM
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror -Inative/focus \
  -c native/focus/focus.m -o "$task_dir/focus.o"
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -Wall -Wextra -Werror -Inative/focus \
  -c native/focus/focus-regression.c -o "$task_dir/focus-regression.o"
xcrun clang -arch arm64 "$task_dir/focus-regression.o" "$task_dir/focus.o" -framework AppKit -o "$task_dir/focus-regression"
"$task_dir/focus-regression"
printf '%s\n' 'PASS: focus adapter refuses invalid and stale identities without changing anything'
