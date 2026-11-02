# shellcheck shell=sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Sourced by the stability live-guest scripts (native-frame-cap.sh, native-snapshot-race.sh, capture-stale-frame.sh,
# zero-screen-keys.sh); not a test of its own. Conventions are those of tests/e2e/compositor-dnd.sh: nothing runs without
# --live-guest (the script prints LIVE NOT RUN), the guest is reached only through the command prefix in $GUEST_SSH, and
# this machine only builds fixtures and keeps evidence (target/ipc). In the guest everything happens in one fresh
# directory, /tmp/infinify-NAME.PID: the fixtures and stability-guest-driver.py are copied there (tar over $GUEST_SSH),
# the driver starts the fixtures and Infinify itself and ends them on every exit, and the directory's processes are
# signalled and the directory removed on this script's exit. No setting, Dock, SIP or other window is touched.
#
#   GUEST_SSH       command prefix that runs one shell command string in the guest, e.g. "ssh -o BatchMode=yes admin@GUEST"
#   GUEST_INFINIFY  optional guest path of the Infinify executable to test, default
#                   $HOME/infinify-port/target/app/Infinify.app/Contents/MacOS/Infinify (expanded by the guest's shell)
#
# Exit status: 0 every check held; 1 a check failed; 2 usage; 3 not run or not reached (nothing failed).

live_guest_begin() {
  live_name=$1; live_what=$2; shift 2
  case ${1:-} in
    '') echo "LIVE NOT RUN: pass --live-guest with GUEST_SSH set for a disposable guest ($live_what)."; exit 0 ;;
    --live-guest) shift ;;
    *) echo "Usage: $0 [--live-guest]" >&2; exit 2 ;;
  esac
  [ "$#" -eq 0 ] || { echo "Usage: $0 [--live-guest]" >&2; exit 2; }
  if [ -z "${GUEST_SSH:-}" ]; then
    echo 'NOT RUN: GUEST_SSH must name the disposable guest; this script never runs native input or window changes on the machine it is started from.' >&2
    exit 3
  fi
  test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
  root=$PWD
  mkdir -p "$root/target/ipc"
  evidence=$(mktemp -d "$root/target/ipc/$live_name.XXXXXX")
  mkdir -p "$evidence/bin"
  printf 'Evidence: %s\n' "$evidence"
  gwork=/tmp/infinify-$live_name.$$
  # Left unexpanded here on purpose: the guest's shell expands $HOME.
  # shellcheck disable=SC2016
  ginf=${GUEST_INFINIFY:-'$HOME/infinify-port/target/app/Infinify.app/Contents/MacOS/Infinify'}
  trap live_guest_end EXIT
  trap 'exit 1' INT TERM HUP
  live_gs "test -x $ginf" || { echo "NOT RUN: no Infinify executable at $ginf in the guest (copy a build there, or set GUEST_INFINIFY)." >&2; exit 3; }
  live_gs '! pgrep -x Infinify >/dev/null' || { echo 'NOT RUN: an Infinify is already running in the guest; nothing was started.' >&2; exit 3; }
  [ "$(live_gs 'defaults read com.apple.WindowManager GloballyEnabled 2>/dev/null || echo 0')" != 1 ] || { echo 'NOT RUN: Stage Manager is on in the guest (read, never written).' >&2; exit 3; }
  live_gs "rm -rf $gwork && mkdir -m 700 $gwork"
}
live_gs() { $GUEST_SSH "$1"; }
# Copy files from this machine into the guest work directory (flat), as one tar stream over $GUEST_SSH.
live_guest_push() {
  # Each -C is absolute: tar applies them one after another. Split on purpose (no spaces in these paths).
  # shellcheck disable=SC2046
  set -- $(for file in "$@"; do if [ "${file#/}" != "$file" ]; then dir=$(dirname "$file"); else dir=$root/$(dirname "$file"); fi; printf ' -C %s %s' "$dir" "$(basename "$file")"; done)
  tar -cf - "$@" | live_gs "tar -C $gwork -xf -"
}
# Build an Objective-C or C fixture into the evidence directory, ad hoc signed.
live_guest_build() {
  out=$evidence/bin/$1; shift
  xcrun clang -arch arm64 -mmacosx-version-min=26.0 -Wall -Wextra -Werror "$@" -o "$out"
  codesign -s - -f "$out" >/dev/null 2>&1
}
# Run one mode of the guest driver; its lines stream here and into evidence/driver.log.
# Call it as `if live_guest_drive MODE; then ...`: its status is 0, 1 or 3 as above.
live_guest_drive() {
  : > "$evidence/driver.$1.log"
  live_gs "cd $gwork && /usr/bin/python3 $gwork/stability-guest-driver.py $1 $gwork $ginf" 2>&1 | tee "$evidence/driver.$1.log" || true
  cat "$evidence/driver.$1.log" >> "$evidence/driver.log"
  status=$(tail -1 "$evidence/driver.$1.log" | sed -n 's/^PASS: .*/0/p')
  if [ "$status" = 0 ]; then return 0; fi
  if grep -q '^FAIL: ' "$evidence/driver.$1.log"; then return 1; fi
  if grep -q '^NOT REACHED: ' "$evidence/driver.$1.log"; then return 3; fi
  return 1
}
live_guest_end() {
  result=$?
  trap - EXIT INT TERM HUP
  if [ -n "${gwork:-}" ]; then
    live_gs "test -d $gwork/evidence && tar -C $gwork -cf - evidence" 2>/dev/null | tar -C "$evidence" -xf - 2>/dev/null || true
    # Only this run's own processes: every one has the work directory in its command line.
    # The bracket keeps the pattern from matching the guest shell that runs pkill.
    pattern="[/]${gwork#/}/"
    live_gs "pkill -f '$pattern' 2>/dev/null; sleep 1; pkill -9 -f '$pattern' 2>/dev/null; rm -rf $gwork; true" >/dev/null 2>&1 || true
  fi
  return "$result"
}
