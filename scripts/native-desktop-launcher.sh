#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Bundled, checkout-independent integrity preflight for the full desktop helper: the owner in a terminal, the login item
# (--login), and the running app after a Dock restart (--reload) all pass through these same checks.
# The signed app owns lifecycle policy after this wrapper verifies the bundle and its artifacts.
# Nothing security-relevant about the bundle or artifacts is handed through arguments or environment.
# Only the mode and inherited reload descriptor cross the handoff.
set +x
set -eu
umask 077

native_mode=launch
native_usage='usage: Infinify.app/Contents/Resources/NativeDesktop/launch.sh [--check]'
if [ $# -gt 1 ]; then
  printf '%s\n' "$native_usage" >&2
  exit 64
fi
if [ $# -eq 1 ]; then
  case "$1" in
    --check) native_mode=check ;;
    --login) native_mode=login ;;
    --reload) native_mode=reload ;;
    --help)
      printf '%s\n' "$native_usage"
      printf '%s\n' '--check: verify the signed bundle and read-only policy report; no sudo, runtime creation or app launch.'
      printf '%s\n' '--login: the login item of an enabled compositor mode (Infinify native-desktop enable): no terminal; the launch daemon loads.'
      printf '%s\n' '--reload: for the running app after a Dock restart: the same recovery-aware load through the launch daemon; prints the new endpoint.'
      exit 0
      ;;
    *) printf '%s\n' "$native_usage" >&2; exit 64 ;;
  esac
fi

# A refusal ends a login start quietly (status 0): launchd restarts a failed login item, and a refusal here is a decision
# the owner has to look at (the log, `Infinify native-desktop status`), not something a restart fixes.
native_fail_status=1
[ "$native_mode" != login ] || native_fail_status=0
# With no terminal to read a refusal (a login start, or a start by hand from the setup assistant, which sets
# INFINIFY_LAUNCH_FROM_SETUP), the app's setup assistant says it instead and offers to try again or the demo
# (`Infinify setup --refused REASON`). Only once the app bundle's signature has been verified below; never for --check or
# --reload, and the variable goes no further than this launcher, so the app and its own reloads never see it.
native_setup_feedback=false
if [ "$native_mode" = login ] || { [ "$native_mode" = launch ] && [ "${INFINIFY_LAUNCH_FROM_SETUP:-}" = 1 ]; }; then native_setup_feedback=true; fi
unset INFINIFY_LAUNCH_FROM_SETUP
native_app_verified=false
native_lock_held=false
fail() {
  printf 'Infinify native desktop: %s\n' "$*" >&2
  if [ "$native_setup_feedback" = true ] && [ "$native_app_verified" = true ]; then
    # exec skips the EXIT trap, so the launch lock this run took (and only that one) is released first.
    if [ "$native_lock_held" = true ]; then /bin/rmdir "$native_lock" 2>/dev/null || :; fi
    exec "$native_app" setup --refused "$*"
  fi
  exit "$native_fail_status"
}
# The reload's stdout is the app's to read: the one endpoint line goes to descriptor 3, everything else to stderr.
if [ "$native_mode" = reload ]; then exec 3>&1 1>&2; fi
native_state_dir="$HOME/Library/Application Support/Infinify/native-desktop"
if [ "$native_mode" = login ]; then
  # No terminal: what the launcher says goes to a log in the state directory, which `status` points to.
  [ ! -L "$native_state_dir" ] || fail 'the launch-state directory must not be a symlink.'
  /bin/mkdir -p "$native_state_dir" && /bin/chmod 700 "$native_state_dir" || fail 'could not prepare the launch-state directory.'
  native_log="$native_state_dir/login.log"
  if [ -f "$native_log" ] && [ "$(/usr/bin/stat -f '%z' "$native_log")" -gt 262144 ]; then /bin/mv -f "$native_log" "$native_log.1"; fi
  exec >> "$native_log" 2>&1
  printf '%s login start\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')"
fi
native_dir=$(CDPATH='' cd -P "$(dirname "$0")" && pwd -P) || fail 'could not resolve the bundled native helper directory.'
native_bundle=$(CDPATH='' cd -P "$native_dir/../../.." && pwd -P) || fail 'could not resolve the containing app bundle.'
native_name=${native_bundle##*/}
[ "$native_name" = Infinify.app ] || fail 'the bundled launcher must run from Infinify.app.'
[ "$native_dir" = "$native_bundle/Contents/Resources/NativeDesktop" ] || fail 'native helper path resolves outside the containing app bundle.'
for native_component in "$native_bundle/Contents" "$native_bundle/Contents/Resources" "$native_bundle/Contents/Resources/NativeDesktop" "$native_bundle/Contents/MacOS"; do
  [ ! -L "$native_component" ] || fail "app bundle path component is a symlink: $native_component"
done
native_manifest="$native_dir/manifest.plist"
native_launcher="$native_dir/launch.sh"
native_doctor="$native_dir/doctor"
native_loader="$native_dir/loader-arm64e"
native_daemon="$native_dir/loadd"
native_payload="$native_dir/payload-arm64e.dylib"
native_app="$native_bundle/Contents/MacOS/Infinify"
native_info="$native_bundle/Contents/Info.plist"

native_regular_file() { [ -f "$1" ] && [ ! -L "$1" ]; }
native_digest() { /usr/bin/shasum -a 256 "$1" | /usr/bin/awk '{print $1}'; }
native_manifest_value() { /usr/bin/plutil -extract "$1" raw -expect "$2" -o - "$native_manifest"; }
native_valid_hash() {
  [ "${#1}" -eq 64 ] || return 1
  case "$1" in *[!0-9a-f]*|'') return 1 ;; esac
  return 0
}
native_regular_file "$native_launcher" || fail 'bundled launcher is missing or is a symlink.'
native_regular_file "$native_manifest" || fail 'native helper manifest is missing or is a symlink.'
native_regular_file "$native_doctor" || fail 'bundled doctor is missing or is a symlink.'
native_regular_file "$native_loader" || fail 'bundled loader is missing or is a symlink.'
native_regular_file "$native_daemon" || fail 'bundled launch daemon is missing or is a symlink.'
native_regular_file "$native_payload" || fail 'bundled payload is missing or is a symlink.'
native_regular_file "$native_app" || fail 'standard app executable is missing or is a symlink.'
native_regular_file "$native_info" || fail 'app Info.plist is missing or is a symlink.'
/usr/bin/plutil -lint "$native_manifest" >/dev/null || fail 'native helper manifest is invalid.'
[ "$(/usr/bin/plutil -extract schema_version raw -expect integer -o - "$native_manifest")" = 1 ] || fail 'unsupported native helper manifest schema.'
native_source_fingerprint=$(native_manifest_value source_fingerprint_sha256 string) || fail 'native helper manifest has no source fingerprint.'
native_valid_hash "$native_source_fingerprint" || fail 'native helper manifest has an invalid source fingerprint.'
[ "$(/usr/bin/plutil -extract git_commit raw -expect string -o - "$native_manifest")" != '' ] || fail 'native helper manifest has no source commit.'
[ "$(/usr/bin/plutil -extract CFBundleIdentifier raw -expect string -o - "$native_info")" = com.marengox.infinify ] || fail 'unexpected app bundle identifier.'
[ "$(/usr/bin/plutil -extract CFBundleExecutable raw -expect string -o - "$native_info")" = Infinify ] || fail 'unexpected app bundle executable.'

native_check_artifact() {
  native_name=$1
  native_path=$2
  native_relative=$3
  native_executable=$4
  [ "$(native_manifest_value "artifacts.$native_name.path" string)" = "$native_relative" ] || fail "native helper manifest has an unexpected $native_name path."
  native_expected=$(native_manifest_value "artifacts.$native_name.sha256" string) || fail "native helper manifest has no $native_name digest."
  native_valid_hash "$native_expected" || fail "native helper manifest has an invalid $native_name digest."
  native_regular_file "$native_path" || fail "bundled $native_name is missing or is a symlink."
  if [ "$native_executable" = yes ] && [ ! -x "$native_path" ]; then fail "bundled $native_name is not executable."; fi
  [ "$(native_digest "$native_path")" = "$native_expected" ] || fail "bundled $native_name bytes differ from the signed manifest."
}

native_check_artifact launcher "$native_launcher" Contents/Resources/NativeDesktop/launch.sh yes
native_check_artifact doctor "$native_doctor" Contents/Resources/NativeDesktop/doctor yes
native_check_artifact loader "$native_loader" Contents/Resources/NativeDesktop/loader-arm64e yes
native_check_artifact daemon "$native_daemon" Contents/Resources/NativeDesktop/loadd yes
native_check_artifact payload "$native_payload" Contents/Resources/NativeDesktop/payload-arm64e.dylib yes
native_payload_sha256=$(native_manifest_value artifacts.payload.sha256 string) || fail 'native helper manifest has no payload digest.'
/usr/bin/codesign --verify --strict "$native_doctor" || fail 'doctor signature verification failed.'
/usr/bin/codesign --verify --strict "$native_loader" || fail 'loader signature verification failed.'
/usr/bin/codesign --verify --strict "$native_daemon" || fail 'launch daemon signature verification failed.'
/usr/bin/codesign --verify --strict "$native_payload" || fail 'payload signature verification failed.'
/usr/bin/codesign --verify --deep --strict "$native_bundle" || fail 'app bundle signature verification failed.'
native_app_verified=true

if [ "$native_mode" = launch ] && [ "$native_setup_feedback" = true ]; then
  native_mode=launch-setup
fi
exec "$native_app" native-desktop launcher "$native_mode"
