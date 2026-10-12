#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Real AppKit file DnD between two exact, cooperative native windows presented
# at half scale. Captured replicas do not have an NSDraggingDestination route.
set -eu
cd "$(dirname "$0")/../.."
case ${1:-} in
  '') echo 'LIVE NOT RUN: pass --live-owned-fixture to exercise the disposable AppKit drag/drop fixture.'; exit 0 ;;
  --live-owned-fixture) ;;
  *) echo "Usage: $0 [--live-owned-fixture]" >&2; exit 2 ;;
esac
[ "$#" -eq 1 ] || { echo "Usage: $0 [--live-owned-fixture]" >&2; exit 2; }

root=$PWD
driver=$root/tests/e2e/native-drag-drop-driver.py
app=$root/target/app/Infinify.app/Contents/MacOS/Infinify
payload=$root/target/privileged/payload-arm64.dylib
if [ ! -x "$app" ] || [ ! -f "$payload" ]; then
  echo 'NOT RUN: build the packaged app and cooperative v2 helper first; this focused test never builds or replaces them.' >&2
  exit 3
fi
if pgrep -f 'Infinify.app/Contents/MacOS/Infinify' >/dev/null 2>&1; then
  echo 'NOT RUN: another Infinify instance is running; no fixture was started.' >&2
  exit 3
fi
if [ "$(defaults read com.apple.WindowManager GloballyEnabled 2>/dev/null || echo 0)" = 1 ]; then
  echo 'NOT RUN: Stage Manager is enabled; no fixture was started and no setting was changed.' >&2
  exit 3
fi
python3 "$driver" preflight || exit $?

mkdir -p "$root/target/ipc"
evidence=$(mktemp -d "$root/target/ipc/native-drag.XXXXXX")
chmod 700 "$evidence"
printf 'Evidence: %s\n' "$evidence"
mkdir -p -m 700 "$evidence/runtime" "$evidence/home" "$evidence/DragDropHost.app/Contents/MacOS"
runtime=$evidence/runtime
socket=$evidence/infinify.sock
state=$evidence/scene.json
config=$evidence/config.toml
: > "$config"
nonce=$(od -An -N32 -tx1 /dev/urandom | tr -d ' \n')
(umask 077; printf '%s\n' "$nonce" > "$evidence/nonce")
drop_file=$evidence/drop.txt
(umask 077; printf '%s' "$nonce" > "$drop_file")
chmod 600 "$drop_file"
cat > "$evidence/DragDropHost.app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleIdentifier</key><string>org.infinify.native-drag-drop-fixture</string>
  <key>CFBundleName</key><string>NativeDragDropFixture</string>
  <key>CFBundleExecutable</key><string>NativeDragDropFixture</string>
  <key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
host_app=$evidence/DragDropHost.app
host_executable=$host_app/Contents/MacOS/NativeDragDropFixture
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror \
  native/fixture/native-drag-drop-host.m -framework AppKit -o "$host_executable"

host_pid=
infinify_pid=
quit_infinify() {
  [ -n "$infinify_pid" ] || return 0
  "$app" msg --socket "$socket" action quit >/dev/null 2>&1 || true
  n=0
  while kill -0 "$infinify_pid" 2>/dev/null && [ "$n" -lt 60 ]; do sleep .1; n=$((n+1)); done
  if kill -0 "$infinify_pid" 2>/dev/null; then kill "$infinify_pid" 2>/dev/null || true; fi
  n=0
  while kill -0 "$infinify_pid" 2>/dev/null && [ "$n" -lt 30 ]; do sleep .1; n=$((n+1)); done
  if kill -0 "$infinify_pid" 2>/dev/null; then kill -KILL "$infinify_pid" 2>/dev/null || true; fi
  wait "$infinify_pid" 2>/dev/null || true
  infinify_pid=
}
stop_host() {
  [ -n "$host_pid" ] || return 0
  kill -TERM "$host_pid" 2>/dev/null || true
  n=0
  while kill -0 "$host_pid" 2>/dev/null && [ "$n" -lt 30 ]; do sleep .1; n=$((n+1)); done
  if kill -0 "$host_pid" 2>/dev/null; then kill -KILL "$host_pid" 2>/dev/null || true; fi
  wait "$host_pid" 2>/dev/null || true
  host_pid=
}
cleanup() {
  result=$?
  trap - EXIT INT TERM HUP
  quit_infinify
  if [ -f "$evidence/cursor.json" ]; then python3 "$driver" restore-cursor "$evidence" >/dev/null 2>&1 || true; fi
  if [ -f "$evidence/native-before.json" ] && [ -n "$host_pid" ]; then
    python3 "$driver" verify-restored "$evidence" --runtime "$runtime" --nonce-file "$evidence/nonce" --host-pid "$host_pid" --timeout 6 \
      >"$evidence/cleanup-restore.log" 2>&1 || { cat "$evidence/cleanup-restore.log" >&2; result=1; }
  fi
  stop_host
  return "$result"
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP

"$host_executable" "$payload" "$runtime" "$evidence/nonce" "$evidence" "$drop_file" >"$evidence/host.log" 2>&1 &
host_pid=$!
n=0
while ! grep -q '^READY ' "$evidence/host.log" 2>/dev/null && [ "$n" -lt 100 ]; do sleep .1; n=$((n+1)); done
grep -q '^READY ' "$evidence/host.log" || { cat "$evidence/host.log" >&2; exit 1; }
[ -S "$runtime/v2.sock" ] || { echo 'FAIL: cooperative fixture did not expose its v2 helper socket' >&2; exit 1; }
python3 "$driver" baseline "$evidence" --runtime "$runtime" --nonce-file "$evidence/nonce" --host-pid "$host_pid"

: > "$evidence/infinify.log"
# Existing scoped benchmark ordering keeps only the owned canvas/windows above
# unrelated apps. It changes panel ordering/discovery, not AppKit drag routing.
INFINIFY_DEBUG=1 INFINIFY_DEBUG_BENCH=1 INFINIFY_DEBUG_NATIVE_BENCH=1 CFFIXED_USER_HOME="$evidence/home" "$app" \
  --windowed 1100x700 --state "$state" --config "$config" --socket "$socket" \
  --no-hover-forwarding --debug-pointer --only-pid "$host_pid" --native-helper "$runtime" "$evidence/nonce" \
  2>"$evidence/infinify.log" &
infinify_pid=$!
n=0
while [ ! -S "$socket" ] && [ "$n" -lt 100 ]; do sleep .1; n=$((n+1)); done
[ -S "$socket" ] || { echo "FAIL: Infinify did not open its IPC socket: $(cat "$evidence/infinify.log")" >&2; exit 1; }

python3 "$driver" run "$evidence" --runtime "$runtime" --nonce-file "$evidence/nonce" --host-pid "$host_pid" \
  --app-pid "$infinify_pid" --app "$app" --socket "$socket"
quit_infinify
python3 "$driver" verify-restored "$evidence" --runtime "$runtime" --nonce-file "$evidence/nonce" --host-pid "$host_pid" --timeout 8
stop_host
echo 'PASS: native NSDraggingSession delivered the nonce file URL and transformed local drop location to the exact owned AppKit destination; captured replicas remain unsupported.'
