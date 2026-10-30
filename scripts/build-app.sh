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

# The transform helper's client library (plain C) was built above; native presentation links it.
# Sources import each other by bare name; each module directory is a header search path.
native_includes='-Icrates/desktop/include -Inative/app -Inative/app/Desktop -Inative/app/Canvas -Inative/app/Windows -Inative/app/Input -Inative/app/CompositorMode -Inative/app/Navigation -Inative/app/System -Inative/app/Support -Inative/dock-helper/Client -Inative/dock-helper/Daemon -Inative/dock-helper/Loader -Inative/dock-helper/Payload'
# shellcheck disable=SC2086
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -O2 -fobjc-arc -Wall -Wextra -Werror \
  $native_includes native/app/main.m native/app/CompositorMode/DWNativePresenter.m native/app/CompositorMode/DWNativeDisplaySpace.m native/app/CompositorMode/DWNativeTransition.m native/app/CompositorMode/DWNativeViews.m native/app/CompositorMode/DWNativePlacementValidation.m native/app/CompositorMode/DWNativeReplicaInput.m native/app/CompositorMode/DWNativeReplicaFamilies.m native/app/CompositorMode/DWNativeTabletRouter.m native/app/CompositorMode/DWNativePointerGrab.m native/app/CompositorMode/DWNativeRelativeMotion.m native/app/CompositorMode/DWNativeFamily.m native/app/Windows/DWWindowObserver.m native/app/Input/DWNativeInput.m native/app/CompositorMode/DWNativeDecorations.m "$stage/privileged/dwclient.o" native/app/Navigation/DWNavigationCoordinator.m native/app/Navigation/DWNativeFocusDriver.m native/app/Navigation/DWNativeFocus.m native/app/Navigation/DWResizeCoordinator.m native/app/Navigation/DWNativeResizeDriver.m native/app/System/DWIPCServer.m native/app/Windows/DWSceneWriter.m native/app/Input/DWHotKeys.m native/app/Input/DWTapKeys.m native/app/System/DWConfigWatcher.m native/app/Input/DWCycleHold.m native/app/Input/DWHotCorners.m native/app/Input/DWInputSources.m native/app/Windows/DWWindowManager.m native/app/Windows/DWWindowEvents.m native/app/Windows/DWPanLaunch.m native/app/Input/DWTrackpadGestures.m native/app/Input/DWMultitouchSource.m native/app/Input/DWDockGuard.m native/app/Input/DWPointerHover.m native/app/Canvas/DWCanvasCursor.m native/app/Canvas/DWCanvasRenderer.m native/app/System/DWScreenshotWriter.m native/app/Canvas/DWFrameDriver.m native/app/Canvas/IFCompositorRenderer.m native/app/Canvas/IFBackgroundProgram.m native/app/Canvas/DWMacWallpaperCache.m native/app/Canvas/IFBGTiffSource.m native/app/System/DWLoginItem.m native/app/System/DWOnboarding.m native/app/System/DWSystemTakeover.m native/app/System/DWSessionWatch.m native/app/System/DWNativeDesktopCLI.m native/app/System/DWLoaderService.m native/app/System/DWDockReloader.m native/dock-helper/Daemon/DWLoaddRequest.m native/app/Navigation/DWNativeResize.m target/release/libdriftwm_desktop.a \
  -framework AppKit -framework ScreenCaptureKit \
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
