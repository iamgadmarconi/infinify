#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
cargo build -p driftwm-desktop --release
app=target/app/Infinify.app
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror \
  -Icrates/desktop/include native/desktop/main.m native/desktop/navigation-coordinator.m native/desktop/focus-driver.m native/focus/focus.m target/release/libdriftwm_desktop.a \
  -framework AppKit -framework AVFoundation -framework ScreenCaptureKit \
  -framework CoreMedia -framework CoreVideo -framework QuartzCore -framework Carbon \
  -framework Security -framework SystemConfiguration -o "$app/Contents/MacOS/Infinify"
cp native/desktop/Info.plist "$app/Contents/Info.plist"
cp LICENSE NOTICE "$app/Contents/Resources/"
codesign --force --sign - "$app"
printf '%s\n' "Built $app (arm64, macOS 26+); nothing launched."
