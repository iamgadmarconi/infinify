#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64

root=$(pwd -P)
target=$root/target
app_dir=$target/app
mkdir -p "$target"
stage=$(mktemp -d "$target/.infinify-stage.XXXXXX")
app=$stage/Infinify.app

cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  rm -rf "$stage"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/Library/LaunchAgents"

# Record the exact working-tree source set before compilation. The package helper
# refuses to publish if tracked or non-ignored untracked inputs change before
# signing and promotion finish.
python3 scripts/build-app-package.py snapshot \
  --root "$root" \
  --output "$stage/source-before.json"

./scripts/build-privileged.sh --production --output-dir "$stage/privileged"
cargo build -p driftwm-desktop --release

# The transform helper's client library is plain C; native presentation links it.
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -O2 -std=gnu11 -Wall -Wextra -Werror -c \
  native/privileged/dwclient.c -o "$stage/dwclient.o"
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -O2 -fobjc-arc -Wall -Wextra -Werror \
  -Icrates/desktop/include -Inative/privileged native/desktop/main.m native/desktop/native-presenter.m native/desktop/native-display-space.m native/desktop/native-transition.m native/desktop/native-views.m native/desktop/native-placement-validation.m native/desktop/native-replica-input.m native/desktop/native-replica-family.m native/desktop/native-tablet.m native/desktop/native-pointer-grab.m native/desktop/native-relative-motion.m native/desktop/native-family.m native/desktop/window-observer.m native/desktop/native-input.m native/desktop/native-decorations.m "$stage/dwclient.o" native/desktop/navigation-coordinator.m native/desktop/focus-driver.m native/focus/focus.m native/desktop/resize-coordinator.m native/desktop/resize-driver.m native/desktop/ipc-server.m native/desktop/scene-writer.m native/desktop/hotkeys.m native/desktop/tap-keys.m native/desktop/config-watcher.m native/desktop/cycle-hold.m native/desktop/hot-corners.m native/desktop/input-sources.m native/desktop/window-manager.m native/desktop/window-events.m native/desktop/pan-launch.m native/desktop/trackpad-gestures.m native/desktop/multitouch-source.m native/desktop/dock-guard.m native/desktop/pointer-hover.m native/desktop/canvas-cursor.m native/desktop/canvas-renderer.m native/desktop/screenshot-writer.m native/desktop/frame-driver.m native/desktop/compositor.m native/desktop/background.m native/desktop/mac-wallpaper-cache.m native/desktop/background-tiff.m native/desktop/login-item.m native/desktop/onboarding.m native/desktop/system-takeover.m native/desktop/session-watch.m native/desktop/native-desktop-cli.m native/desktop/loader-service.m native/desktop/dock-reload.m native/privileged/loadd-request.m native/resize/resize.m target/release/libdriftwm_desktop.a \
  -framework AppKit -framework AVFoundation -framework ScreenCaptureKit \
  -framework CoreMedia -framework CoreVideo -framework QuartzCore -framework Carbon \
  -framework Metal -framework CoreGraphics -framework CoreText -framework IOSurface -framework ImageIO -framework Accelerate \
  -framework Security -framework SystemConfiguration -framework ServiceManagement -o "$app/Contents/MacOS/Infinify"

python3 scripts/build-app-package.py publish \
  --root "$root" \
  --snapshot "$stage/source-before.json" \
  --staged-app "$app" \
  --privileged-dir "$stage/privileged" \
  --app-dir "$app_dir"

printf '%s\n' "Built $app_dir/Infinify.app (arm64, macOS 26+); nothing launched. scripts/install-app.sh installs it as ~/Applications/Infinify.app."
