#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# No desktop application, renderer, GPU, native window, capture or input starts.
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
python3 tests/e2e/screenshot-write-driver.py target/screenshot-write/regression
