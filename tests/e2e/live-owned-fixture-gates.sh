#!/bin/sh
# Process-boundary regression for launcher opt-in gates. All commands run in a
# temporary copied harness; no project binary or native fixture is executed.
set -eu
cd "$(dirname "$0")/../.."

root=$PWD
harness=$(mktemp -d "${TMPDIR:-/tmp}/infinify-live-gates.XXXXXX")
trap 'rm -rf "$harness"' EXIT HUP INT TERM
mkdir -p "$harness/tests/e2e" "$harness/scripts" "$harness/bin"
for name in native-resize captured-windows desktop-app live-surfaces native-families native-fixture privileged-fixture; do
  cp "$root/tests/e2e/$name.sh" "$harness/tests/e2e/"
done

for name in resize captured-windows surfaces families privileged; do
  printf '%s\n' '#!/bin/sh' "printf 'build-$name\\n' >> \"\$GATE_LOG\"" > "$harness/scripts/build-$name.sh"
  chmod +x "$harness/scripts/build-$name.sh"
done
cat > "$harness/scripts/build-app.sh" <<'SH'
#!/bin/sh
set -eu
printf 'build-app\n' >> "$GATE_LOG"
mkdir -p target/app/Infinify.app/Contents/MacOS target/app/Infinify.app/Contents
printf '%s\n' '#!/bin/sh' 'printf "app|%s\\n" "$*" >> "$GATE_LOG"' '[ "${1:-}" != --demo-probe-guard ] || exit 2' > target/app/Infinify.app/Contents/MacOS/Infinify
chmod +x target/app/Infinify.app/Contents/MacOS/Infinify
: > target/app/Infinify.app/Contents/Info.plist
SH
chmod +x "$harness/scripts/build-app.sh"

cat > "$harness/bin/python3" <<'SH'
#!/bin/sh
printf 'python3|%s\n' "$*" >> "$GATE_LOG"
case ${1:-} in -) cat >/dev/null ;; esac
SH
cat > "$harness/bin/cargo" <<'SH'
#!/bin/sh
set -eu
printf 'cargo|%s\n' "$*" >> "$GATE_LOG"
mkdir -p target/debug
printf '%s\n' '#!/bin/sh' 'printf "probe|%s\\n" "$*" >> "$GATE_LOG"' 'printf "{}\\n"' > target/debug/driftwm-native-probe
chmod +x target/debug/driftwm-native-probe
SH
cat > "$harness/bin/xcrun" <<'SH'
#!/bin/sh
set -eu
printf 'xcrun|%s\n' "$*" >> "$GATE_LOG"
out=
while [ "$#" -gt 0 ]; do
  if [ "$1" = -o ]; then out=$2; break; fi
  shift
done
if [ -n "$out" ]; then
  mkdir -p "$(dirname "$out")"
  printf '%s\n' '#!/bin/sh' 'printf "native|%s\\n" "$*" >> "$GATE_LOG"' > "$out"
  chmod +x "$out"
fi
SH
for name in plutil codesign; do
  printf '%s\n' '#!/bin/sh' "printf '$name|%s\\n' \"\$*\" >> \"\$GATE_LOG\"" > "$harness/bin/$name"
done
chmod +x "$harness/bin/"*

export PATH="$harness/bin:$PATH"
export GATE_LOG="$harness/calls.log"
cd "$harness"

fail() { echo "FAIL: $*" >&2; exit 1; }
assert_line() { grep -Fqx "$1" "$GATE_LOG" || fail "missing call: $1"; }
assert_prefix() { grep -Fq "$1" "$GATE_LOG" || fail "missing call containing: $1"; }
assert_rejected() {
  : > "$GATE_LOG"
  if "$@" >/dev/null 2>&1; then
    fail "$1 accepted malformed arguments"
  else
    status=$?
    [ "$status" -eq 2 ] || fail "$1 malformed arguments returned $status"
  fi
  [ ! -s "$GATE_LOG" ] || fail "$1 ran a command before rejecting malformed arguments"
}

for name in native-resize captured-windows desktop-app live-surfaces native-families native-fixture privileged-fixture; do
  : > "$GATE_LOG"
  output=$("./tests/e2e/$name.sh")
  printf '%s\n' "$output" | grep -Fq 'LIVE NOT RUN:' || fail "$name default lacked live-not-run receipt"
  grep -Eq '^(build-|cargo\|)' "$GATE_LOG" || fail "$name default did not build"
  grep -Eq '^(python3|app|probe|native)\|' "$GATE_LOG" && fail "$name default crossed live boundary"
  grep -Fq 'cargo|test ' "$GATE_LOG" && fail "$name default ran a native Rust integration test"

  : > "$GATE_LOG"
  if "./tests/e2e/$name.sh" --unknown >/dev/null 2>&1; then
    fail "$name accepted unknown option"
  else
    status=$?
    [ "$status" -eq 2 ] || fail "$name unknown option returned $status"
  fi
  [ ! -s "$GATE_LOG" ] || fail "$name ran a command before rejecting unknown option"
done

assert_rejected ./tests/e2e/native-resize.sh --live-owned-fixture one two
assert_rejected ./tests/e2e/captured-windows.sh --live-owned-fixture --bad-mode
assert_rejected ./tests/e2e/desktop-app.sh --live-owned-fixture extra
assert_rejected ./tests/e2e/live-surfaces.sh --live-owned-fixture one two
assert_rejected ./tests/e2e/native-families.sh --live-owned-fixture --bad-mode
assert_rejected ./tests/e2e/native-fixture.sh --live-owned-fixture one two
assert_rejected ./tests/e2e/privileged-fixture.sh --live-owned-fixture extra

: > "$GATE_LOG"
./tests/e2e/native-resize.sh --live-owned-fixture resize-out
assert_line 'python3|native/resize/e2e.py resize-out'

: > "$GATE_LOG"
./tests/e2e/captured-windows.sh --live-owned-fixture captured-out
assert_line 'python3|- captured-out'

: > "$GATE_LOG"
./tests/e2e/captured-windows.sh --live-owned-fixture --demo-input-only demo-out
assert_prefix 'native|'
assert_prefix 'target/captured-windows/captured-windows demo-out/run-'

: > "$GATE_LOG"
./tests/e2e/desktop-app.sh --live-owned-fixture
assert_prefix 'app|--demo-probe '
assert_prefix 'app|--demo-probe-guard '

: > "$GATE_LOG"
./tests/e2e/live-surfaces.sh --live-owned-fixture surfaces-out
assert_line 'python3|- surfaces-out'

: > "$GATE_LOG"
./tests/e2e/native-families.sh --live-owned-fixture --lifecycle-only families-out
assert_line 'python3|native/families/run.py families-out --lifecycle-only'

: > "$GATE_LOG"
./tests/e2e/native-fixture.sh --live-owned-fixture fixture.json
assert_line 'cargo|test -p driftwm-macos-backend --test native_fixture --locked'
assert_line 'probe|probe'
assert_line 'python3|- fixture.json'

: > "$GATE_LOG"
./tests/e2e/privileged-fixture.sh --live-owned-fixture
assert_line 'python3|native/privileged/fixture_test.py'

echo 'PASS: seven launchers build only by default, reject malformed opt-in, and forward legacy live arguments'
