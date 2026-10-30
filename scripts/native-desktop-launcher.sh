#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Bundled, checkout-independent launcher for the full desktop helper: run by the owner in a terminal, by the login item
# when the owner enabled compositor mode (--login), and by the running app after a Dock restart (--reload).
# No Dock restart, settings change, automatic retry of an uncertain injection or runtime cleanup.
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
fail() { printf 'Infinify native desktop: %s\n' "$*" >&2; exit "$native_fail_status"; }
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
native_valid_boot_uuid() {
  [ "${#1}" -eq 36 ] || return 1
  case "$1" in
    ????????-????-????-????-????????????) ;;
    *) return 1 ;;
  esac
  native_compact_uuid=$(printf '%s' "$1" | /usr/bin/tr -d '-') || return 1
  [ "${#native_compact_uuid}" -eq 32 ] || return 1
  case "$native_compact_uuid" in *[!0-9A-F]*|'') return 1 ;; esac
  return 0
}

# The payload a recorded runtime's Dock opened, and the directory beside which its sidecar was written. Prints "DIRECTORY SHA256".
# Loaded with sudo, it is the runtime's own private copy. Loaded through the launch daemon, it is the daemon's copy: root's file in
# root's directory below directories only root writes, which the app (native/dock-helper/Daemon/DWLoaddRequest.m) checks again, read-only,
# against the same rule the loader enforced before it injected. No runtime of the login user is the Dock's payload path then.
native_loaded_payload() {
  if [ -e "$1/payload-arm64e.dylib" ] || [ -L "$1/payload-arm64e.dylib" ]; then
    private_file "$1/payload-arm64e.dylib" || return 1
    printf '%s %s\n' "$1" "$(native_digest "$1/payload-arm64e.dylib")"
  else
    "$native_app" native-desktop daemon staged "$1"
  fi
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
# The launch daemon is how the loader runs without a password once the owner approved it (Infinify native-desktop enable).
# Its answer is read here, by the signed app, and decides how the loader step below runs; it changes nothing.
native_daemon_enabled() { "$native_app" native-desktop daemon status >/dev/null 2>&1; }
if [ "$native_mode" = check ]; then
  printf 'launch daemon: %s\n' "$("$native_app" native-desktop daemon status 2>/dev/null || :)"
  exit 0
fi

native_uid=$(/usr/bin/id -u)
if [ "$native_mode" = reload ]; then
  # Only the running app asks for a reload, and it is the one instance: this launcher's parent.
  # pgrep leaves out its own ancestors unless asked (-a), and the app is one.
  native_instances=$(/usr/bin/pgrep -a -u "$native_uid" -x Infinify) || fail 'a reload is for the running Infinify, and none is running.'
  [ "$native_instances" = "$PPID" ] || fail 'a reload is for the one running Infinify to ask, as its child.'
else
  if /usr/bin/pgrep -u "$native_uid" -x Infinify >/dev/null; then
    [ "$native_mode" != login ] || { printf '%s\n' 'Infinify is already running; nothing to start.'; exit 0; }
    fail 'an Infinify instance is already running; quit it normally before starting native desktop mode.'
  else
    native_lookup_status=$?
    [ "$native_lookup_status" -eq 1 ] || fail 'could not determine whether Infinify is already running.'
  fi
fi

# The loader's read-only identity query and its later expected-Dock check use the
# same exact libproc process birth fields. A PID alone must never authorize reuse.
# A login start waits for the Dock of a session that is still starting, and a reload for one that was just restarted: the
# identity must read the same twice, three seconds apart (one second for a reload, whose app has already let the new Dock
# settle), before it is trusted (Sunlight lets a new Dock settle too). The load itself is pinned to that identity.
native_dock_wait=1
native_dock_confirm=3
case "$native_mode" in login) native_dock_wait=60 ;; reload) native_dock_wait=15; native_dock_confirm=1 ;; esac
native_dock=
native_dock_stable=false
native_attempt=0
while :; do
  native_attempt=$((native_attempt + 1))
  if native_dock=$("$native_loader" --dock-identity 2>/dev/null); then
    if [ "$native_mode" = launch ]; then native_dock_stable=true; break; fi
    native_dock_again=$(/bin/sleep "$native_dock_confirm"; "$native_loader" --dock-identity 2>/dev/null) || native_dock_again=
    if [ "$native_dock" = "$native_dock_again" ]; then native_dock_stable=true; break; fi
  fi
  [ "$native_attempt" -lt "$native_dock_wait" ] || break
  [ "$native_mode" = launch ] || /bin/sleep 2
done
[ -n "$native_dock" ] || fail 'could not resolve the current Dock process identity.'
[ "$native_dock_stable" = true ] || fail 'the Dock process identity did not settle.'
dock_value() { printf '%s\n' "$native_dock" | /usr/bin/plutil -extract "$1" raw -expect "$2" -o - -; }
native_dock_pid=$(dock_value pid integer) || fail 'invalid Dock PID report.'
native_dock_sec=$(dock_value birth_sec integer) || fail 'invalid Dock birth report.'
native_dock_usec=$(dock_value birth_usec integer) || fail 'invalid Dock birth report.'
native_dock_uid=$(dock_value uid integer) || fail 'invalid Dock user report.'
native_boot_uuid=$(dock_value boot_uuid string) || fail 'invalid boot identity report.'
native_valid_boot_uuid "$native_boot_uuid" || fail 'invalid boot session UUID report.'
[ "$native_dock_uid" = "$native_uid" ] || fail 'Dock belongs to another login user.'

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
# Three Dock restarts in a row around loads of this payload stopped automatic loading (the app wrote this file). A manual start
# by the owner is the way out; the login start and a reload keep to it.
native_pause_file="$native_state_dir/auto-reload-paused.plist"
native_paused() {
  [ -e "$native_pause_file" ] || [ -L "$native_pause_file" ] || return 1
  private_file "$native_pause_file" || return 0
  native_paused_sha=$(/usr/bin/plutil -extract payload_sha256 raw -expect string -o - "$native_pause_file" 2>/dev/null) || return 0
  [ "$native_paused_sha" = "$native_payload_sha256" ]
}
if [ "$native_mode" = launch ]; then
  if [ -e "$native_pause_file" ] || [ -L "$native_pause_file" ]; then
    /bin/rm -f "$native_pause_file" && printf '%s\n' 'Automatic loading had been paused after Dock restarts around loads; this start by hand lifts the pause.'
  fi
elif native_paused; then
  case "$native_mode" in
    login) printf '%s\n' 'Automatic loading is paused for this payload (three Dock restarts in a row around loads): compositor mode was not started. Run Infinify native-desktop by hand to try again.'; exit 0 ;;
    *) fail 'automatic loading is paused for this payload; run Infinify native-desktop by hand to lift the pause.' ;;
  esac
fi
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
  printf 'Archived the retired Dock launch record at %s; no runtime or recovery journal was changed.\n' "$native_archive_dir/launch.plist"
}

native_archive_and_remove_prior_boot_record() {
  native_archive_retired_record
  [ "$(native_digest "$native_record")" = "$native_record_sha256" ] || fail 'the launch record changed while archiving; preserve both copies and inspect them.'
  /bin/rm "$native_record" || fail 'the prior-boot record was archived but could not be removed from the active launch path.'
}

# The one journal schema this build writes and recovers. An older journal recorded each window's original as an absolute matrix, which
# also contains whatever other placements held at the time; it is not migrated (nothing in this build can say what it meant), so it is
# archived with its launch record and the start is fresh, rather than blocking every later start.
native_journal_schema=4
native_journal_refused=false
native_refuse_unrecoverable_journal() {
  native_archive_retired_record
  if [ "$native_journal_refused" = absent ]; then
    [ "$(native_digest "$native_record")" = "$native_record_sha256" ] || fail 'the launch record changed while archiving; preserve both copies and inspect them.'
    /bin/rm "$native_record" || fail 'the retired launch record was archived but could not be removed from the active launch path.'
    printf 'The retired helper runtime holds no journal and no recovery source. The helper writes its journal before it changes any window, so it changed none; nothing needs recovering. The launch record was archived under %s, the retired runtime was left untouched, and startup will be fresh.\n' "$native_archive_dir"
    return 0
  fi
  /bin/cp "$native_journal" "$native_archive_dir/v2-journal.json" || fail 'could not preserve the retired helper journal.'
  /bin/chmod 600 "$native_archive_dir/v2-journal.json" || fail 'could not secure the archived helper journal.'
  private_file "$native_archive_dir/v2-journal.json" || fail 'archived helper journal is not a private regular file.'
  [ "$(native_digest "$native_archive_dir/v2-journal.json")" = "$(native_digest "$native_journal")" ] || fail 'archived helper journal bytes changed; preserve the archive and inspect it.'
  [ "$(native_digest "$native_record")" = "$native_record_sha256" ] || fail 'the launch record changed while archiving; preserve both copies and inspect them.'
  /bin/rm "$native_record" || fail 'the retired launch record was archived but could not be removed from the active launch path.'
  printf 'The retired helper journal is schema %s and this build recovers schema %s only (older journals are not migrated), so nothing was recovered from it. The launch record and the journal were archived under %s, the retired runtime was left untouched, and startup will be fresh without journal replay.\n' "$native_journal_version" "$native_journal_schema" "$native_archive_dir"
}

native_validate_retired_journal() {
  native_journal="$native_runtime/v2-journal.json"
  # A helper that never changed a window never wrote a journal (it journals before every change), and a runtime with none of its
  # journal, staging file or recovery import has nothing to recover; refusing it would block every later start for nothing.
  native_journal_absent=true
  # A lone socket (v2.sock, which the loader and payload create) is not state to recover: it does not count as an artifact here.
  for native_artifact in v2-journal.json v2-journal.next recovery-source.json recovery.json recovery.next; do
    if [ -e "$native_runtime/$native_artifact" ] || [ -L "$native_runtime/$native_artifact" ]; then native_journal_absent=false; fi
  done
  if [ "$native_journal_absent" = true ]; then native_journal_refused=absent; return 0; fi
  private_file "$native_journal" || fail 'the retired helper has no private committed v2 journal; preserve its state and inspect it.'
  native_journal_size=$(/usr/bin/stat -f '%z' "$native_journal") || fail 'could not inspect the retired helper journal.'
  native_decimal "$native_journal_size" && [ "$native_journal_size" -ge 1 ] && [ "$native_journal_size" -le 4194304 ] || fail 'the retired helper journal size is invalid; preserve it and inspect it.'
  native_journal_version=$(/usr/bin/plutil -extract v raw -expect integer -o - "$native_journal") || fail 'the retired helper journal has no integer schema number; preserve it and inspect it.'
  native_decimal "$native_journal_version" || fail 'the retired helper journal has an invalid schema number; preserve it and inspect it.'
  if [ "$native_journal_version" != "$native_journal_schema" ]; then native_journal_refused=true; return 0; fi
  native_journal_pid=$(/usr/bin/plutil -extract server_pid raw -expect integer -o - "$native_journal") || fail 'the retired helper journal has no exact integer server PID.'
  native_pid_valid "$native_journal_pid" && [ "$native_journal_pid" = "$native_old_dock_pid" ] || fail 'the retired helper journal does not identify its recorded Dock process.'
  native_journal_sec=$(/usr/bin/plutil -extract server_birth_sec raw -expect integer -o - "$native_journal") || fail 'the retired helper journal has no exact server birth time.'
  native_journal_usec=$(/usr/bin/plutil -extract server_birth_usec raw -expect integer -o - "$native_journal") || fail 'the retired helper journal has no exact server birth time.'
  native_journal_uid=$(/usr/bin/plutil -extract server_uid raw -expect integer -o - "$native_journal") || fail 'the retired helper journal has no exact server UID.'
  native_decimal "$native_journal_sec" && [ "$native_journal_sec" = "$native_old_dock_sec" ] || fail 'the retired helper journal birth time differs from the launch record.'
  native_decimal "$native_journal_usec" && [ "$native_journal_usec" = "$native_old_dock_usec" ] || fail 'the retired helper journal birth time differs from the launch record.'
  [ "$native_journal_uid" = "$native_uid" ] || fail 'the retired helper journal belongs to another login user.'
  native_journal_boot_uuid=$(/usr/bin/plutil -extract boot_uuid raw -expect string -o - "$native_journal") || fail 'the retired helper journal has no exact boot session UUID.'
  native_valid_boot_uuid "$native_journal_boot_uuid" && [ "$native_journal_boot_uuid" = "$native_boot_uuid" ] || fail 'the retired helper journal belongs to a different boot session; preserve it and inspect it.'
  native_journal_generation=$(/usr/bin/plutil -extract generation raw -expect integer -o - "$native_journal") || fail 'the retired helper journal has no exact integer generation.'
  native_decimal "$native_journal_generation" || fail 'the retired helper journal generation is invalid.'
  native_journal_state=$(/usr/bin/plutil -extract state raw -expect string -o - "$native_journal") || fail 'the retired helper journal has no valid state.'
  case "$native_journal_state" in empty|holding|restoring) ;; *) fail 'the retired helper journal has an unknown state; preserve it and inspect it.' ;; esac
  [ "$(/usr/bin/plutil -type windows "$native_journal")" = array ] || fail 'the retired helper journal has no valid active window table.'
  [ "$(/usr/bin/plutil -type released_windows "$native_journal")" = array ] || fail 'the retired helper journal has no valid retained-original table.'
  native_journal_restore_type=$(/usr/bin/plutil -type last_restore "$native_journal") || fail 'the retired helper journal has no valid restoration receipt.'
  case "$native_journal_restore_type" in '(any)'|dictionary) ;; *) fail 'the retired helper journal has an unknown restoration receipt; preserve it and inspect it.' ;; esac
  native_import_source="$native_runtime/recovery-source.json"
  native_sidecar="$native_loaded_dir/payload-arm64e.dylib.json"
  private_file "$native_sidecar" || fail 'the retired helper sidecar is missing or not private; preserve the runtime and inspect it.'
  if [ -e "$native_import_source" ] || [ -L "$native_import_source" ]; then
    private_file "$native_import_source" || fail 'the retained historical recovery source is not private; preserve it and inspect it.'
    native_import_size=$(/usr/bin/stat -f '%z' "$native_import_source") || fail 'could not inspect the historical recovery source.'
    native_decimal "$native_import_size" && [ "$native_import_size" -ge 1 ] && [ "$native_import_size" -le 4194304 ] || fail 'the historical recovery source size is invalid; preserve it and inspect it.'
    private_file "$native_sidecar" || fail 'the retained recovery sidecar is missing or not private; preserve the runtime and inspect it.'
    native_import_hash=$(/usr/bin/plutil -extract recovery_source_sha256 raw -expect string -o - "$native_sidecar") || fail 'the retained recovery sidecar has no source digest.'
    native_valid_hash "$native_import_hash" || fail 'the retained recovery sidecar has an invalid source digest.'
    [ "$(native_digest "$native_import_source")" = "$native_import_hash" ] || fail 'the retained historical recovery source differs from its sidecar digest.'
    [ "$(/usr/bin/plutil -extract v raw -expect integer -o - "$native_import_source")" = "$native_journal_schema" ] || fail "the retained historical recovery source is not schema $native_journal_schema."
    for native_pair in 'server_pid recovery_server_pid' 'server_birth_sec recovery_server_birth_sec' 'server_birth_usec recovery_server_birth_usec' 'server_uid recovery_server_uid'; do
      native_source_key=${native_pair%% *}
      native_sidecar_key=${native_pair#* }
      native_source_value=$(/usr/bin/plutil -extract "$native_source_key" raw -expect integer -o - "$native_import_source") || fail 'the retained historical recovery source is missing writer identity.'
      native_sidecar_value=$(/usr/bin/plutil -extract "$native_sidecar_key" raw -expect integer -o - "$native_sidecar") || fail 'the retained recovery sidecar is missing writer identity.'
      [ "$native_source_value" = "$native_sidecar_value" ] || fail 'the retained historical source identity differs from its sidecar.'
    done
    native_source_boot_uuid=$(/usr/bin/plutil -extract boot_uuid raw -expect string -o - "$native_import_source") || fail 'the retained historical source has no boot session UUID.'
    native_sidecar_boot_uuid=$(/usr/bin/plutil -extract recovery_boot_uuid raw -expect string -o - "$native_sidecar") || fail 'the retained recovery sidecar has no boot session UUID.'
    native_valid_boot_uuid "$native_source_boot_uuid" && [ "$native_source_boot_uuid" = "$native_sidecar_boot_uuid" ] || fail 'the retained historical source boot identity differs from its sidecar.'
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
  /usr/bin/plutil -lint "$native_record" >/dev/null || fail 'the existing launch record is not a valid property list.'
  native_record_keys=$(/usr/bin/plutil -convert xml1 -o - "$native_record" | /usr/bin/sed -n 's/^[[:space:]]*<key>\([^<]*\)<\/key>$/\1/p' | /usr/bin/sort) || fail 'could not inspect launch-record keys.'
  native_expected_record_keys=$(printf '%s\n' boot_uuid dock_birth_sec dock_birth_usec dock_pid nonce_file outcome payload_sha256 runtime version | /usr/bin/sort)
  [ "$native_record_keys" = "$native_expected_record_keys" ] || fail 'unknown or incomplete launch-record shape; preserve it and inspect before retrying.'
  [ "$(record_value version integer)" = 3 ] || fail 'unsupported launch-record format; preserve it and inspect before retrying.'
  native_outcome=$(record_value outcome string) || fail 'invalid launch-record outcome; inspect it before retrying.'
  [ "$native_outcome" = ready ] || fail 'a prior injection outcome is pending or unknown; retain its runtime and inspect it, do not inject again.'
  native_record_boot_uuid=$(record_value boot_uuid string) || fail 'launch record has no exact boot-session UUID; preserve it and inspect it before retrying.'
  native_valid_boot_uuid "$native_record_boot_uuid" || fail 'launch record has an invalid boot-session UUID; preserve it and inspect it before retrying.'
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
  if [ "$native_record_boot_uuid" != "$native_boot_uuid" ]; then
    native_archive_and_remove_prior_boot_record
    printf '%s\n' 'The ready record belongs to a previous boot session; its prior Dock cannot survive this boot. The record was archived, any remaining runtime was left untouched, and startup will be fresh without journal replay.'
  else
    [ -d "$native_runtime" ] && [ ! -L "$native_runtime" ] && [ "$(/usr/bin/stat -f '%u:%Lp' "$native_runtime")" = "$native_uid:700" ] || fail 'recorded runtime is missing or no longer private in this boot session; do not inject again.'
    private_file "$native_nonce_file" || fail 'recorded nonce file is missing or no longer private; do not inject again.'
    native_loaded=$(native_loaded_payload "$native_runtime") || fail 'recorded runtime payload is missing, no longer private, or no longer the launch daemon'"'"'s root-owned copy; do not inject again.'
    native_loaded_dir=${native_loaded% *}
    [ "${native_loaded##* }" = "$native_record_payload_sha256" ] || fail 'recorded runtime payload bytes differ from the launch record; do not reuse the old helper.'
    /usr/bin/codesign --verify --strict "$native_loaded_dir/payload-arm64e.dylib" || fail 'recorded runtime payload signature verification failed; do not reuse the old helper.'
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
      if [ "$native_journal_refused" != false ]; then native_refuse_unrecoverable_journal; else native_recovery=true; fi
    fi
  fi
fi

if [ "$native_reuse" = true ]; then
  printf '%s\n' 'Reusing the recorded same-Dock desktop helper with the payload hash bound to this bundle; the app will authenticate its scope and restoration capabilities.'
else
  if [ "$native_recovery" != true ]; then
    [ ! -e "$native_record" ] && [ ! -L "$native_record" ] || fail 'launch record remains after the retired record check; preserve it and inspect it.'
  fi
  # Without the launch daemon the loader needs the owner's sudo password, at a terminal. With it, nothing is asked: the daemon
  # accepts only the signed app as its caller and runs only this loader with these arguments (docs/native/dock-helper/Daemon/README.md).
  native_load_via=sudo
  if native_daemon_enabled; then native_load_via=daemon; fi
  case "$native_mode" in
    login|reload)
      [ "$native_load_via" = daemon ] || fail 'the launch daemon is not enabled, so nothing can be loaded without a password; run Infinify native-desktop enable in a terminal.'
      # The daemon is started by launchd on the first request. An answer proves the caller check and the bundle before anything is
      # written or pending; a login start gives it a little while, since nothing has been written yet.
      native_ping=0
      while ! "$native_app" native-desktop daemon ping >/dev/null 2>&1; do
        native_ping=$((native_ping + 1))
        [ "$native_mode" = login ] && [ "$native_ping" -lt 6 ] || fail 'the launch daemon does not answer this app; nothing was loaded.'
        /bin/sleep 5
      done
      ;;
    *) [ "$native_load_via" = daemon ] || [ -t 0 ] || fail 'start this owner-run launcher in a terminal for the explicit sudo loader step.' ;;
  esac
  native_runtime=$(/usr/bin/mktemp -d /tmp/if-native.XXXXXX)
  native_nonce_file="$native_runtime/nonce"
  /usr/bin/openssl rand -hex 32 > "$native_nonce_file"
  private_file "$native_nonce_file" || fail 'could not create a private nonce file.'
  # With sudo the Dock opens a private copy in this runtime, as it always did: the owner sits at the terminal that asks for the
  # password. Through the launch daemon it does not: the daemon (root) copies the bundled payload to a root-owned place the login user
  # cannot write, checks the copy against the digest built into it, and the loader injects that copy, so no file of this user's is on
  # the path the Dock opens and nothing here can be swapped between the check and the load. This runtime then holds only the nonce,
  # socket and journal.
  if [ "$native_load_via" = sudo ]; then
    /bin/cp "$native_payload" "$native_runtime/payload-arm64e.dylib"
    /bin/chmod 600 "$native_runtime/payload-arm64e.dylib"
    private_file "$native_runtime/payload-arm64e.dylib" || fail 'could not create a private runtime payload.'
    [ "$(native_digest "$native_runtime/payload-arm64e.dylib")" = "$native_payload_sha256" ] || fail 'copied runtime payload bytes differ from the bundle.'
    /usr/bin/codesign --verify --strict "$native_runtime/payload-arm64e.dylib" || fail 'copied payload signature verification failed.'
  fi
  write_record() {
    native_record_target=$1
    native_record_outcome=$2
    native_record_tmp=$(/usr/bin/mktemp "$native_state_dir/.launch.XXXXXX")
    cat > "$native_record_tmp" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict/></plist>
PLIST
    /usr/bin/plutil -insert version -integer 3 "$native_record_tmp"
    /usr/bin/plutil -insert dock_pid -integer "$native_dock_pid" "$native_record_tmp"
    /usr/bin/plutil -insert dock_birth_sec -integer "$native_dock_sec" "$native_record_tmp"
    /usr/bin/plutil -insert dock_birth_usec -integer "$native_dock_usec" "$native_record_tmp"
    /usr/bin/plutil -insert boot_uuid -string "$native_boot_uuid" "$native_record_tmp"
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
  if [ "$native_load_via" = daemon ]; then
    printf '%s\n' 'Starting the explicitly selected full-desktop SAME_USER helper, including newly opened applications. Only the loader runs as root, through the launch daemon.'
  else
    printf '%s\n' 'Starting the explicitly selected full-desktop SAME_USER helper, including newly opened applications. Only the loader runs with sudo.'
  fi
  # Arguments: RUNTIME --nonce-file NONCE --desktop --expected-dock PID SEC USEC [--recover-journal J --expected-retired-dock P S U].
  # The daemon names the payload itself; the sudo loader is given this runtime's private copy.
  native_run_loader() {
    if [ "$native_load_via" = daemon ]; then
      "$native_app" native-desktop daemon load "$@"
    else
      /usr/bin/sudo "$native_loader" --inject-dock "$native_runtime/payload-arm64e.dylib" "$@"
    fi
  }
  native_loaded_at=$(/bin/date +%s)
  if [ "$native_recovery" = true ]; then
    if ! native_run_loader "$native_runtime" --nonce-file "$native_nonce_file" --desktop --expected-dock "$native_dock_pid" "$native_dock_sec" "$native_dock_usec" --recover-journal "$native_recovery_source" --expected-retired-dock "$native_old_dock_pid" "$native_old_dock_sec" "$native_old_dock_usec"; then
      fail "recovery loader did not establish readiness; retained old ready record at $native_record, pending marker at $native_pending_record and runtime at $native_runtime. Inspect before any retry."
    fi
    native_archive_retired_record
    write_record "$native_pending_record" ready
    /bin/mv "$native_pending_record" "$native_record" || fail 'helper recovered, but the ready record could not be promoted; preserve the pending marker and inspect it.'
  else
    if ! native_run_loader "$native_runtime" --nonce-file "$native_nonce_file" --desktop --expected-dock "$native_dock_pid" "$native_dock_sec" "$native_dock_usec"; then
      fail "loader did not establish readiness; retained pending record at $native_record and runtime at $native_runtime. Inspect before any retry."
    fi
    write_record "$native_record" ready
  fi
fi
[ "$(/usr/bin/id -u)" = "$native_uid" ] && [ "$native_uid" != 0 ] || fail 'refusing to run the app as root or another user.'
release_lock
trap - EXIT INT HUP TERM
if [ "$native_mode" = reload ]; then
  # The running app takes this endpoint to its presenter, which authenticates the helper (scope, capabilities, empty restore table).
  printf 'INFINIFY-NATIVE-ENDPOINT %s %s\n' "$native_runtime" "$native_nonce_file" >&3
  exit 0
fi
# With the launch daemon on, the app watches the Dock and has this launcher reload the payload into a Dock that replaced the one
# it is in. When this run loaded, the app counts that load for its crash guard; when it reused a helper, it was not a load.
if native_daemon_enabled; then
  export INFINIFY_DOCK_RELOAD=1 INFINIFY_NATIVE_PAYLOAD_SHA256="$native_payload_sha256" INFINIFY_NATIVE_LOADED_AT="${native_loaded_at:-0}"
fi
exec "$native_app" --native-desktop-helper "$native_runtime" "$native_nonce_file"
