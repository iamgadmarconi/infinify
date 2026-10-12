#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Checkout-aware source-freshness wrapper for the signed, bundled launcher.
set +x
set -eu

native_root=$(CDPATH= cd -P "$(dirname "$0")/.." && pwd -P)
native_mode=launch
native_build=false
native_bundle="$native_root/target/app/Infinify.app"
native_app_explicit=false

fail() { printf 'Infinify native desktop: %s\n' "$*" >&2; exit 1; }
usage() {
  printf '%s\n' 'usage: scripts/start-native-desktop.sh [--build | --check] [--app /absolute/path/Infinify.app]'
  printf '%s\n' 'Default: verify current source freshness, then execute the selected signed app bundle launcher.'
  printf '%s\n' '--build: rebuild production artifacts and the app before checking freshness.'
  printf '%s\n' '--check: read-only bundle and policy check; no sudo, runtime creation or app launch.'
  printf '%s\n' '--app: select an exact installed or otherwise delivered Infinify.app bundle.'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --build)
      [ "$native_build" = false ] || { usage >&2; exit 64; }
      native_build=true
      ;;
    --check)
      [ "$native_mode" = launch ] || { usage >&2; exit 64; }
      native_mode=check
      ;;
    --app)
      [ "$native_app_explicit" = false ] && [ $# -ge 2 ] || { usage >&2; exit 64; }
      shift
      case "$1" in /*) ;; *) fail '--app requires an absolute bundle path.' ;; esac
      native_bundle=$1
      native_app_explicit=true
      ;;
    --help)
      usage
      exit 0
      ;;
    *) usage >&2; exit 64 ;;
  esac
  shift
done
[ "$native_build" = false ] || [ "$native_mode" != check ] || { usage >&2; exit 64; }

if [ "$native_build" = true ]; then
  "$native_root/scripts/build-app.sh"
fi

[ -d "$native_bundle" ] && [ ! -L "$native_bundle" ] || fail "selected app bundle is missing or is a symlink: $native_bundle"
native_bundle=$(CDPATH= cd -P "$native_bundle" && pwd -P) || fail 'could not resolve the selected app bundle.'
[ "${native_bundle##*/}" = Infinify.app ] || fail 'selected bundle must be named Infinify.app.'
native_launcher="$native_bundle/Contents/Resources/NativeDesktop/launch.sh"
[ -f "$native_launcher" ] && [ -x "$native_launcher" ] && [ ! -L "$native_launcher" ] || fail 'selected app has no executable bundled native launcher.'

# This wrapper is intentionally checkout-aware. The bundled launcher validates
# signed bytes and can run without Python or the source tree; this command also
# binds the chosen installed bundle to the current repository build record.
python3 "$native_root/scripts/build-app-package.py" verify-source \
  --root "$native_root" \
  --bundle "$native_bundle" || fail 'the selected app is stale or does not match the current build; rebuild before launching it.'

if [ "$native_mode" = check ]; then
  exec "$native_launcher" --check
fi
exec "$native_launcher"
