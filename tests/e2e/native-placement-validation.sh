#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Substituted read-only placement/input verifier regression; no native fixtures.
set -eu
cd "$(dirname "$0")/../.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/infinify-placement-validation.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT HUP INT TERM
native_includes='-Icrates/desktop/include -Inative/app -Inative/app/Desktop -Inative/app/Canvas -Inative/app/Windows -Inative/app/Input -Inative/app/CompositorMode -Inative/app/Navigation -Inative/app/System -Inative/app/Support -Inative/dock-helper/Client -Inative/dock-helper/Daemon -Inative/dock-helper/Loader -Inative/dock-helper/Payload'
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror $native_includes \
  tests/native/app/CompositorMode/DWNativePlacementValidationTests.m \
  -framework Foundation -framework CoreGraphics -o "$task_dir/native-placement-validation"
"$task_dir/native-placement-validation"
