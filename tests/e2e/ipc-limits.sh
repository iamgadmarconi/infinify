#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# DriftWM v0.21.0's IPC limits and screenshot write, on the production IPC server and
# PNG writer in a headless binary (the one tests/e2e/screenshot-write.sh builds). No
# desktop application, renderer, GPU, native window, capture or input starts, and every
# file and socket is in a directory of its own.
set -eu
cd "$(dirname "$0")/../.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
cargo build -p driftwm-desktop --release
mkdir -p target/screenshot-write
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror \
  -Icrates/desktop/include native/desktop/screenshot-write-regression.m \
  native/desktop/screenshot-writer.m native/desktop/ipc-server.m \
  target/release/libdriftwm_desktop.a -framework Foundation -framework CoreGraphics \
  -framework ImageIO -framework Security -framework SystemConfiguration \
  -o target/screenshot-write/regression
python3 tests/e2e/ipc-limits-driver.py target/screenshot-write/regression
