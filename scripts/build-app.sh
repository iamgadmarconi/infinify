#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
cargo build -p driftwm-desktop --release
app=target/app/Infinify.app
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Library/LaunchAgents"
# The transform helper's client library is plain C, built as scripts/build-privileged.sh builds it; native presentation links it.
mkdir -p target/app-objects
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -O2 -std=gnu11 -Wall -Wextra -Werror -c \
  native/privileged/dwclient.c -o target/app-objects/dwclient.o
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -O2 -fobjc-arc -Wall -Wextra -Werror \
  -Icrates/desktop/include -Inative/privileged native/desktop/main.m native/desktop/native-presenter.m native/desktop/native-views.m native/desktop/native-replica-input.m native/desktop/native-family.m native/desktop/window-observer.m native/desktop/native-input.m native/desktop/native-decorations.m target/app-objects/dwclient.o native/desktop/navigation-coordinator.m native/desktop/focus-driver.m native/focus/focus.m native/desktop/resize-coordinator.m native/desktop/resize-driver.m native/desktop/resize-capture-policy.m native/desktop/ipc-server.m native/desktop/scene-writer.m native/desktop/hotkeys.m native/desktop/tap-keys.m native/desktop/config-watcher.m native/desktop/cycle-hold.m native/desktop/hot-corners.m native/desktop/input-sources.m native/desktop/window-manager.m native/desktop/window-events.m native/desktop/pan-launch.m native/desktop/trackpad-gestures.m native/desktop/pointer-hover.m native/desktop/canvas-renderer.m native/desktop/frame-driver.m native/desktop/compositor.m native/desktop/background.m native/desktop/background-tiff.m native/desktop/login-item.m native/desktop/onboarding.m native/desktop/session-watch.m native/resize/resize.m target/release/libdriftwm_desktop.a \
  -framework AppKit -framework AVFoundation -framework ScreenCaptureKit \
  -framework CoreMedia -framework CoreVideo -framework QuartzCore -framework Carbon \
  -framework Metal -framework CoreGraphics -framework CoreText -framework IOSurface -framework ImageIO -framework Accelerate \
  -framework Security -framework SystemConfiguration -framework ServiceManagement -o "$app/Contents/MacOS/Infinify"
cp native/desktop/Info.plist "$app/Contents/Info.plist"
cp native/families/YABAI-NOTICE.txt "$app/Contents/Resources/"
cp LICENSE NOTICE "$app/Contents/Resources/"
# The login item: `Infinify login-item on` registers this LaunchAgent, whose program is
# the bundle's own executable. It is inside the bundle before the bundle is signed.
cp native/desktop/com.marengox.infinify.agent.plist "$app/Contents/Library/LaunchAgents/"
# Ad-hoc signatures change with every build, so macOS drops the app's privacy
# grants each time. A stable identity keeps them: INFINIFY_SIGN_IDENTITY="Developer ID Application: ...".
codesign --force --sign "${INFINIFY_SIGN_IDENTITY:--}" "$app"
printf '%s\n' "Built $app (arm64, macOS 26+); nothing launched. scripts/install-app.sh installs it as ~/Applications/Infinify.app."
