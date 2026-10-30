#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# The launch daemon's and the Dock reloader's decisions (native/dock-helper/Daemon/DWLoaddRequest.m, native/app/System/DWDockReloader.m and the
# login-mode record): caller requirement, accepted and refused requests, artifact checks, Sunlight's crash guard, the remembered
# pause, the reloader's transitions against a fake Dock, the staged-payload rule (the root-owned copy the Dock opens), and the
# hardened-runtime rule for the caller, checked on real processes signed ad hoc with and without the flag and entitlements, with
# a DYLD_INSERT_LIBRARIES injection showing what the flag keeps out. No daemon, root, Dock, window or sudo is involved.
#   native-daemon.sh [SIGNED_INFINIFY_APP]  with a team-signed bundle, the caller requirement is also checked against it.
set -eu
cd "$(dirname "$0")/../.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/infinify-native-daemon.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT HUP INT TERM
. scripts/native-includes.sh
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -O2 -fobjc-arc -Wall -Wextra -Werror $native_includes \
  tests/native/dock-helper/Daemon/DWLoaddRequestTests.m native/dock-helper/Daemon/DWLoaddRequest.m \
  -framework Foundation -framework Security -o "$task_dir/loadd-request"
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -O2 -fobjc-arc -Wall -Wextra -Werror $native_includes \
  tests/native/app/System/DWDockReloaderTests.m native/app/System/DWDockReloader.m native/app/System/DWNativeDesktopCLI.m native/app/System/DWLoaderService.m \
  native/app/System/DWLoginItem.m native/dock-helper/Daemon/DWLoaddRequest.m \
  -framework AppKit -framework ServiceManagement -framework Security -o "$task_dir/dock-reload"
"$task_dir/loadd-request" ${1:+"$1"}
"$task_dir/dock-reload"

# The caller rule on live processes. The binary under test is the regression itself (--self-caller judges its own audit token);
# ad-hoc signatures can carry the runtime flag and these entitlements, so no identity is needed to see the decision.
cat > "$task_dir/inject.c" <<'C'
#include <stdio.h>
#include <stdlib.h>
__attribute__((constructor)) static void injected(void) { const char *m = getenv("INJECT_MARKER"); if (m) { FILE *f = fopen(m, "w"); if (f) { fputs("injected\n", f); fclose(f); } } }
C
xcrun clang -arch arm64 -dynamiclib -o "$task_dir/inject.dylib" "$task_dir/inject.c"
codesign --force --sign - "$task_dir/inject.dylib" 2>/dev/null
caller_fails=0; caller_checks=0
entitlements() { { printf '%s\n' '<?xml version="1.0" encoding="UTF-8"?><plist version="1.0"><dict>'; for key in "$@"; do printf '<key>%s</key><true/>\n' "$key"; done; printf '%s\n' '</dict></plist>'; } > "$task_dir/entitlements.plist"; }
# expect_caller LABEL ENV(clean|dyld) EXPECTED(accepted|refused) INJECTED(yes|no) CODESIGN-OPTIONS...: the live check on a binary signed so,
# started with or without DYLD_INSERT_LIBRARIES; INJECTED says whether the dylib's constructor ran in it.
expect_caller() {
  label=$1; mode=$2; want=$3; injected=$4; shift 4
  cp "$task_dir/loadd-request" "$task_dir/caller"
  codesign --force --sign - "$@" "$task_dir/caller" 2>/dev/null
  rm -f "$task_dir/marker"
  set +e
  if [ "$mode" = dyld ]; then INJECT_MARKER="$task_dir/marker" DYLD_INSERT_LIBRARIES="$task_dir/inject.dylib" "$task_dir/caller" --self-caller > "$task_dir/caller.out" 2>&1
  else INJECT_MARKER="$task_dir/marker" "$task_dir/caller" --self-caller > "$task_dir/caller.out" 2>&1; fi
  status=$?; set -e
  got=refused; [ "$status" -ne 0 ] || got=accepted
  ran=no; [ ! -e "$task_dir/marker" ] || ran=yes
  caller_checks=$((caller_checks + 1))
  if [ "$got" = "$want" ] && [ "$ran" = "$injected" ]; then printf 'ok   caller %s, %s environment: %s (%s); injected: %s\n' "$label" "$mode" "$got" "$(sed -n 1p "$task_dir/caller.out" | cut -c1-100)" "$ran"
  else caller_fails=$((caller_fails + 1)); printf 'FAIL caller %s, %s environment: %s (wanted %s), injected %s (wanted %s): %s\n' "$label" "$mode" "$got" "$want" "$ran" "$injected" "$(cat "$task_dir/caller.out")"; fi
}
# Without the flag, or with an entitlement that gives the hardening back, the daemon refuses whatever the environment.
expect_caller 'signed without the hardened runtime' clean refused no
expect_caller 'signed without the hardened runtime' dyld refused yes
# With it, a clean start is accepted. The flag alone does not keep a DYLD_INSERT_LIBRARIES dylib out on a Mac with SIP debugging
# restrictions off (this one, the guest and the owner's): the dylib is injected (yes below), and the daemon refuses the caller for the variable.
expect_caller 'hardened runtime' clean accepted no -o runtime
expect_caller 'hardened runtime' dyld refused yes -o runtime
entitlements com.apple.security.get-task-allow
expect_caller 'hardened runtime with get-task-allow' clean refused no -o runtime --entitlements "$task_dir/entitlements.plist"
entitlements com.apple.security.cs.allow-dyld-environment-variables
expect_caller 'hardened runtime with allow-dyld-environment-variables' clean refused no -o runtime --entitlements "$task_dir/entitlements.plist"
entitlements com.apple.security.cs.disable-library-validation
expect_caller 'hardened runtime with disable-library-validation' clean refused no -o runtime --entitlements "$task_dir/entitlements.plist"
entitlements com.apple.security.cs.allow-jit
expect_caller 'hardened runtime with allow-jit only' clean accepted no -o runtime --entitlements "$task_dir/entitlements.plist"
if [ "$caller_fails" -ne 0 ]; then printf 'native-daemon: %s of %s live caller checks FAILED\n' "$caller_fails" "$caller_checks" >&2; exit 1; fi
printf 'native-daemon: %s live caller checks passed\n' "$caller_checks"
