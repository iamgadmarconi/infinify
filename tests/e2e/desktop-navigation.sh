#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
cargo build -p driftwm-desktop --release
mkdir -p target/navigation
native_includes='-Icrates/desktop/include -Inative/app -Inative/app/Desktop -Inative/app/Canvas -Inative/app/Windows -Inative/app/Input -Inative/app/CompositorMode -Inative/app/Navigation -Inative/app/System -Inative/app/Support -Inative/dock-helper/Client -Inative/dock-helper/Daemon -Inative/dock-helper/Loader -Inative/dock-helper/Payload'
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror $native_includes \
  native/app/Navigation/DWNavigationCoordinator.m tests/native/app/Navigation/DWNavigationCoordinatorTests.m \
  target/release/libdriftwm_desktop.a -framework Foundation -framework Security -framework SystemConfiguration \
  -o target/navigation/regression
./target/navigation/regression
