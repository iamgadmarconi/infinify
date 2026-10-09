#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
cargo build -p driftwm-desktop --release
mkdir -p target/navigation
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror \
  -Icrates/desktop/include native/desktop/navigation-coordinator.m native/desktop/navigation-regression.m \
  target/release/libdriftwm_desktop.a -framework Foundation -framework Security -framework SystemConfiguration \
  -o target/navigation/regression
./target/navigation/regression
