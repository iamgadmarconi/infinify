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

if [ "${INFINIFY_NATIVE_CLEAN:-0}" = 1 ]; then
  python3 scripts/native-modules.py clean
fi
./scripts/build-privileged.sh --production --output-dir "$stage/privileged"
cargo build -p driftwm-desktop --release

# Link every production native module with all objects retained. Source lists,
# dependency visibility, flags and incremental objects come from one description.
python3 scripts/native-modules.py build app --output "$app/Contents/MacOS/Infinify"

# The app icon's Icon Composer source: actool writes Assets.car and Infinify.icns, which CFBundleIconName and
# CFBundleIconFile in Info.plist name. Compiled on every build and never committed; actool needs absolute paths.
xcrun actool "$root/native/app/Resources/Infinify.icon" --compile "$app/Contents/Resources" --platform macosx \
  --minimum-deployment-target 26.0 --app-icon Infinify --output-partial-info-plist "$stage/icon.plist" >/dev/null
if [ ! -f "$app/Contents/Resources/Assets.car" ] || [ ! -f "$app/Contents/Resources/Infinify.icns" ]; then
  printf '%s\n' 'actool did not produce Assets.car and Infinify.icns.' >&2
  exit 1
fi

python3 scripts/build-app-package.py publish \
  --root "$root" \
  --snapshot "$stage/source-before.json" \
  --staged-app "$app" \
  --privileged-dir "$stage/privileged" \
  --app-dir "$app_dir"

printf '%s\n' "Built $app_dir/Infinify.app (arm64, macOS 26+); nothing launched. scripts/install-app.sh installs it as /Applications/Infinify.app."
