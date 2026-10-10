#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
cargo build -p driftwm-desktop --release
app=target/app/Infinify.app
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror \
  -Icrates/desktop/include native/desktop/main.m native/desktop/navigation-coordinator.m native/desktop/focus-driver.m native/focus/focus.m native/desktop/resize-coordinator.m native/desktop/resize-driver.m native/desktop/resize-capture-policy.m native/desktop/ipc-server.m native/desktop/hotkeys.m native/desktop/config-watcher.m native/desktop/cycle-hold.m native/desktop/hot-corners.m native/desktop/input-sources.m native/desktop/window-manager.m native/desktop/pan-launch.m native/desktop/trackpad-gestures.m native/resize/resize.m target/release/libdriftwm_desktop.a \
  -framework AppKit -framework AVFoundation -framework ScreenCaptureKit \
  -framework CoreMedia -framework CoreVideo -framework QuartzCore -framework Carbon \
  -framework Security -framework SystemConfiguration -o "$app/Contents/MacOS/Infinify"
cp native/desktop/Info.plist "$app/Contents/Info.plist"
cp native/families/YABAI-NOTICE.txt "$app/Contents/Resources/"
cp LICENSE NOTICE "$app/Contents/Resources/"
# Ad-hoc signatures change with every build, so macOS drops the app's privacy
# grants each time. A stable identity keeps them: INFINIFY_SIGN_IDENTITY="Developer ID Application: ...".
codesign --force --sign "${INFINIFY_SIGN_IDENTITY:--}" "$app"
printf '%s\n' "Built $app (arm64, macOS 26+); nothing launched."
