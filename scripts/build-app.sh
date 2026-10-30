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
. scripts/native-includes.sh
# shellcheck disable=SC2086
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -O2 -fobjc-arc -Wall -Wextra -Werror \
  $native_includes native/app/main.m native/app/Desktop/Desktop.m native/app/Desktop/Desktop+Input.m native/app/Desktop/Desktop+NativeMouse.m native/app/Desktop/Desktop+CapturedInput.m native/app/Desktop/Desktop+NativeTitles.m native/app/Desktop/Desktop+Gestures.m native/app/Desktop/Desktop+Navigation.m native/app/Desktop/Desktop+Fill.m native/app/Desktop/Desktop+Hover.m native/app/Desktop/Desktop+Windows.m native/app/Desktop/Desktop+Visibility.m native/app/Desktop/Desktop+Chooser.m native/app/Desktop/Desktop+Capture.m native/app/Desktop/Desktop+Session.m native/app/Desktop/Desktop+Config.m native/app/Desktop/Desktop+Actions.m native/app/Desktop/Desktop+Bindings.m native/app/Desktop/Desktop+IPC.m native/app/Desktop/Desktop+Rendering.m native/app/Desktop/DesktopView.m native/app/Desktop/DesktopView+Scroll.m native/app/Desktop/DesktopView+Pointer.m native/app/Desktop/LiveSource.m native/app/Desktop/DWRootCaptureMailbox.m native/app/Desktop/Router.m native/app/Desktop/DWExportFrame.m native/app/Desktop/FlippedView.m native/app/Desktop/FixtureWindow.m native/app/Desktop/CanvasPanel.m native/app/Desktop/DesktopPanel.m native/app/Desktop/DWChildProcess.m native/app/CompositorMode/DWNativeWindowServer.m native/app/CompositorMode/DWNativePresenter.m native/app/CompositorMode/DWNativePresenter+Acknowledgement.m native/app/CompositorMode/DWNativePresenter+Families.m native/app/CompositorMode/DWNativePresenter+Withholding.m native/app/CompositorMode/DWNativePresenter+Frames.m native/app/CompositorMode/DWNativePresenterGroup.m native/app/CompositorMode/DWNativeDisplaySpace.m native/app/CompositorMode/DWNativeTransition.m native/app/CompositorMode/DWNativeViews.m native/app/CompositorMode/DWNativePlacementValidation.m native/app/CompositorMode/DWNativeReplicaInput.m native/app/CompositorMode/DWNativeReplicaFamilies.m native/app/CompositorMode/DWNativeReplicaFamilies+Recovery.m native/app/CompositorMode/DWNativeReplicaFamilies+Ordering.m native/app/CompositorMode/DWReplicaMember.m native/app/CompositorMode/DWReplicaRecovery.m native/app/CompositorMode/DWReplicaOrder.m native/app/CompositorMode/DWNativeTabletRouter.m native/app/CompositorMode/DWNativePointerGrab.m native/app/CompositorMode/DWNativeRelativeMotion.m native/app/CompositorMode/DWNativeFamily.m native/app/Windows/DWWindowObserver.m native/app/Input/DWNativeInput.m native/app/CompositorMode/DWNativeDecorations.m "$stage/privileged/dwclient.o" native/app/Navigation/DWNavigationCoordinator.m native/app/Navigation/DWNativeFocusDriver.m native/app/Navigation/DWNativeFocus.m native/app/Navigation/DWResizeCoordinator.m native/app/Navigation/DWNativeResizeDriver.m native/app/System/DWIPCServer.m native/app/Windows/DWSceneWriter.m native/app/Input/DWHotKeys.m native/app/Input/DWTapKeys.m native/app/System/DWConfigWatcher.m native/app/Input/DWCycleHold.m native/app/Input/DWHotCorners.m native/app/Input/DWInputSources.m native/app/Windows/DWWindowManager.m native/app/Windows/DWWindowManager+Discovery.m native/app/Windows/DWWindowCandidate.m native/app/Windows/DWWindowEvents.m native/app/Windows/DWWindowEvents+Applications.m native/app/Windows/DWWindowEvents+Observation.m native/app/Windows/DWApplicationWatch.m native/app/Windows/DWApplicationCatalogWatch.m native/app/Windows/DWApplicationMetadata.m native/app/Windows/DWObservedApplication.m native/app/Windows/DWObservedWindow.m native/app/Windows/DWPanLaunch.m native/app/Input/DWTrackpadGestures.m native/app/Input/DWMultitouchSource.m native/app/Input/DWDockGuard.m native/app/Input/DWPointerHover.m native/app/Canvas/DWCanvasCursor.m native/app/Canvas/DWCanvasRenderer.m native/app/Canvas/DWCanvasRenderer+Fullscreen.m native/app/Canvas/DWCanvasRenderer+Families.m native/app/Canvas/DWCanvasRenderer+Lifecycle.m native/app/Canvas/DWCanvasRenderer+GeometryTransitions.m native/app/Canvas/DWCanvasRenderer+Screenshot.m native/app/Canvas/DWCanvasAttachment.m native/app/System/DWScreenshotWriter.m native/app/Canvas/DWFrameDriver.m native/app/Canvas/IFCDeviceResources.m native/app/Canvas/IFCompositorFrame.m native/app/Canvas/DWCompositorRasterizers.m native/app/Canvas/IFCompositorRenderer.m native/app/Canvas/IFCompositorRenderer+Draw.m native/app/Canvas/IFCompositorRenderer+Blur.m native/app/Canvas/IFCompositorLayer.m native/app/Canvas/IFBackgroundProgram.m native/app/Canvas/IFBGDeviceResources.m native/app/Canvas/DWBackgroundGLSLTranslation.m native/app/Canvas/DWBackgroundFiles.m native/app/Canvas/IFBGChunk.m native/app/Canvas/IFBGShaderChunks.m native/app/Canvas/IFBGTileChunks.m native/app/Canvas/DWMacWallpaperCache.m native/app/Canvas/IFBGTiffSource.m native/app/Canvas/IFBGShaderDecl.m native/app/System/DWLoginItem.m native/app/System/DWOnboarding.m native/app/System/DWSystemTakeover.m native/app/System/DWSessionWatch.m native/app/System/DWNativeDesktopCLI.m native/app/System/DWLoaderService.m native/app/System/DWDockReloader.m native/dock-helper/Daemon/DWLoaddRequest.m native/app/Navigation/DWNativeResize.m target/release/libdriftwm_desktop.a \
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
