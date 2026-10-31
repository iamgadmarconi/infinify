#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Compiles the app icon's Icon Composer source exactly as scripts/build-app.sh does, into a scratch directory, and checks
# that actool writes Assets.car and Infinify.icns, that the Info.plist keys it reports are the ones the bundle's
# Info.plist carries, and that the catalogue holds the light, dark and tintable appearances. Reads and writes nothing else.
set -eu
cd "$(dirname "$0")/../.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
root=$(pwd -P)
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/infinify-app-icon.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT HUP INT TERM
fail() { printf 'app-icon: %s\n' "$*" >&2; exit 1; }

mkdir "$task_dir/Resources"
xcrun actool "$root/native/app/Resources/Infinify.icon" --compile "$task_dir/Resources" --platform macosx \
  --minimum-deployment-target 26.0 --app-icon Infinify --output-partial-info-plist "$task_dir/icon.plist" >/dev/null
[ -f "$task_dir/Resources/Assets.car" ] || fail 'actool wrote no Assets.car'
[ -f "$task_dir/Resources/Infinify.icns" ] || fail 'actool wrote no Infinify.icns'
printf '%s\n' 'ok - actool writes Assets.car and Infinify.icns'

for key in CFBundleIconFile CFBundleIconName; do
  reported=$(/usr/libexec/PlistBuddy -c "Print :$key" "$task_dir/icon.plist") || fail "actool reported no $key"
  carried=$(/usr/libexec/PlistBuddy -c "Print :$key" native/app/Resources/Info.plist) || fail "Info.plist has no $key"
  [ "$reported" = "$carried" ] || fail "$key: actool reports $reported, Info.plist carries $carried"
  printf 'ok - %s is %s in both\n' "$key" "$carried"
done

xcrun assetutil --info "$task_dir/Resources/Assets.car" > "$task_dir/info.json"
python3 -I - "$task_dir/info.json" <<'EOF'
import json, sys
entries = json.load(open(sys.argv[1]))
stacks = {e.get("Appearance") for e in entries if e.get("AssetType") == "IconImageStack" and e.get("Name") == "Infinify"}
for appearance in ("NSAppearanceNameAqua", "NSAppearanceNameDarkAqua", "ISAppearanceTintable"):
    if appearance not in stacks:
        sys.exit(f"app-icon: no {appearance} icon stack in Assets.car (found {sorted(a for a in stacks if a)})")
    print(f"ok - {appearance} icon stack")
if not any(e.get("AssetType") == "Vector" and e.get("Name") == "Infinify_Assets/window" for e in entries):
    sys.exit("app-icon: the window layer is not in Assets.car")
print("ok - window layer")
EOF
printf '%s\n' 'app-icon: PASS'
