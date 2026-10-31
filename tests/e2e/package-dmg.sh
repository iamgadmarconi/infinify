#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Packs a small ad hoc signed fixture app with scripts/package-dmg.sh and checks the image from the outside: compressed
# read-only format, the exact bundle and an Applications link inside, an existing output and a bundle whose signature no
# longer verifies both refused with no image left. Mounts only its own images, hidden from Finder; writes only a scratch
# directory.
set -eu
cd "$(dirname "$0")/../.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/infinify-package-dmg.XXXXXX")
mounted=false
cleanup() {
  if [ "$mounted" = true ]; then diskutil unmount force "$task_dir/mount" >/dev/null 2>&1 || true; fi
  rm -rf "$task_dir"
}
trap cleanup EXIT HUP INT TERM
fail() { printf 'package-dmg: %s\n' "$*" >&2; exit 1; }

app=$task_dir/Fixture.app
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$task_dir/out"
printf 'int main(void) { return 0; }\n' | xcrun clang -arch arm64 -mmacosx-version-min=26.0 -x c - -o "$app/Contents/MacOS/Fixture"
cat > "$app/Contents/Info.plist" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Fixture</string>
<key>CFBundleIdentifier</key><string>com.marengox.infinify.package-dmg-fixture</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
EOF
printf 'resource\n' > "$app/Contents/Resources/resource.txt"
codesign --force --sign - "$app" 2>/dev/null

dmg=$task_dir/out/Fixture.dmg
./scripts/package-dmg.sh "$app" "$dmg" >/dev/null
[ -f "$dmg" ] || fail 'no image was written'
[ ! -e "$dmg.partial.dmg" ] || fail 'a partial image was left behind'
printf '%s\n' 'ok - packs the fixture app'

format=$(diskutil image info --plist "$dmg" | plutil -extract 'Image Format' raw -)
[ "$format" = ULFO ] || fail "the image format is $format, not ULFO"
printf '%s\n' 'ok - compressed read-only image (ULFO)'

mounted=true
diskutil image attach --readOnly --nobrowse --mountPoint "$task_dir/mount" "$dmg" >/dev/null
[ "$(ls "$task_dir/mount" | sort | tr '\n' ' ')" = 'Applications Fixture.app ' ] || fail "unexpected contents: $(ls -A "$task_dir/mount")"
[ "$(readlink "$task_dir/mount/Applications")" = /Applications ] || fail 'Applications is not a link to /Applications'
diff -rq "$app" "$task_dir/mount/Fixture.app" >/dev/null || fail 'the bundle in the image differs from the source'
codesign --verify --deep --strict "$task_dir/mount/Fixture.app" || fail 'the bundle in the image does not verify'
diskutil eject "$task_dir/mount" >/dev/null
mounted=false
printf '%s\n' 'ok - the image holds the exact signed bundle and an Applications link'

if ./scripts/package-dmg.sh "$app" "$dmg" >/dev/null 2>&1; then fail 'an existing image was overwritten'; fi
printf '%s\n' 'ok - refuses an existing image'

printf 'changed after signing\n' > "$app/Contents/Resources/resource.txt"
if ./scripts/package-dmg.sh "$app" "$task_dir/out/Broken.dmg" >/dev/null 2>&1; then fail 'packed a bundle whose signature does not verify'; fi
[ ! -e "$task_dir/out/Broken.dmg" ] && [ ! -e "$task_dir/out/Broken.dmg.partial.dmg" ] || fail 'a refused bundle left an image behind'
printf '%s\n' 'ok - refuses a bundle whose signature does not verify, leaving no image'
printf '%s\n' 'package-dmg: PASS'
