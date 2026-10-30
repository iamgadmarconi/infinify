#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Pure request/rate state; no application, windows, capture or permission calls.
set -eu
cd "$(dirname "$0")/../.."
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/infinify-capture-config.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT HUP INT TERM
. scripts/native-includes.sh
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -std=c11 -Wall -Wextra -Werror $native_includes \
  tests/native/app/Desktop/DWCaptureConfigurationTests.c -framework CoreMedia -framework CoreGraphics \
  -o "$task_dir/capture-configuration"
"$task_dir/capture-configuration"
