#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
cargo build -p driftwm-desktop --release
mkdir -p target/navigation
. scripts/native-includes.sh
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror $native_includes \
  native/app/Navigation/DWNavigationCoordinator.m tests/native/app/Navigation/DWNavigationCoordinatorTests.m \
  target/release/libdriftwm_desktop.a -framework Foundation -framework Security -framework SystemConfiguration \
  -o target/navigation/regression
./target/navigation/regression
