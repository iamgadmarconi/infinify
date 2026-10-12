#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Owner-run full-desktop launcher. Source/build work must never execute this.
# No Dock restart, settings change, automatic injection retry or runtime cleanup.
set +x
set -eu
umask 077
cd "$(dirname "$0")/.."
native_repo=$(pwd -P)
native_mode=launch
native_uid=$(id -u)

fail() { printf 'Infinify native desktop: %s\n' "$*" >&2; exit 1; }
usage() {
  printf '%s\n' 'usage: scripts/start-native-desktop.sh [--build | --check]'
  printf '%s\n' 'Default: use the delivered production artifacts, check policy, reuse or explicitly load one desktop helper, then start the standard app as the login user.'
  printf '%s\n' '--build: rebuild production artifacts after policy preflight (no fixture builds).'
  printf '%s\n' '--check: read-only doctor report only; no sudo, runtime creation or app launch.'
}
if [ $# -gt 1 ]; then usage >&2; exit 64; fi
if [ $# -eq 1 ]; then
  case "$1" in
    --build) native_mode=build ;;
    --check) native_mode=check ;;
    --help) usage; exit 0 ;;
    *) usage >&2; exit 64 ;;
  esac
fi
[ "$native_uid" != 0 ] || fail 'run this script as the login user, never with sudo; only its explicit loader step uses sudo.'
[ "$(uname -s)" = Darwin ] && [ "$(uname -m)" = arm64 ] || fail 'Apple Silicon macOS 26 or later is required.'
native_version=$(/usr/bin/sw_vers -productVersion)
native_major=${native_version%%.*}
case "$native_major" in ''|*[!0-9]*) fail 'could not identify the macOS version.' ;; esac
[ "$native_major" -ge 26 ] || fail 'macOS 26 or later is required.'
native_artifacts="$native_repo/target/privileged"
native_doctor="$native_artifacts/doctor"
native_loader="$native_artifacts/loader-arm64e"
native_payload="$native_artifacts/payload-arm64e.dylib"
native_bundle="$native_repo/target/app/Infinify.app"
native_app="$native_bundle/Contents/MacOS/Infinify"

# A missing doctor can only be built under the explicit --build choice. --check
# and the normal delivered-artifact path remain read-only until preflight passes.
if [ "$native_mode" = build ]; then ./scripts/build-privileged.sh --doctor-only; fi
[ -x "$native_doctor" ] || fail 'doctor is missing; use --build to prepare it, or build-privileged.sh --doctor-only.'
native_report=$("$native_doctor") || fail 'doctor failed; no helper was loaded.'
printf '%s\n' "$native_report"
native_preflight=$(printf '%s\n' "$native_report" | /usr/bin/plutil -extract injection_preflight_passed raw -expect bool -o - -) || fail 'doctor returned an invalid policy report.'
[ "$native_preflight" = true ] || fail 'current SIP/arm64e boot policy does not pass preflight; nothing was loaded and no settings were changed.'
[ "$native_mode" != check ] || exit 0

if [ "$native_mode" = build ]; then
  ./scripts/build-privileged.sh --production
  ./scripts/build-app.sh
fi
[ -x "$native_loader" ] && [ -f "$native_payload" ] && [ -x "$native_app" ] || fail 'production artifacts are incomplete; use --build after reviewing its build/signing behavior.'
for native_source in native/privileged/loader.m native/privileged/preflight.h native/privileged/dwclient.c native/privileged/dwclient.h native/privileged/protocol2.h; do
  [ ! "$native_source" -nt "$native_loader" ] || fail 'the loader is older than its sources; use --build or build-privileged.sh --production.'
done
for native_source in native/privileged/payload.m native/privileged/payload-v2.m native/privileged/protocol.h native/privileged/protocol2.h; do
  [ ! "$native_source" -nt "$native_payload" ] || fail 'the payload is older than its sources; use --build or build-privileged.sh --production.'
done
/usr/bin/codesign --verify --strict "$native_loader" || fail 'loader signature verification failed.'
/usr/bin/codesign --verify --strict "$native_payload" || fail 'payload signature verification failed.'
/usr/bin/codesign --verify --strict "$native_bundle" || fail 'standard app signature verification failed.'
# Validate the delivered signed bytes and the complete current source snapshot.
# This freshness check is read-only and happens before sudo or runtime creation.
python3 - "$native_repo" "$native_repo/target/app/BUILD.json" "$native_app" <<'PYTHON' || fail 'the delivered app does not match its build manifest and current sources; rebuild with scripts/build-app.sh or --build before launching.'
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import sys

sys.dont_write_bytecode = True
os.environ['GIT_OPTIONAL_LOCKS'] = '0'
try:
    root, manifest_path, executable = map(Path, sys.argv[1:])
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise ValueError('BUILD.json is missing or is not a regular file')
    manifest = json.loads(manifest_path.read_text(encoding='utf-8'))
    if type(manifest.get('schema_version')) is not int or manifest['schema_version'] != 1:
        raise ValueError('unsupported BUILD.json schema')
    if manifest.get('executable') != 'Infinify.app/Contents/MacOS/Infinify':
        raise ValueError('unexpected executable path in BUILD.json')
    if manifest.get('executable_sha256') != hashlib.sha256(executable.read_bytes()).hexdigest():
        raise ValueError('signed executable bytes differ from BUILD.json')
    spec = importlib.util.spec_from_file_location('infinify_build_package', root / 'scripts/build-app-package.py')
    package = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(package)
    current = package.source_state(root)
    if manifest.get('git_commit') != current['commit']:
        raise ValueError('BUILD.json does not describe the current Git HEAD')
    if manifest.get('source_fingerprint_sha256') != current['source_fingerprint_sha256']:
        raise ValueError('tracked or nonignored source files changed after the app was built')
except Exception as error:
    print(f'Infinify app freshness: {error}', file=sys.stderr)
    sys.exit(1)
PYTHON
if /usr/bin/pgrep -u "$native_uid" -x Infinify >/dev/null; then
  fail 'an Infinify instance is already running; quit it normally before starting native desktop mode.'
else
  native_lookup_status=$?
  [ "$native_lookup_status" -eq 1 ] || fail 'could not determine whether Infinify is already running.'
fi

# The loader's read-only identity query and its later expected-Dock check use the
# same exact libproc process birth fields. A PID alone must never authorize reuse.
native_dock=$("$native_loader" --dock-identity) || fail 'could not resolve the current Dock process identity.'
dock_value() { printf '%s\n' "$native_dock" | /usr/bin/plutil -extract "$1" raw -expect integer -o - -; }
native_dock_pid=$(dock_value pid) || fail 'invalid Dock PID report.'
native_dock_sec=$(dock_value birth_sec) || fail 'invalid Dock birth report.'
native_dock_usec=$(dock_value birth_usec) || fail 'invalid Dock birth report.'
native_dock_uid=$(dock_value uid) || fail 'invalid Dock user report.'
[ "$native_dock_uid" = "$native_uid" ] || fail 'Dock belongs to another login user.'

native_state_dir="$HOME/Library/Application Support/Infinify/native-desktop"
native_record="$native_state_dir/launch.plist"
native_lock="$native_state_dir/launch.lock"
[ ! -L "$native_state_dir" ] || fail 'the launch-state directory must not be a symlink.'
mkdir -p "$native_state_dir"
[ -d "$native_state_dir" ] && [ "$(/usr/bin/stat -f '%u:%Lp' "$native_state_dir")" = "$native_uid:700" ] || fail 'launch-state directory must be owned by this login user with mode 0700.'
mkdir "$native_lock" 2>/dev/null || fail 'another launch or interrupted launch lock exists; inspect it before retrying.'
# Only this invocation's empty lock is removed. Runtimes, nonce files, payload
# sidecars and recovery journals are never deleted, even after an early failure.
release_lock() { rmdir "$native_lock" 2>/dev/null || :; }
trap release_lock EXIT
trap 'exit 130' INT
trap 'exit 129' HUP
trap 'exit 143' TERM
record_value() { /usr/bin/plutil -extract "$1" raw -expect "$2" -o - "$native_record"; }
private_file() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(/usr/bin/stat -f '%u:%Lp' "$1")" = "$native_uid:600" ]; }

if [ -e "$native_record" ] || [ -L "$native_record" ]; then
  private_file "$native_record" || fail 'the existing launch record is not a private regular file; inspect it before retrying.'
  [ "$(record_value version integer)" = 1 ] || fail 'unknown launch-record format; inspect it before retrying.'
  native_outcome=$(record_value outcome string) || fail 'invalid launch-record outcome; inspect it before retrying.'
  [ "$native_outcome" = ready ] || fail 'a prior injection outcome is pending or unknown; retain its runtime and inspect it, do not inject again.'
  [ "$(record_value dock_pid integer)" = "$native_dock_pid" ] && [ "$(record_value dock_birth_sec integer)" = "$native_dock_sec" ] && [ "$(record_value dock_birth_usec integer)" = "$native_dock_usec" ] || fail 'Dock changed since the recorded session; inspect and preserve the old runtime/recovery state before preparing another session.'
  native_runtime=$(record_value runtime string) || fail 'invalid recorded runtime path.'
  native_nonce_file=$(record_value nonce_file string) || fail 'invalid recorded nonce-file path.'
  case "$native_runtime" in /tmp/if-native.*) ;; *) fail 'invalid recorded private runtime path.' ;; esac
  [ "$native_nonce_file" = "$native_runtime/nonce" ] || fail 'recorded nonce file does not belong to its runtime.'
  [ -d "$native_runtime" ] && [ ! -L "$native_runtime" ] && [ "$(/usr/bin/stat -f '%u:%Lp' "$native_runtime")" = "$native_uid:700" ] || fail 'recorded runtime is missing or no longer private; do not inject again.'
  private_file "$native_nonce_file" || fail 'recorded nonce file is missing or no longer private; do not inject again.'
  printf '%s\n' 'Reusing the recorded same-Dock desktop helper; the app will authenticate its scope and restoration capabilities.'
else
  [ -t 0 ] || fail 'start this owner-run launcher in a terminal for the explicit sudo loader step.'
  native_runtime=$(/usr/bin/mktemp -d /tmp/if-native.XXXXXX)
  native_nonce_file="$native_runtime/nonce"
  /usr/bin/openssl rand -hex 32 > "$native_nonce_file"
  private_file "$native_nonce_file" || fail 'could not create a private nonce file.'
  /bin/cp "$native_payload" "$native_runtime/payload-arm64e.dylib"
  /usr/bin/codesign --verify --strict "$native_runtime/payload-arm64e.dylib" || fail 'copied payload signature verification failed.'
  write_record() {
    native_record_tmp=$(/usr/bin/mktemp "$native_state_dir/.launch.XXXXXX")
    cat > "$native_record_tmp" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict/></plist>
PLIST
    /usr/bin/plutil -insert version -integer 1 "$native_record_tmp"
    /usr/bin/plutil -insert dock_pid -integer "$native_dock_pid" "$native_record_tmp"
    /usr/bin/plutil -insert dock_birth_sec -integer "$native_dock_sec" "$native_record_tmp"
    /usr/bin/plutil -insert dock_birth_usec -integer "$native_dock_usec" "$native_record_tmp"
    /usr/bin/plutil -insert runtime -string "$native_runtime" "$native_record_tmp"
    /usr/bin/plutil -insert nonce_file -string "$native_nonce_file" "$native_record_tmp"
    /usr/bin/plutil -insert outcome -string "$1" "$native_record_tmp"
    /bin/mv "$native_record_tmp" "$native_record"
  }
  # Save ambiguity BEFORE sudo can execute remote code. A signal, failed loader
  # or uncertain bootstrap leaves pending on disk and forbids blind reinjection.
  write_record pending
  printf '%s\n' 'Starting the explicitly selected full-desktop SAME_USER helper, including newly opened applications. Only the loader runs with sudo.'
  if ! /usr/bin/sudo "$native_loader" --inject-dock "$native_runtime/payload-arm64e.dylib" "$native_runtime" --nonce-file "$native_nonce_file" --desktop --expected-dock "$native_dock_pid" "$native_dock_sec" "$native_dock_usec"; then
    fail "loader did not establish readiness; retained pending record at $native_record and runtime at $native_runtime. Inspect before any retry."
  fi
  write_record ready
fi
[ "$(id -u)" = "$native_uid" ] && [ "$native_uid" != 0 ] || fail 'refusing to run the app as root or another user.'
release_lock
trap - EXIT INT HUP TERM
exec "$native_app" --native-desktop-helper "$native_runtime" "$native_nonce_file"
