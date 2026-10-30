#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
cargo build -p driftwm-desktop --release
mkdir -p target/resize
. scripts/native-includes.sh
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror $native_includes \
  native/app/Navigation/DWResizeCoordinator.m native/app/Navigation/DWNativeResizeDriver.m tests/native/app/Navigation/DWResizeCoordinatorTests.m \
  target/release/libdriftwm_desktop.a -framework Foundation -framework CoreGraphics -framework CoreMedia -framework CoreVideo -framework ScreenCaptureKit -framework Security -framework SystemConfiguration \
  -o target/resize/desktop-regression
./target/resize/desktop-regression
