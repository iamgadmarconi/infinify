#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Packs an app bundle into a compressed, read-only disk image beside an Applications link, copying the bundle's exact
# bytes, then mounts the image read-only and checks the copy inside it: its signature verifies and every file equals the
# source bundle's. The image appears at OUT only once every check has passed.
#   scripts/package-dmg.sh APP OUT.dmg [--sign IDENTITY] [--validate-native]
# --sign signs the image itself with that identity, timestamped, as notarization requires; without it the image is unsigned.
# --validate-native also runs scripts/build-app-package.py validate-bundle on the mounted copy (for Infinify.app).
# It mounts only its own image, at a private mount point hidden from Finder, and ejects it on every exit. It uses
# `diskutil image` (macOS 27 deprecates the hdiutil verbs it replaces); the image holds an APFS volume.
set -eu
usage='usage: scripts/package-dmg.sh APP OUT.dmg [--sign IDENTITY] [--validate-native]'
fail() { printf 'package-dmg: %s\n' "$*" >&2; exit 1; }
[ $# -ge 2 ] || { printf '%s\n' "$usage" >&2; exit 64; }
app=$1 out=$2
shift 2
identity= validate_native=false
while [ $# -gt 0 ]; do
  case "$1" in
    --sign) [ $# -ge 2 ] && [ -n "$2" ] || { printf '%s\n' "$usage" >&2; exit 64; }; identity=$2; shift ;;
    --validate-native) validate_native=true ;;
    *) printf '%s\n' "$usage" >&2; exit 64 ;;
  esac
  shift
done
package=$(CDPATH='' cd -P "$(dirname "$0")" && pwd -P)/build-app-package.py
case "$app" in *.app) ;; *) fail "not an app bundle: $app" ;; esac
[ -d "$app" ] && [ ! -L "$app" ] || fail "no app bundle at $app"
case "$out" in *.dmg) ;; *) fail "the image must be named .dmg: $out" ;; esac
[ ! -e "$out" ] || fail "$out exists; remove it first"
out_dir=$(dirname "$out")
[ -d "$out_dir" ] || fail "no directory $out_dir"
name=$(basename "$app" .app)
diskutil image >/dev/null 2>&1 || fail 'this macOS has no `diskutil image`; build the image on a Mac that has it'

stage=$(mktemp -d "${TMPDIR:-/tmp}/package-dmg.XXXXXX")
mounted=false
cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  if [ "$mounted" = true ]; then diskutil eject "$stage/mount" >/dev/null 2>&1 || diskutil unmount force "$stage/mount" >/dev/null 2>&1 || true; fi
  rm -rf "$stage"
  rm -f "$out.partial.dmg"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

/usr/bin/codesign --verify --deep --strict "$app" || fail "the bundle's signature does not verify: $app"
mkdir "$stage/root"
ditto "$app" "$stage/root/$name.app"
ln -s /Applications "$stage/root/Applications"
# diskutil prints its progress on stderr; it is shown only if the image cannot be made.
if ! progress=$(diskutil image create from --format ULFO --volumeName "$name" "$stage/root" "$out.partial.dmg" 2>&1 >/dev/null); then
  printf '%s\n' "$progress" >&2
  fail 'diskutil could not make the image'
fi
[ -z "$identity" ] || /usr/bin/codesign --sign "$identity" --timestamp "$out.partial.dmg"
hdiutil verify -quiet "$out.partial.dmg" || fail 'the image does not verify'

# diskutil creates the mount point and removes it again on eject.
mounted=true
diskutil image attach --readOnly --nobrowse --mountPoint "$stage/mount" "$out.partial.dmg" >/dev/null
copy=$stage/mount/$name.app
[ -L "$stage/mount/Applications" ] && [ "$(readlink "$stage/mount/Applications")" = /Applications ] \
  || fail 'the image has no Applications link'
/usr/bin/codesign --verify --deep --strict "$copy" || fail "the bundle in the image does not verify"
diff -rq "$app" "$copy" >/dev/null || fail "the bundle in the image differs from $app"
[ "$validate_native" = false ] || python3 -I "$package" validate-bundle --bundle "$copy" >/dev/null
diskutil eject "$stage/mount" >/dev/null
mounted=false

mv "$out.partial.dmg" "$out"
printf 'Packed %s into %s (%s)\n' "$app" "$out" "$([ -n "$identity" ] && printf 'image signed' || printf 'image unsigned')"
