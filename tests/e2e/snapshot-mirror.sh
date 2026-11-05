#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# In-memory regression: the shell's snapshot mirror rebuilds the real controller's snapshot from top-level deltas across a camera flight,
# edits, a refusal, a load and controller swaps, and equals a full snapshot after every step. No window, tap or native call.
set -eu
cd "$(dirname "$0")/../.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
cargo build -p driftwm-desktop --release
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/infinify-snapshot-mirror.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT HUP INT TERM
. scripts/native-includes.sh
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror $native_includes \
  native/app/Desktop/DWSnapshotMirror.m tests/native/app/Desktop/DWSnapshotMirrorTests.m \
  target/release/libdriftwm_desktop.a -framework Foundation -framework Security -framework SystemConfiguration \
  -o "$task_dir/snapshot-mirror"
"$task_dir/snapshot-mirror"
