#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Substituted read-only placement/input verifier regression; no native fixtures.
set -eu
cd "$(dirname "$0")/../.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/infinify-placement-validation.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT HUP INT TERM
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror \
  native/desktop/native-placement-validation-regression.m \
  -framework Foundation -framework CoreGraphics -o "$task_dir/native-placement-validation"
"$task_dir/native-placement-validation"
