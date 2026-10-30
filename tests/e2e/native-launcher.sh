#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# The bundled native-desktop launcher's modes (owner start, --login, --reload), end to end, against a signed stand-in bundle:
# stub doctor/loader/app/daemon client (tests/native/dock-helper/Loader/NativeLauncherFixture.c) that load nothing, a throwaway HOME, and the real
# launcher script. It shows the launcher's decisions: when it asks the launch daemon and with which arguments, the journal
# handoff from a retired Dock, the pause of automatic loading, the refusal of uncertain states, the quiet login refusals. It is
# not evidence that anything loads into a Dock (see docs/native/dock-helper/Daemon/README.md for the guest run).
# It needs no Infinify process to be running (the launcher looks for one by name); run it where none is, e.g. the guest.
set -eu
cd "$(dirname "$0")/../.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
if /usr/bin/pgrep -u "$(id -u)" -x Infinify >/dev/null; then
  printf '%s\n' 'native-launcher: SKIPPED, an Infinify process is running here and the launcher would take it for the one under test. Run it where none is.'
  exit 0
fi
work=$(mktemp -d "${TMPDIR:-/tmp}/infinify-native-launcher.XXXXXX")
sleeper=
cleanup() {
  status=$?
  trap - EXIT HUP INT TERM
  [ -z "$sleeper" ] || kill "$sleeper" 2>/dev/null || :
  # The runtimes this run's launcher made in /tmp (and only those) go with it.
  if [ -f "$work/control/daemon-loads" ]; then
    while read -r runtime _rest; do
      case "$runtime" in /tmp/if-native.??????) rm -rf "$runtime" ;; esac
    done < "$work/control/daemon-loads"
  fi
  rm -rf "$work"
  exit "$status"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM

app=$work/Infinify.app
native=$app/Contents/Resources/NativeDesktop
control=$work/control
export HOME=$work/home STUB_DIR=$control STUB_PAYLOAD=$native/payload-arm64e.dylib
mkdir -p "$app/Contents/MacOS" "$native" "$control" "$HOME"
# STUB_BINARY: a stand-in already built (for a machine without the compiler, such as the guest).
if [ -n "${STUB_BINARY:-}" ]; then cp "$STUB_BINARY" "$work/stub"; else xcrun clang -arch arm64 -mmacosx-version-min=26.0 -Wall -Wextra -Werror -O1 tests/native/dock-helper/Loader/NativeLauncherFixture.c -o "$work/stub"; fi
cp "$work/stub" "$app/Contents/MacOS/Infinify"
for name in doctor loader-arm64e payload-arm64e.dylib loadd; do cp "$work/stub" "$native/$name"; done
cp scripts/native-desktop-launcher.sh "$native/launch.sh"
chmod 755 "$native"/* "$app/Contents/MacOS/Infinify"
cat > "$app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>CFBundleExecutable</key><string>Infinify</string><key>CFBundleIdentifier</key><string>com.marengox.infinify</string></dict></plist>
PLIST
# Each stand-in is signed (ad hoc) under its own name, then bound by digest in a manifest, then the bundle is signed over all of it.
for name in doctor loader-arm64e payload-arm64e.dylib loadd; do codesign --force --sign - "$native/$name" 2>/dev/null; done
digest() { shasum -a 256 "$1" | cut -d ' ' -f 1; }
payload_sha=$(digest "$native/payload-arm64e.dylib")
{
  printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'
  printf '%s\n' '<key>schema_version</key><integer>1</integer><key>git_commit</key><string>stub</string>'
  printf '<key>source_fingerprint_sha256</key><string>%s</string><key>artifacts</key><dict>\n' "$(printf stub | shasum -a 256 | cut -d ' ' -f 1)"
  for pair in doctor:doctor loader:loader-arm64e payload:payload-arm64e.dylib daemon:loadd launcher:launch.sh; do
    key=${pair%%:*}; file=${pair#*:}
    printf '<key>%s</key><dict><key>path</key><string>Contents/Resources/NativeDesktop/%s</string><key>sha256</key><string>%s</string></dict>\n' "$key" "$file" "$(digest "$native/$file")"
  done
  printf '%s\n' '</dict></dict></plist>'
} > "$native/manifest.plist"
plutil -lint "$native/manifest.plist" >/dev/null
codesign --force --sign - "$app" 2>/dev/null
codesign --verify --deep --strict "$app"

launcher=$native/launch.sh
state_dir() { printf '%s/Library/Application Support/Infinify/native-desktop' "$HOME"; }
fails=0; checks=0
ok() { checks=$((checks + 1)); printf 'ok   %s\n' "$1"; }
bad() { checks=$((checks + 1)); fails=$((fails + 1)); printf 'FAIL %s\n' "$1"; }
out=$work/out
# run LABEL EXPECTED_STATUS COMMAND...: stdout and stderr go to $out.
run() { label=$1; want=$2; shift 2; case " $* " in *" --login "*) [ ! -f "$(state_dir)/login.log" ] || : > "$(state_dir)/login.log" ;; esac; set +e; "$@" > "$out" 2>&1 < /dev/null; got=$?; set -e; if [ "$got" = "$want" ]; then ok "$label: exit $got"; else bad "$label: exit $got, wanted $want"; sed 's/^/     | /' "$out"; fi; }
# run_split LABEL EXPECTED_STATUS COMMAND...: stdout alone goes to $out, stderr to $out.err (the app reads a reload's stdout).
run_split() { label=$1; want=$2; shift 2; set +e; "$@" > "$out" 2> "$out.err" < /dev/null; got=$?; set -e; if [ "$got" = "$want" ]; then ok "$label: exit $got"; else bad "$label: exit $got, wanted $want"; sed 's/^/     | /' "$out" "$out.err"; fi; }
# What the last login start wrote to its log (a login start prints nothing to the console).
logsays() { if tail -n 60 "$(state_dir)/login.log" | grep -q -- "$2"; then ok "$1: logs '$2'"; else bad "$1: its log does not say '$2'"; tail -n 8 "$(state_dir)/login.log" | sed 's/^/     | /'; fi; }
says() { if grep -q -- "$2" "$out"; then ok "$1: says '$2'"; else bad "$1: does not say '$2'"; sed 's/^/     | /' "$out"; fi; }
loads() { if [ -f "$control/daemon-loads" ]; then wc -l < "$control/daemon-loads" | tr -d ' '; else echo 0; fi; }
expect_loads() { if [ "$(loads)" = "$2" ]; then ok "$1: $2 daemon load(s) so far"; else bad "$1: $(loads) daemon loads, wanted $2"; fi; }
exists() { if [ -e "$2" ]; then ok "$1"; else bad "$1 (missing $2)"; fi; }
absent() { if [ ! -e "$2" ]; then ok "$1"; else bad "$1 (found $2)"; fi; }
last_launch() { sed -n "$1p" "$control/app-launch" | grep -c -- "$2" | tr -d ' '; }
dock() { printf '%s\n' "$1 $2 $3" > "$control/dock"; }
record() { /usr/bin/plutil -extract "$1" raw -expect "$2" -o - "$(state_dir)/launch.plist"; }
D1="9990001 1790000000 111"; D2="9990002 1790000100 222"; D3="9990003 1790000200 333"; D4="9990004 1790000300 444"
# shellcheck disable=SC2086
dock $D1

run '--check without the daemon' 0 "$launcher" --check
says '--check without the daemon' 'launch daemon: not-registered'
absent '--check creates no launch state' "$HOME/Library"
absent '--check loads nothing' "$control/daemon-loads"

run 'owner start without a daemon or a terminal' 1 "$launcher"
says 'owner start without a daemon or a terminal' 'in a terminal for the explicit sudo loader step'
absent 'no launch record was written' "$(state_dir)/launch.plist"
absent 'no pending marker was written' "$(state_dir)/launch.pending.plist"
absent 'sudo was not reached' "$control/loader-calls"

touch "$control/daemon-enabled"
run 'owner start with the daemon' 0 "$launcher"
says 'owner start with the daemon' 'through the launch daemon'
expect_loads 'owner start' 1
if grep -q -- "--desktop --expected-dock $D1 " "$control/daemon-loads" && ! grep -q -- '--recover-journal' "$control/daemon-loads"; then ok 'the load pins the Dock the launcher read, fresh form'; else bad 'the load arguments'; cat "$control/daemon-loads"; fi
if [ "$(record outcome string)" = ready ] && [ "$(record version integer)" = 3 ] && [ "$(record payload_sha256 string)" = "$payload_sha" ] && [ "$(record dock_pid integer)" = 9990001 ]; then ok 'a ready schema-3 record binds the Dock and the payload digest'; else bad 'the launch record'; fi
if [ "$(last_launch 1 '^args: --native-desktop-helper /tmp/if-native\.[A-Za-z0-9]\{6\} /tmp/if-native\.[A-Za-z0-9]\{6\}/nonce$')" = 1 ]; then ok 'the app is started with the helper runtime and nonce file'; else bad 'the app arguments'; cat "$control/app-launch"; fi
if sed -n 2p "$control/app-launch" | grep -q "^env: reload=1 sha=$payload_sha loaded_at=[1-9][0-9]*$"; then ok 'the app is told reloads are possible, for which payload, and when the launcher loaded'; else bad 'the app environment'; cat "$control/app-launch"; fi
first_runtime=$(record runtime string)

run 'second start in the same Dock reuses the helper' 0 "$launcher"
says 'second start' 'Reusing the recorded same-Dock desktop helper'
expect_loads 'second start' 1
if sed -n 4p "$control/app-launch" | grep -q "^env: reload=1 sha=$payload_sha loaded_at=0$"; then ok 'a reuse is not reported to the crash guard as a load'; else bad 'the reuse environment'; cat "$control/app-launch"; fi

# Through the daemon the Dock opens the daemon's own copy of the payload, never a file in this user's runtime: the launcher puts none
# there, names none in the request, and on a reuse checks the staged copy (which the app reports) against the record.
if ! grep -q 'payload-arm64e' "$control/daemon-loads"; then ok 'the load request names no payload'; else bad 'the load request names a payload'; cat "$control/daemon-loads"; fi
if grep -q '^/tmp/if-native\.[A-Za-z0-9]\{6\} --nonce-file ' "$control/daemon-loads"; then ok 'the load request starts with the runtime'; else bad 'the load request form'; cat "$control/daemon-loads"; fi
absent 'no payload copy is left in the user-writable runtime' "$first_runtime/payload-arm64e.dylib"
staged_payload=$control/staged/infinify-payload.${first_runtime##*.}/payload-arm64e.dylib
exists 'the daemon staged the payload and its sidecar for the runtime' "$staged_payload.json"
cp "$staged_payload" "$work/staged-original"
printf x >> "$staged_payload"
run 'a staged payload whose bytes changed is not reused' 1 "$launcher"
says 'a changed staged payload' 'recorded runtime payload bytes differ from the launch record'
cp "$work/staged-original" "$staged_payload"
mv "$staged_payload" "$staged_payload.moved"
run 'a staged payload that is gone is not reused' 1 "$launcher"
says 'a missing staged payload' 'missing, no longer private, or no longer the launch daemon'
mv "$staged_payload.moved" "$staged_payload"
run 'the intact staged payload is reused again' 0 "$launcher"
says 'the intact staged payload' 'Reusing the recorded same-Dock'
expect_loads 'staged payload checks' 1

# --reload: only the one running Infinify may ask, as its parent.
cp "$control/app-launch" "$control/app-launch.before"
dock $D2
run 'reload with no Infinify running' 1 "$launcher" --reload
says 'reload with no Infinify running' 'none is running'
expect_loads 'reload with no Infinify running' 1
"$app/Contents/MacOS/Infinify" stub-sleep &
sleeper=$!
sleep 1
run 'reload from a process that is not the running Infinify' 1 "$launcher" --reload
says 'reload from a process that is not the running Infinify' 'as its child'
expect_loads 'reload from a stranger' 1
run 'login start while Infinify runs' 0 "$launcher" --login
if grep -q 'Infinify is already running' "$(state_dir)/login.log"; then ok 'login start while Infinify runs: says so in its log'; else bad 'login start while Infinify runs: the log does not say so'; fi
expect_loads 'login start while Infinify runs' 1
kill "$sleeper" 2>/dev/null || :; sleeper=
sleep 1

export STUB_LAUNCHER=$launcher
run_split 'reload after a Dock restart (journal handoff from the retired Dock)' 0 "$app/Contents/MacOS/Infinify" stub-reload-parent
if [ "$(grep -c '^INFINIFY-NATIVE-ENDPOINT /tmp/if-native\.[A-Za-z0-9]\{6\} /tmp/if-native\.[A-Za-z0-9]\{6\}/nonce$' "$out")" = 1 ] && [ "$(wc -l < "$out" | tr -d ' ')" = 1 ]; then ok 'the app reads one endpoint line and nothing else on its pipe'; else bad 'the reload output'; sed 's/^/     | /' "$out"; fi
if grep -q 'Starting the explicitly selected full-desktop' "$out.err" && grep -q 'Archived the retired Dock launch record' "$out.err"; then ok 'the launcher keeps its chatter on stderr'; else bad 'the launcher chatter is not on stderr'; fi
expect_loads 'reload' 2
if sed -n 2p "$control/daemon-loads" | grep -q -- "--expected-dock $D2 --recover-journal $first_runtime/v2-journal.json --expected-retired-dock $D1 "; then ok 'the recovery names the new Dock, the retired runtime journal and the retired Dock'; else bad 'the recovery arguments'; sed -n 2p "$control/daemon-loads"; fi
if [ "$(record dock_pid integer)" = 9990002 ] && [ "$(record outcome string)" = ready ] && [ "$(record runtime string)" != "$first_runtime" ]; then ok 'the ready record moved to the new Dock and runtime'; else bad 'the record after the reload'; fi
if ls -d "$(state_dir)"/retired-launch.* >/dev/null 2>&1; then ok 'the retired launch record was archived byte for byte'; else bad 'no archive of the retired record'; fi
absent 'no pending marker remains after a successful recovery' "$(state_dir)/launch.pending.plist"
[ "$(wc -l < "$control/app-launch")" = "$(wc -l < "$control/app-launch.before")" ] && ok 'a reload does not start the app' || bad 'a reload started the app'

dock $D3
run_split 'a second reload recovers from a runtime that itself recovered' 0 "$app/Contents/MacOS/Infinify" stub-reload-parent
expect_loads 'second reload' 3
if sed -n 3p "$control/daemon-loads" | grep -q -- "--expected-retired-dock $D2 "; then ok 'the handoff chain follows the previous Dock'; else bad 'chained recovery'; sed -n 3p "$control/daemon-loads"; fi

# The pause of automatic loading.
pause=$(state_dir)/auto-reload-paused.plist
write_pause() { /bin/rm -f "$pause"; printf '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict><key>version</key><integer>1</integer><key>payload_sha256</key><string>%s</string></dict></plist>\n' "$1" > "$pause"; chmod 600 "$pause"; }
write_pause "$payload_sha"
dock $D4
launches=$(grep -c '^args:' "$control/app-launch")
run 'reload while paused' 1 "$app/Contents/MacOS/Infinify" stub-reload-parent
says 'reload while paused' 'paused for this payload'
run 'login start while paused' 0 "$launcher" --login
logsays 'login start while paused' 'compositor mode was not started'
expect_loads 'paused' 3
[ "$(grep -c '^args:' "$control/app-launch")" = "$launches" ] && ok 'a paused login started no app' || bad 'a paused login started the app'
write_pause "$(printf other | shasum -a 256 | cut -d ' ' -f 1)"
dock $D3
run 'login start with a pause made for another payload' 0 "$launcher" --login
if tail -n 40 "$(state_dir)/login.log" | grep -q 'Reusing the recorded same-Dock'; then ok 'another payload version is not paused'; else bad 'a pause for another payload held this one back'; sed 's/^/     | /' "$out"; fi
printf 'not a plist' > "$pause"; chmod 600 "$pause"
run 'login start with an unreadable pause file' 0 "$launcher" --login
logsays 'login start with an unreadable pause file' 'compositor mode was not started'
write_pause "$payload_sha"
run 'owner start lifts the pause' 0 "$launcher"
says 'owner start lifts the pause' 'lifts the pause'
absent 'the pause file is gone' "$pause"

# Login start: waits for the Dock, logs, and refuses quietly.
printf '%s\n' 2 > "$control/dock-absent-queries"
run 'login start while the Dock is still starting' 0 "$launcher" --login
exists 'the login log exists' "$(state_dir)/login.log"
if grep -q 'login start' "$(state_dir)/login.log" && grep -q 'Reusing the recorded same-Dock' "$(state_dir)/login.log"; then ok 'the login start went to its log'; else bad 'the login log'; fi
[ ! -s "$out" ] && ok 'a login start writes nothing to the console' || { bad 'the login start wrote to the console'; cat "$out"; }
rm -f "$control/daemon-enabled"
run 'login start in the same Dock without the daemon' 0 "$launcher" --login
n=$(grep -c '^args:' "$control/app-launch")
if tail -n 2 "$control/app-launch" | sed -n 2p | grep -q 'reload=-'; then ok 'without the daemon the app starts but is not told to reload'; else bad 'environment without the daemon'; tail -n 2 "$control/app-launch"; fi
dock $D4
run 'login start in a new Dock without the daemon' 0 "$launcher" --login
grep -q 'launch daemon is not enabled' "$(state_dir)/login.log" && ok 'a login start that would need a password says so in its log and exits 0' || bad 'the log says nothing'
expect_loads 'no daemon' 3
absent 'nothing was left pending' "$(state_dir)/launch.pending.plist"
[ "$(grep -c '^args:' "$control/app-launch")" = "$n" ] && ok 'no app was started' || bad 'an app was started'

touch "$control/daemon-enabled" "$control/daemon-ping-fails"
run 'reload when the daemon does not answer' 1 "$app/Contents/MacOS/Infinify" stub-reload-parent
says 'reload when the daemon does not answer' 'does not answer this app'
expect_loads 'unanswered daemon' 3
absent 'an unanswered daemon leaves nothing pending' "$(state_dir)/launch.pending.plist"
rm -f "$control/daemon-ping-fails"

touch "$control/daemon-load-fails"
run 'reload when the loader fails' 1 "$app/Contents/MacOS/Infinify" stub-reload-parent
says 'reload when the loader fails' 'recovery loader did not establish readiness'
expect_loads 'failed loader' 4
exists 'a failed load leaves its pending marker' "$(state_dir)/launch.pending.plist"
run 'login start after a failed load' 0 "$launcher" --login
grep -q 'interrupted launch or recovery remains pending' "$(state_dir)/login.log" && ok 'an uncertain load is refused at the next login' || bad 'pending not refused at login'
run 'reload after a failed load' 1 "$app/Contents/MacOS/Infinify" stub-reload-parent
says 'reload after a failed load' 'remains pending'
expect_loads 'nothing is retried' 4
rm -f "$(state_dir)/launch.pending.plist" "$control/daemon-load-fails"   # the owner inspected it

run 'reload once the owner cleared the marker' 0 "$app/Contents/MacOS/Infinify" stub-reload-parent
expect_loads 'after the marker was cleared' 5

# A record from another boot session is archived and the start is fresh, without journal replay.
/usr/bin/plutil -replace boot_uuid -string 00000000-0000-0000-0000-000000000000 "$(state_dir)/launch.plist"
run 'login start with a record of a previous boot' 0 "$launcher" --login
expect_loads 'previous boot' 6
if sed -n 6p "$control/daemon-loads" | grep -q -- '--recover-journal'; then bad 'a previous boot replayed a journal'; else ok 'a record of a previous boot starts fresh, without recovery'; fi
if [ "$(record outcome string)" = ready ] && [ "$(record dock_pid integer)" = 9990004 ]; then ok 'and the new ready record is for the current Dock'; else bad 'record after the fresh start'; fi

# A retired helper journal of the previous schema (absolute originals) is refused whole and does not block: the launch record and the
# journal are archived, the retired runtime stays as it was, the start is fresh (no recovery arguments), nothing is left pending, and the
# next Dock restart recovers from the fresh runtime's own journal as usual.
old_runtime=$(record runtime string)
/usr/bin/plutil -replace v -integer 3 "$old_runtime/v2-journal.json"; chmod 600 "$old_runtime/v2-journal.json"
D5="9990005 1790000400 555"; D6="9990006 1790000500 666"
dock $D5
archives_before=$(ls -d "$(state_dir)"/retired-launch.* | wc -l | tr -d ' ')
run_split 'reload with a retired journal of the previous schema' 0 "$app/Contents/MacOS/Infinify" stub-reload-parent
expect_loads 'previous schema' 7
if grep -q 'schema 3 and this build recovers schema 4 only' "$out.err" && grep -q 'startup will be fresh without journal replay' "$out.err"; then ok 'the launcher says the old schema is not recovered and the start is fresh'; else bad 'no message about the old schema'; sed 's/^/     | /' "$out.err"; fi
if sed -n 7p "$control/daemon-loads" | grep -q -- '--recover-journal'; then bad 'a journal of the previous schema was offered for recovery'; else ok 'a journal of the previous schema is not offered for recovery'; fi
absent 'no pending marker after refusing the old journal' "$(state_dir)/launch.pending.plist"
if [ "$(record outcome string)" = ready ] && [ "$(record dock_pid integer)" = 9990005 ] && [ "$(record runtime string)" != "$old_runtime" ]; then ok 'the new ready record is for the current Dock and a fresh runtime'; else bad 'record after refusing the old journal'; fi
archived=
for d in "$(state_dir)"/retired-launch.*; do if [ -f "$d/v2-journal.json" ] && [ "$(/usr/bin/plutil -extract v raw -expect integer -o - "$d/v2-journal.json")" = 3 ]; then archived=$d; fi; done
if [ -n "$archived" ] && [ -f "$archived/launch.plist" ] && [ "$(stat -f '%Lp' "$archived/v2-journal.json")" = 600 ] && cmp -s "$archived/v2-journal.json" "$old_runtime/v2-journal.json"; then ok 'the launch record and the old journal were archived byte for byte'; else bad 'the old journal was not archived'; fi
exists 'the retired runtime and its journal were left in place' "$old_runtime/v2-journal.json"
[ "$(ls -d "$(state_dir)"/retired-launch.* | wc -l | tr -d ' ')" = "$((archives_before + 1))" ] && ok 'exactly one archive was made' || bad 'archive count'
# A retired runtime with no journal at all (its helper never changed a window, so it never wrote one: the guest's first smoke runs left
# exactly that) has nothing to recover; it is archived like a record of an earlier boot instead of blocking every later start.
old_runtime=$(record runtime string)
rm -f "$old_runtime/v2-journal.json"
dock $D6
run_split 'reload with a retired runtime that never wrote a journal' 0 "$app/Contents/MacOS/Infinify" stub-reload-parent
expect_loads 'no journal' 8
if grep -q 'holds no journal and no recovery source' "$out.err"; then ok 'the launcher says nothing needs recovering and the start is fresh'; else bad 'no message about the absent journal'; sed 's/^/     | /' "$out.err"; fi
if sed -n 8p "$control/daemon-loads" | grep -q -- '--recover-journal'; then bad 'an absent journal was offered for recovery'; else ok 'an absent journal is not offered for recovery'; fi
absent 'no pending marker after an absent journal' "$(state_dir)/launch.pending.plist"
if [ "$(record outcome string)" = ready ] && [ "$(record dock_pid integer)" = 9990006 ]; then ok 'the new ready record is for the current Dock'; else bad 'record after the absent journal'; fi

# Now the next Dock restart recovers from a current-schema journal as usual.
D7="9990007 1790000600 777"; D8="9990008 1790000700 888"
dock $D7
run_split 'the next reload recovers from the fresh runtime' 0 "$app/Contents/MacOS/Infinify" stub-reload-parent
expect_loads 'after the refusals' 9
if sed -n 9p "$control/daemon-loads" | grep -q -- "--recover-journal .*/v2-journal.json --expected-retired-dock $D6 "; then ok 'a current-schema journal is recovered again'; else bad 'recovery after the refusals'; sed -n 9p "$control/daemon-loads"; fi
absent 'nothing pending after the recovery' "$(state_dir)/launch.pending.plist"

# A runtime that kept a recovery import but lost its journal is another matter: that import is an obligation, so the start is refused
# and everything is preserved.
old_runtime=$(record runtime string)
exists 'the recovered runtime holds its recovery import' "$old_runtime/recovery-source.json"
rm -f "$old_runtime/v2-journal.json"
dock $D8
run_split 'reload with a retired runtime that kept a recovery import but no journal' 1 "$app/Contents/MacOS/Infinify" stub-reload-parent
expect_loads 'recovery import without a journal' 9
if grep -q 'no private committed v2 journal' "$out.err"; then ok 'a recovery import without its journal is still refused and preserved'; else bad 'wrong refusal'; sed 's/^/     | /' "$out.err"; fi
exists 'the launch record is untouched' "$(state_dir)/launch.plist"
absent 'and nothing is pending' "$(state_dir)/launch.pending.plist"

if [ "$fails" -ne 0 ]; then printf 'native-launcher: %s of %s checks FAILED\n' "$fails" "$checks" >&2; exit 1; fi
printf 'native-launcher: %s checks passed\n' "$checks"
