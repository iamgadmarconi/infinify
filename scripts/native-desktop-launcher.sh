#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Bundled, checkout-independent owner-run launcher for the full desktop helper.
# No Dock restart, settings change, automatic injection retry or runtime cleanup.
set +x
set -eu
umask 077

native_mode=launch
if [ $# -gt 1 ]; then
  printf '%s\n' 'usage: Infinify.app/Contents/Resources/NativeDesktop/launch.sh [--check]' >&2
  exit 64
fi
if [ $# -eq 1 ]; then
  case "$1" in
    --check) native_mode=check ;;
    --help)
      printf '%s\n' 'usage: Infinify.app/Contents/Resources/NativeDesktop/launch.sh [--check]'
      printf '%s\n' '--check: verify the signed bundle and read-only policy report; no sudo, runtime creation or app launch.'
      exit 0
      ;;
    *) printf '%s\n' 'usage: Infinify.app/Contents/Resources/NativeDesktop/launch.sh [--check]' >&2; exit 64 ;;
  esac
fi

fail() { printf 'Infinify native desktop: %s\n' "$*" >&2; exit 1; }
native_dir=$(CDPATH= cd -P "$(dirname "$0")" && pwd -P) || fail 'could not resolve the bundled native helper directory.'
native_bundle=$(CDPATH= cd -P "$native_dir/../../.." && pwd -P) || fail 'could not resolve the containing app bundle.'
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
native_check_artifact payload "$native_payload" Contents/Resources/NativeDesktop/payload-arm64e.dylib yes
native_payload_sha256=$(native_manifest_value artifacts.payload.sha256 string) || fail 'native helper manifest has no payload digest.'
/usr/bin/codesign --verify --strict "$native_doctor" || fail 'doctor signature verification failed.'
/usr/bin/codesign --verify --strict "$native_loader" || fail 'loader signature verification failed.'
/usr/bin/codesign --verify --strict "$native_payload" || fail 'payload signature verification failed.'
/usr/bin/codesign --verify --deep --strict "$native_bundle" || fail 'app bundle signature verification failed.'

[ "$(/usr/bin/id -u)" != 0 ] || fail 'run this launcher as the login user, never with sudo; only its explicit loader step uses sudo.'
[ "$(/usr/bin/uname -s)" = Darwin ] && [ "$(/usr/bin/uname -m)" = arm64 ] || fail 'Apple Silicon macOS 26 or later is required.'
native_version=$(/usr/bin/sw_vers -productVersion)
native_major=${native_version%%.*}
case "$native_major" in ''|*[!0-9]*) fail 'could not identify the macOS version.' ;; esac
[ "$native_major" -ge 26 ] || fail 'macOS 26 or later is required.'

# Doctor is deliberately read-only. A passing prerequisite report does not
# prove that injection or third-party native compositing will work.
native_report=$("$native_doctor") || fail 'doctor failed; no helper was loaded.'
printf '%s\n' "$native_report"
native_preflight=$(printf '%s\n' "$native_report" | /usr/bin/plutil -extract injection_preflight_passed raw -expect bool -o - -) || fail 'doctor returned an invalid policy report.'
[ "$native_preflight" = true ] || fail 'current SIP/arm64e boot policy does not pass preflight; nothing was loaded and no settings were changed.'
[ "$native_mode" != check ] || exit 0

native_uid=$(/usr/bin/id -u)
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
native_boot_sec=$(dock_value boot_sec) || fail 'invalid boot identity report.'
native_boot_usec=$(dock_value boot_usec) || fail 'invalid boot identity report.'
[ "$native_dock_uid" = "$native_uid" ] || fail 'Dock belongs to another login user.'

native_state_dir="$HOME/Library/Application Support/Infinify/native-desktop"
native_record="$native_state_dir/launch.plist"
native_pending_record="$native_state_dir/launch.pending.plist"
native_lock="$native_state_dir/launch.lock"
[ ! -L "$native_state_dir" ] || fail 'the launch-state directory must not be a symlink.'
/bin/mkdir -p "$native_state_dir"
[ -d "$native_state_dir" ] && [ "$(/usr/bin/stat -f '%u:%Lp' "$native_state_dir")" = "$native_uid:700" ] || fail 'launch-state directory must be owned by this login user with mode 0700.'
/bin/mkdir "$native_lock" 2>/dev/null || fail 'another launch or interrupted launch lock exists; inspect it before retrying.'
# Only this invocation's empty lock is removed. Runtimes, nonce files, payload
# sidecars and recovery journals are never deleted, even after an early failure.
release_lock() { /bin/rmdir "$native_lock" 2>/dev/null || :; }
trap release_lock EXIT
trap 'exit 130' INT
trap 'exit 129' HUP
trap 'exit 143' TERM
record_value() { /usr/bin/plutil -extract "$1" raw -expect "$2" -o - "$native_record"; }
private_file() { [ -f "$1" ] && [ ! -L "$1" ] && [ "$(/usr/bin/stat -f '%u:%Lp' "$1")" = "$native_uid:600" ]; }
native_decimal() { case "$1" in ''|*[!0-9]*) return 1 ;; esac; }
native_pid_valid() { native_decimal "$1" && [ "$1" -ge 1 ] && [ "$1" -le 2147483647 ]; }
if [ -e "$native_pending_record" ] || [ -L "$native_pending_record" ]; then
  private_file "$native_pending_record" || fail 'an interrupted launch or recovery marker is not private; preserve it and inspect before retrying.'
  fail 'an interrupted launch or recovery remains pending; preserve its runtime and inspect it before retrying.'
fi

native_prior_dock_gone() {
  if [ "$native_old_dock_pid" = "$native_dock_pid" ]; then
    [ "$native_old_dock_sec" != "$native_dock_sec" ] || [ "$native_old_dock_usec" != "$native_dock_usec" ]
    return $?
  fi
  if native_kill_output=$(LC_ALL=C /bin/kill -0 "$native_old_dock_pid" 2>&1); then
    return 1
  else
    native_kill_status=$?
    [ "$native_kill_status" -eq 1 ] || return 2
    case "$native_kill_output" in *"No such process"*) return 0 ;; *) return 2 ;; esac
  fi
}

native_archive_retired_record() {
  native_archive_dir=$(/usr/bin/mktemp -d "$native_state_dir/retired-launch.XXXXXX") || fail 'could not create a private archive for the retired launch record.'
  [ "$(/usr/bin/stat -f '%u:%Lp' "$native_archive_dir")" = "$native_uid:700" ] || fail 'retired launch-record archive is not private.'
  native_record_sha256=$(native_digest "$native_record") || fail 'could not hash the retired launch record.'
  /bin/cp "$native_record" "$native_archive_dir/launch.plist" || fail 'could not preserve the retired launch record.'
  /bin/chmod 600 "$native_archive_dir/launch.plist" || fail 'could not secure the archived launch record.'
  private_file "$native_archive_dir/launch.plist" || fail 'archived launch record is not a private regular file.'
  [ "$(native_digest "$native_archive_dir/launch.plist")" = "$native_record_sha256" ] || fail 'archived launch record bytes changed; preserve the archive and inspect it.'
  printf 'Archived the retired Dock launch record at %s; its runtime and recovery journal were preserved.\n' "$native_archive_dir/launch.plist"
}

native_validate_retired_journal() {
  native_journal="$native_runtime/v2-journal.json"
  private_file "$native_journal" || fail 'the retired helper has no private committed v2 journal; preserve its state and inspect it.'
  native_journal_size=$(/usr/bin/stat -f '%z' "$native_journal") || fail 'could not inspect the retired helper journal.'
  native_decimal "$native_journal_size" && [ "$native_journal_size" -ge 1 ] && [ "$native_journal_size" -le 4194304 ] || fail 'the retired helper journal size is invalid; preserve it and inspect it.'
  native_journal_version=$(/usr/bin/plutil -extract v raw -expect integer -o - "$native_journal") || fail 'the retired helper journal is not a valid schema-3 journal.'
  [ "$native_journal_version" = 3 ] || fail 'the retired helper journal is schema 2 or unknown; it has no retained original-window ledger for safe Dock recovery. Preserve it and inspect it; no automatic transform reconstruction is safe.'
  native_journal_pid=$(/usr/bin/plutil -extract server_pid raw -expect integer -o - "$native_journal") || fail 'the retired helper journal has no exact integer server PID.'
  native_pid_valid "$native_journal_pid" && [ "$native_journal_pid" = "$native_old_dock_pid" ] || fail 'the retired helper journal does not identify its recorded Dock process.'
  native_journal_sec=$(/usr/bin/plutil -extract server_birth_sec raw -expect integer -o - "$native_journal") || fail 'the retired helper journal has no exact server birth time.'
  native_journal_usec=$(/usr/bin/plutil -extract server_birth_usec raw -expect integer -o - "$native_journal") || fail 'the retired helper journal has no exact server birth time.'
  native_journal_uid=$(/usr/bin/plutil -extract server_uid raw -expect integer -o - "$native_journal") || fail 'the retired helper journal has no exact server UID.'
  native_decimal "$native_journal_sec" && [ "$native_journal_sec" = "$native_old_dock_sec" ] || fail 'the retired helper journal birth time differs from the launch record.'
  native_decimal "$native_journal_usec" && [ "$native_journal_usec" = "$native_old_dock_usec" ] || fail 'the retired helper journal birth time differs from the launch record.'
  [ "$native_journal_uid" = "$native_uid" ] || fail 'the retired helper journal belongs to another login user.'
  native_journal_boot_sec=$(/usr/bin/plutil -extract boot_sec raw -expect integer -o - "$native_journal") || fail 'the retired helper journal has no exact boot identity.'
  native_journal_boot_usec=$(/usr/bin/plutil -extract boot_usec raw -expect integer -o - "$native_journal") || fail 'the retired helper journal has no exact boot identity.'
  [ "$native_journal_boot_sec" = "$native_boot_sec" ] && [ "$native_journal_boot_usec" = "$native_boot_usec" ] || fail 'the retired helper journal belongs to a different boot; preserve it and inspect it.'
  native_journal_generation=$(/usr/bin/plutil -extract generation raw -expect integer -o - "$native_journal") || fail 'the retired helper journal has no exact integer generation.'
  native_decimal "$native_journal_generation" || fail 'the retired helper journal generation is invalid.'
  native_journal_state=$(/usr/bin/plutil -extract state raw -expect string -o - "$native_journal") || fail 'the retired helper journal has no valid state.'
  case "$native_journal_state" in empty|holding|restoring) ;; *) fail 'the retired helper journal has an unknown state; preserve it and inspect it.' ;; esac
  [ "$(/usr/bin/plutil -type windows "$native_journal")" = array ] || fail 'the retired helper journal has no valid active window table.'
  [ "$(/usr/bin/plutil -type released_windows "$native_journal")" = array ] || fail 'the retired helper journal has no valid retained-original table.'
  native_journal_restore_type=$(/usr/bin/plutil -type last_restore "$native_journal") || fail 'the retired helper journal has no valid restoration receipt.'
  case "$native_journal_restore_type" in '(any)'|dictionary) ;; *) fail 'the retired helper journal has an unknown restoration receipt; preserve it and inspect it.' ;; esac
  native_import_source="$native_runtime/recovery-source.json"
  native_sidecar="$native_runtime/payload-arm64e.dylib.json"
  private_file "$native_sidecar" || fail 'the retired helper sidecar is missing or not private; preserve the runtime and inspect it.'
  if [ -e "$native_import_source" ] || [ -L "$native_import_source" ]; then
    private_file "$native_import_source" || fail 'the retained historical recovery source is not private; preserve it and inspect it.'
    native_import_size=$(/usr/bin/stat -f '%z' "$native_import_source") || fail 'could not inspect the historical recovery source.'
    native_decimal "$native_import_size" && [ "$native_import_size" -ge 1 ] && [ "$native_import_size" -le 4194304 ] || fail 'the historical recovery source size is invalid; preserve it and inspect it.'
    private_file "$native_sidecar" || fail 'the retained recovery sidecar is missing or not private; preserve the runtime and inspect it.'
    native_import_hash=$(/usr/bin/plutil -extract recovery_source_sha256 raw -expect string -o - "$native_sidecar") || fail 'the retained recovery sidecar has no source digest.'
    native_valid_hash "$native_import_hash" || fail 'the retained recovery sidecar has an invalid source digest.'
    [ "$(native_digest "$native_import_source")" = "$native_import_hash" ] || fail 'the retained historical recovery source differs from its sidecar digest.'
    [ "$(/usr/bin/plutil -extract v raw -expect integer -o - "$native_import_source")" = 3 ] || fail 'the retained historical recovery source is not schema 3.'
    for native_pair in 'server_pid recovery_server_pid' 'server_birth_sec recovery_server_birth_sec' 'server_birth_usec recovery_server_birth_usec' 'server_uid recovery_server_uid' 'boot_sec recovery_boot_sec' 'boot_usec recovery_boot_usec'; do
      native_source_key=${native_pair%% *}
      native_sidecar_key=${native_pair#* }
      native_source_value=$(/usr/bin/plutil -extract "$native_source_key" raw -expect integer -o - "$native_import_source") || fail 'the retained historical recovery source is missing writer identity.'
      native_sidecar_value=$(/usr/bin/plutil -extract "$native_sidecar_key" raw -expect integer -o - "$native_sidecar") || fail 'the retained recovery sidecar is missing writer identity.'
      [ "$native_source_value" = "$native_sidecar_value" ] || fail 'the retained historical source identity differs from its sidecar.'
    done
  else
    if /usr/bin/plutil -extract recovery_source_sha256 raw -expect string -o - "$native_sidecar" >/dev/null 2>&1; then
      fail 'the recovery sidecar names a historical source that is missing; preserve the runtime and inspect it.'
    fi
  fi
  for native_artifact in v2-journal.next recovery.json recovery.next helper.sock; do
    [ ! -e "$native_runtime/$native_artifact" ] && [ ! -L "$native_runtime/$native_artifact" ] || fail "the retired helper runtime contains $native_artifact; preserve it and inspect it."
  done
  native_recovery_source=$native_journal
}

native_reuse=false
native_recovery=false

if [ -e "$native_record" ] || [ -L "$native_record" ]; then
  private_file "$native_record" || fail 'the existing launch record is not a private regular file; inspect it before retrying.'
  [ "$(record_value version integer)" = 2 ] || fail 'unknown launch-record format; inspect it before retrying.'
  native_outcome=$(record_value outcome string) || fail 'invalid launch-record outcome; inspect it before retrying.'
  [ "$native_outcome" = ready ] || fail 'a prior injection outcome is pending or unknown; retain its runtime and inspect it, do not inject again.'
  native_old_dock_pid=$(record_value dock_pid integer) || fail 'launch record has no exact integer Dock PID; inspect it before retrying.'
  native_old_dock_sec=$(record_value dock_birth_sec integer) || fail 'launch record has no exact integer Dock birth time; inspect it before retrying.'
  native_old_dock_usec=$(record_value dock_birth_usec integer) || fail 'launch record has no exact integer Dock birth time; inspect it before retrying.'
  native_pid_valid "$native_old_dock_pid" || fail 'launch record has an invalid Dock PID; inspect it before retrying.'
  native_decimal "$native_old_dock_sec" && [ "$native_old_dock_sec" != 0 ] || fail 'launch record has an invalid Dock birth time; inspect it before retrying.'
  native_decimal "$native_old_dock_usec" && [ "$native_old_dock_usec" -le 999999 ] || fail 'launch record has an invalid Dock birth time; inspect it before retrying.'
  native_record_payload_sha256=$(record_value payload_sha256 string) || fail 'launch record has no payload digest; inspect it before retrying.'
  native_valid_hash "$native_record_payload_sha256" || fail 'launch record has an invalid payload digest; inspect it before retrying.'
  native_runtime=$(record_value runtime string) || fail 'invalid recorded runtime path.'
  native_nonce_file=$(record_value nonce_file string) || fail 'invalid recorded nonce-file path.'
  case "$native_runtime" in /tmp/if-native.??????) ;; *) fail 'invalid recorded private runtime path.' ;; esac
  native_runtime_suffix=${native_runtime##*.}
  case "$native_runtime_suffix" in *[!A-Za-z0-9]*|'') fail 'invalid recorded private runtime path.' ;; esac
  [ "$native_nonce_file" = "$native_runtime/nonce" ] || fail 'recorded nonce file does not belong to its runtime.'
  [ -d "$native_runtime" ] && [ ! -L "$native_runtime" ] && [ "$(/usr/bin/stat -f '%u:%Lp' "$native_runtime")" = "$native_uid:700" ] || fail 'recorded runtime is missing or no longer private; do not inject again.'
  private_file "$native_nonce_file" || fail 'recorded nonce file is missing or no longer private; do not inject again.'
  native_runtime_payload="$native_runtime/payload-arm64e.dylib"
  private_file "$native_runtime_payload" || fail 'recorded runtime payload is missing or no longer private; do not inject again.'
  [ "$(native_digest "$native_runtime_payload")" = "$native_record_payload_sha256" ] || fail 'recorded runtime payload bytes differ from the launch record; do not reuse the old helper.'
  /usr/bin/codesign --verify --strict "$native_runtime_payload" || fail 'recorded runtime payload signature verification failed; do not reuse the old helper.'
  if [ "$native_old_dock_pid" = "$native_dock_pid" ] && [ "$native_old_dock_sec" = "$native_dock_sec" ] && [ "$native_old_dock_usec" = "$native_dock_usec" ]; then
    [ "$native_record_payload_sha256" = "$native_payload_sha256" ] || fail 'the recorded helper payload differs from this bundle; inspect the old session and do not reuse it.'
    native_reuse=true
  else
    if native_prior_dock_gone; then
      :
    else
      native_prior_status=$?
      [ "$native_prior_status" -ne 1 ] || fail 'the recorded Dock PID is still present; preserve its launch record and runtime.'
      fail 'could not prove the recorded Dock process is gone; preserve its launch record and runtime.'
    fi
    native_validate_retired_journal
    native_recovery=true
  fi
fi

if [ "$native_reuse" = true ]; then
  printf '%s\n' 'Reusing the recorded same-Dock desktop helper with the payload hash bound to this bundle; the app will authenticate its scope and restoration capabilities.'
else
  if [ "$native_recovery" != true ]; then
    [ ! -e "$native_record" ] && [ ! -L "$native_record" ] || fail 'launch record remains after the retired record check; preserve it and inspect it.'
  fi
  [ -t 0 ] || fail 'start this owner-run launcher in a terminal for the explicit sudo loader step.'
  native_runtime=$(/usr/bin/mktemp -d /tmp/if-native.XXXXXX)
  native_nonce_file="$native_runtime/nonce"
  /usr/bin/openssl rand -hex 32 > "$native_nonce_file"
  private_file "$native_nonce_file" || fail 'could not create a private nonce file.'
  /bin/cp "$native_payload" "$native_runtime/payload-arm64e.dylib"
  /bin/chmod 600 "$native_runtime/payload-arm64e.dylib"
  private_file "$native_runtime/payload-arm64e.dylib" || fail 'could not create a private runtime payload.'
  [ "$(native_digest "$native_runtime/payload-arm64e.dylib")" = "$native_payload_sha256" ] || fail 'copied runtime payload bytes differ from the bundle.'
  /usr/bin/codesign --verify --strict "$native_runtime/payload-arm64e.dylib" || fail 'copied payload signature verification failed.'
  write_record() {
    native_record_target=$1
    native_record_outcome=$2
    native_record_tmp=$(/usr/bin/mktemp "$native_state_dir/.launch.XXXXXX")
    cat > "$native_record_tmp" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict/></plist>
PLIST
    /usr/bin/plutil -insert version -integer 2 "$native_record_tmp"
    /usr/bin/plutil -insert dock_pid -integer "$native_dock_pid" "$native_record_tmp"
    /usr/bin/plutil -insert dock_birth_sec -integer "$native_dock_sec" "$native_record_tmp"
    /usr/bin/plutil -insert dock_birth_usec -integer "$native_dock_usec" "$native_record_tmp"
    /usr/bin/plutil -insert runtime -string "$native_runtime" "$native_record_tmp"
    /usr/bin/plutil -insert nonce_file -string "$native_nonce_file" "$native_record_tmp"
    /usr/bin/plutil -insert payload_sha256 -string "$native_payload_sha256" "$native_record_tmp"
    /usr/bin/plutil -insert outcome -string "$native_record_outcome" "$native_record_tmp"
    /bin/chmod 600 "$native_record_tmp"
    /bin/mv "$native_record_tmp" "$native_record_target"
  }
  # Save ambiguity BEFORE sudo can execute remote code. A signal, failed loader
  # or uncertain bootstrap leaves pending on disk and forbids blind reinjection.
  if [ "$native_recovery" = true ]; then
    [ ! -e "$native_pending_record" ] && [ ! -L "$native_pending_record" ] || fail 'an interrupted recovery marker already exists; preserve it and inspect it.'
    write_record "$native_pending_record" pending
  else
    write_record "$native_record" pending
  fi
  printf '%s\n' 'Starting the explicitly selected full-desktop SAME_USER helper, including newly opened applications. Only the loader runs with sudo.'
  if [ "$native_recovery" = true ]; then
    if ! /usr/bin/sudo "$native_loader" --inject-dock "$native_runtime/payload-arm64e.dylib" "$native_runtime" --nonce-file "$native_nonce_file" --desktop --expected-dock "$native_dock_pid" "$native_dock_sec" "$native_dock_usec" --recover-journal "$native_recovery_source" --expected-retired-dock "$native_old_dock_pid" "$native_old_dock_sec" "$native_old_dock_usec"; then
      fail "recovery loader did not establish readiness; retained old ready record at $native_record, pending marker at $native_pending_record and runtime at $native_runtime. Inspect before any retry."
    fi
    native_archive_retired_record
    write_record "$native_pending_record" ready
    /bin/mv "$native_pending_record" "$native_record" || fail 'helper recovered, but the ready record could not be promoted; preserve the pending marker and inspect it.'
  else
    if ! /usr/bin/sudo "$native_loader" --inject-dock "$native_runtime/payload-arm64e.dylib" "$native_runtime" --nonce-file "$native_nonce_file" --desktop --expected-dock "$native_dock_pid" "$native_dock_sec" "$native_dock_usec"; then
      fail "loader did not establish readiness; retained pending record at $native_record and runtime at $native_runtime. Inspect before any retry."
    fi
    write_record "$native_record" ready
  fi
fi
[ "$(/usr/bin/id -u)" = "$native_uid" ] && [ "$native_uid" != 0 ] || fail 'refusing to run the app as root or another user.'
release_lock
trap - EXIT INT HUP TERM
exec "$native_app" --native-desktop-helper "$native_runtime" "$native_nonce_file"
