#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# DriftWM v0.21.0's IPC limits and screenshot write, on the production IPC server and PNG writer in one headless binary,
# driven by tests/e2e/ipc-limits-driver.py and tests/e2e/screenshot-write-driver.py. No desktop application, renderer, GPU,
# native window, capture or input starts, and every file and socket is in a directory of its own.
set -eu
cd "$(dirname "$0")/../.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
cargo build -p driftwm-desktop --release
mkdir -p target/screenshot-write
native_includes='-Icrates/desktop/include -Inative/app -Inative/app/Desktop -Inative/app/Canvas -Inative/app/Windows -Inative/app/Input -Inative/app/CompositorMode -Inative/app/Navigation -Inative/app/System -Inative/app/Support -Inative/dock-helper/Client -Inative/dock-helper/Daemon -Inative/dock-helper/Loader -Inative/dock-helper/Payload'
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror $native_includes \
  tests/native/app/System/DWScreenshotWriterTests.m \
  native/app/System/DWScreenshotWriter.m native/app/System/DWIPCServer.m \
  target/release/libdriftwm_desktop.a -framework Foundation -framework CoreGraphics \
  -framework ImageIO -framework Security -framework SystemConfiguration \
  -o target/screenshot-write/regression
python3 tests/e2e/ipc-limits-driver.py target/screenshot-write/regression
python3 tests/e2e/screenshot-write-driver.py target/screenshot-write/regression
