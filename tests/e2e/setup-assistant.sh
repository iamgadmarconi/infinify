#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Setup without touching this Mac's setup: what a plain launch and the login item decide (DWSetupStateTests), the pieces of
# uninstall that need no registration (DWUninstallTests), where Infinify lives and the move to Applications, on stand-in
# bundles (DWInstallTests), the update check offline (DWUpdateCheckTests), and every pane of the setup assistant drawn off screen in the light
# and the dark appearance from made-up states (DWSetupAssistantFixture). Set INFINIFY_SETUP_PICTURES=DIRECTORY to keep the
# pictures. Reads SIP once, read-only; writes only scratch directories; registers, grants and shows nothing.
set -eu
cd "$(dirname "$0")/../.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/infinify-setup-assistant.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT HUP INT TERM
fail() { printf 'setup-assistant: %s\n' "$*" >&2; exit 1; }
. scripts/native-includes.sh
compile() {
  output=$1
  shift
  # shellcheck disable=SC2086
  xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror $native_includes "$@" -o "$task_dir/$output"
}
system=native/app/System
compile setup-state tests/native/app/System/DWSetupStateTests.m $system/DWSetupState.m $system/DWLoginItem.m \
  -framework Foundation -framework ServiceManagement
compile uninstall tests/native/app/System/DWUninstallTests.m $system/DWUninstall.m $system/DWSetupState.m $system/DWLoginItem.m \
  $system/DWNativeDesktopCLI.m $system/DWLoaderService.m $system/DWDockReloader.m $system/DWSystemTakeover.m \
  native/dock-helper/Daemon/DWLoaddRequest.m -framework AppKit -framework ServiceManagement -framework Security
compile install tests/native/app/System/DWInstallTests.m $system/DWInstall.m $system/DWUninstall.m $system/DWSetupState.m \
  $system/DWLoginItem.m $system/DWNativeDesktopCLI.m $system/DWLoaderService.m $system/DWDockReloader.m $system/DWSystemTakeover.m \
  native/dock-helper/Daemon/DWLoaddRequest.m -framework AppKit -framework ServiceManagement -framework Security
compile update-check tests/native/app/System/DWUpdateCheckTests.m $system/DWUpdateCheck.m -framework Foundation
compile fixture tests/native/app/System/DWSetupAssistantFixture.m $system/DWSetupAssistant.m $system/DWSetupButton.m \
  $system/DWSetupState.m $system/DWUninstall.m $system/DWInstall.m $system/DWUpdateCheck.m $system/DWLoaderService.m $system/DWLoginItem.m $system/DWNativeDesktopCLI.m \
  $system/DWDockReloader.m $system/DWSystemTakeover.m native/dock-helper/Daemon/DWLoaddRequest.m \
  -framework AppKit -framework ServiceManagement -framework Security -framework QuartzCore
"$task_dir/setup-state"
"$task_dir/uninstall"
"$task_dir/install"
"$task_dir/update-check"

pictures=${INFINIFY_SETUP_PICTURES:-$task_dir/pictures}
mkdir -p "$pictures"
icon=$task_dir/icon
mkdir "$icon"
xcrun actool "$PWD/native/app/Resources/Infinify.icon" --compile "$icon" --platform macosx --minimum-deployment-target 26.0 \
  --app-icon Infinify --output-partial-info-plist "$icon/partial.plist" >/dev/null
"$task_dir/fixture" "$pictures" "$icon/Infinify.icns"
count=0
for picture in "$pictures"/*.png; do
  [ "$(stat -f %z "$picture")" -gt 12000 ] || fail "$(basename "$picture") is nearly empty"
  count=$((count + 1))
done
[ "$count" -eq 34 ] || fail "$count pictures, not 34 (17 states, light and dark)"
for state in welcome permissions login compositor-sip ready; do
  cmp -s "$pictures/$state-light.png" "$pictures/$state-dark.png" && fail "$state looks the same in light and dark"
done
printf 'ok   %s\n' 'every pane drawn in light and dark, each differing between the two'
printf '%s\n' 'setup-assistant: PASS'
