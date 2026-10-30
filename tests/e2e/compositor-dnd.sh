#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Real-HID drag-and-drop between two disposable AppKit fixtures while Infinify's Dock helper draws them away from their
# native frames at several canvas zooms (compositor mode). Runs only in a disposable guest reached through $DND_GSSH
# and $DND_GSCP; Infinify must already be running there in compositor mode (this script never starts, stops or
# reloads Infinify or the Dock, and changes no setting). It starts two fixture processes of its own and ends them on
# every exit. See native/desktop/NATIVE-DRAG-ROUTING.md ("Compositor mode") for what the numbers mean.
#
#   DND_GSSH   command prefix that runs one shell command string in the guest, e.g. "ssh -o BatchMode=yes admin@GUEST"
#   DND_GSCP   command copying SRC to guest:DST, e.g. a scp wrapper that rewrites the guest: prefix
#   DND_INFINIFY_LOG  optional guest path of Infinify's INFINIFY_DEBUG log, to record the taps' own lines per drag
#   DND_SCREEN        guest logical display size, default 1920x1200
set -eu
cd "$(dirname "$0")/../.."
case ${1:-} in
  '') echo 'LIVE NOT RUN: pass --live-guest [pair|band|outside [ZOOM...]] with DND_GSSH and DND_GSCP set for a disposable guest running Infinify in compositor mode.'; exit 0 ;;
  --live-guest) shift ;;
  *) echo "Usage: $0 [--live-guest [pair|band|outside [ZOOM...]]]" >&2; exit 2 ;;
esac
mode=${1:-pair}
[ "$#" -gt 0 ] && shift
case $mode in pair|band|outside) ;; *) echo "Usage: $0 --live-guest [pair|band|outside [ZOOM...]]" >&2; exit 2 ;; esac
if [ -z "${DND_GSSH:-}" ] || [ -z "${DND_GSCP:-}" ]; then
  echo 'NOT RUN: DND_GSSH and DND_GSCP must name the disposable guest; this script never runs native input on the machine it is started from.' >&2
  exit 3
fi
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64

root=$PWD
mkdir -p "$root/target/ipc"
evidence=$(mktemp -d "$root/target/ipc/compositor-dnd.XXXXXX")
printf 'Evidence: %s\n' "$evidence"
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror \
  native/fixture/native-dnd-probe.m -framework AppKit -framework QuartzCore -o "$evidence/compositor-dnd-probe"
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -O1 -Wall -Wextra -Werror \
  tests/e2e/compositor-dnd-hid.c -framework ApplicationServices -framework CoreFoundation -o "$evidence/compositor-dnd-hid"
codesign -s - -f "$evidence/compositor-dnd-probe" "$evidence/compositor-dnd-hid" >/dev/null 2>&1

gs() { $DND_GSSH "$1"; }
logs='$HOME/dnd-fixture-log'
cleanup() {
  result=$?
  trap - EXIT INT TERM HUP
  gs "pkill -x compositor-dnd-probe 2>/dev/null; rm -rf $logs /tmp/compositor-dnd-probe /tmp/compositor-dnd-hid /tmp/compositor-dnd-*.png; true" >/dev/null 2>&1 || true
  return "$result"
}
trap cleanup EXIT
trap 'exit 1' INT TERM HUP

# Infinify must already be placing windows; refuse to measure an idle desktop.
inf=${DND_INFINIFY:-'$HOME/Applications/Infinify.app/Contents/MacOS/Infinify'}
export DND_INFINIFY=$inf
outputs=$(gs "$inf msg --json state" | python3 -c 'import json,sys; print(len(json.load(sys.stdin)["Ok"]["State"]["outputs"]))' 2>/dev/null || echo 0)
if [ "$outputs" -lt 1 ]; then echo 'NOT RUN: Infinify is not answering `msg state` with an output in the guest.' >&2; exit 3; fi

$DND_GSCP "$evidence/compositor-dnd-probe" guest:/tmp/compositor-dnd-probe
$DND_GSCP "$evidence/compositor-dnd-hid" guest:/tmp/compositor-dnd-hid
gs "pkill -x compositor-dnd-probe 2>/dev/null; rm -rf $logs; mkdir -p $logs $logs/files; printf FILE > $logs/files/payload.txt; chmod +x /tmp/compositor-dnd-probe /tmp/compositor-dnd-hid; true"
gs "nohup /tmp/compositor-dnd-probe P1 100 150 520 420 $logs/p1.jsonl $logs/files/payload.txt >/dev/null 2>&1 &"
sleep 1.5
gs "nohup /tmp/compositor-dnd-probe P2 760 150 520 420 $logs/p2.jsonl $logs/files/payload.txt >/dev/null 2>&1 &"
sleep 3
for n in p1 p2; do
  gs "grep -q '\"ready\"' $logs/$n.jsonl" || { echo "FAIL: fixture $n did not start in the guest" >&2; exit 1; }
done

# The tilde stays literal on purpose: the driver puts this path into commands it runs in the guest, whose shell expands it.
# shellcheck disable=SC2088
DND_HID=/tmp/compositor-dnd-hid DND_LOG_DIR='~/dnd-fixture-log' python3 tests/e2e/compositor-dnd-driver.py "$mode" "$evidence" "$@"
echo "PASS: compositor-mode $mode run finished; evidence in $evidence (guest-observed, disposable fixtures only; not third-party acceptance)."
