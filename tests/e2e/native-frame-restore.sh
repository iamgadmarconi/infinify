#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
cd "$(dirname "$0")/../.."
mkdir -p target/resize
native_includes='-Icrates/desktop/include -Inative/app -Inative/app/Desktop -Inative/app/Canvas -Inative/app/Windows -Inative/app/Input -Inative/app/CompositorMode -Inative/app/Navigation -Inative/app/System -Inative/app/Support -Inative/dock-helper/Client -Inative/dock-helper/Daemon -Inative/dock-helper/Loader -Inative/dock-helper/Payload'
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror $native_includes \
  tests/native/app/Navigation/DWNativeResizeTests.m -framework AppKit -o target/resize/frame-regression
./target/resize/frame-regression
