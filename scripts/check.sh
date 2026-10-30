#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# The one-command guardrail: format, lint, Rust tests, the app build, the packaging test and every headless
# end-to-end script, in that order. It stops at the first failure, names it, and prints a summary table
# (step, result, seconds) on every exit.
#
#   ./scripts/check.sh
#   INFINIFY_SIGN_IDENTITY="Developer ID Application: ..." ./scripts/check.sh
#
# INFINIFY_SIGN_IDENTITY is passed through to the app build (ad hoc signing when it is unset or empty) and to no other
# step: the packaging test asserts on an ad hoc build and fails when the variable is set, so later steps run without it.
# Read-only on the host except for the build outputs under target/: the e2e scripts run with no arguments, so the live
# ones, which start disposable fixture windows or need a guest, print "LIVE NOT RUN" and are reported as skipped. A
# script that declines to run here with a line starting "<name>: SKIPPED" (the launcher test when an Infinify process
# is running) is reported as skipped as well.
# Do not edit tracked or untracked source files while it runs: the app build refuses to publish if its inputs change.
set -u
cd "$(dirname "$0")/.." || exit 2
root=$(pwd -P)
sign_identity=${INFINIFY_SIGN_IDENTITY:--}
unset INFINIFY_SIGN_IDENTITY

if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
  printf '%s\n' 'check: needs an Apple Silicon Mac (the app build and the e2e scripts are macOS arm64 only)' >&2
  exit 2
fi
for tool in cargo python3 xcrun; do
  command -v "$tool" >/dev/null 2>&1 || { printf 'check: %s is not on PATH\n' "$tool" >&2; exit 2; }
done

mkdir -p "$root/target"
work=$(mktemp -d "$root/target/.check.XXXXXX") || exit 2
rows=$work/rows            # one "name|result|seconds" line per step, in order
: > "$rows"
passed=0 skipped=0 failed=0
started=$(date +%s)

# Remove the scratch directory on every exit; a signal prints the summary of what had run.
finish() {
  code=$1
  trap - EXIT HUP INT TERM
  summary
  rm -rf "$work"
  exit "$code"
}
trap 'finish $?' EXIT
trap 'printf "\ncheck: interrupted\n" >&2; finish 130' HUP INT TERM

summary() {
  total=$(( $(date +%s) - started ))
  printf '\n%s\n' '== summary =='
  printf '%-52s %-8s %7s\n' STEP RESULT SECONDS
  while IFS='|' read -r name result seconds; do
    printf '%-52s %-8s %7s\n' "$name" "$result" "$seconds"
  done < "$rows"
  if [ -n "${pending:-}" ]; then
    printf '%-52s %-8s %7s\n' "$pending" ABORTED -
  fi
  printf '%-52s %-8s %7s\n' total "pass $passed skip $skipped fail $failed" "$total"
}

record() { # name result seconds
  printf '%s|%s|%s\n' "$1" "$2" "$3" >> "$rows"
}

stop() { # name seconds message...
  name=$1 seconds=$2
  shift 2
  record "$name" FAIL "$seconds"
  failed=$((failed + 1))
  pending=
  printf '\ncheck: FAILED at "%s": %s\n' "$name" "$*" >&2
  finish 1
}

# step NAME COMMAND...: run a command with its output streaming; stop the whole check if it fails.
step() {
  name=$1
  shift
  pending=$name
  printf '\n== %s ==\n+ %s\n' "$name" "$*"
  t0=$(date +%s)
  "$@"
  status=$?
  t1=$(date +%s)
  if [ "$status" -ne 0 ]; then
    stop "$name" $((t1 - t0)) "'$*' exited $status"
  fi
  record "$name" PASS $((t1 - t0))
  passed=$((passed + 1))
  pending=
}

step '1 cargo fmt --check' cargo fmt --all -- --check
step '2 cargo clippy' cargo clippy --workspace --all-targets -- -D warnings
step '3 cargo test' cargo test --workspace --no-fail-fast
step '4 app build' env "INFINIFY_SIGN_IDENTITY=$sign_identity" ./scripts/build-app.sh
step '5 packaging test' python3 -I scripts/test-build-app-package.py

# 6: every tests/e2e/*.sh, sorted bytewise, with no arguments.
scripts=$(LC_ALL=C ls tests/e2e/*.sh 2>/dev/null)
if [ -z "$scripts" ]; then
  stop '6 e2e' 0 'no tests/e2e/*.sh found'
fi
for script in $scripts; do
  name="6 e2e/${script#tests/e2e/}"
  pending=$name
  printf '\n== %s ==\n' "$name"
  out=$work/out
  t0=$(date +%s)
  if [ -x "$script" ]; then "./$script" > "$out" 2>&1; else sh "$script" > "$out" 2>&1; fi
  status=$?
  t1=$(date +%s)
  cat "$out"
  if grep -q 'LIVE NOT RUN' "$out"; then
    record "$name" SKIP $((t1 - t0))
    skipped=$((skipped + 1))
  elif [ "$status" -ne 0 ]; then
    stop "$name" $((t1 - t0)) "$script exited $status"
  elif grep -q '^[A-Za-z0-9_.-]*: SKIPPED' "$out"; then
    record "$name" SKIP $((t1 - t0))
    skipped=$((skipped + 1))
  else
    record "$name" PASS $((t1 - t0))
    passed=$((passed + 1))
  fi
  pending=
done

printf '\ncheck: all steps passed (%s passed, %s skipped)\n' "$passed" "$skipped"
finish 0
