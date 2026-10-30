#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Headless regression of the Dock helper payload and its C client. DWPayloadRestoreIdentityTests.m and DWPayloadForwardOperationsTests.m compile
# the real payload (native/dock-helper/Payload/DWPayload.m) with substituted native calls: journal before mutation, identity fences, restore
# re-basing, handoff recovery, Space and veil rules, outcomes and native-call counts. DWHelperClientTests.py builds the C client
# (DWHelperClient.c) and runs it against a fake peer on a temporary socket. No window, Dock, root, setting or permission is touched; none
# of this is native compositing evidence.
set -eu
cd "$(dirname "$0")/../.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/infinify-privileged-regression.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT HUP INT TERM
native_includes='-Icrates/desktop/include -Inative/app -Inative/app/Desktop -Inative/app/Canvas -Inative/app/Windows -Inative/app/Input -Inative/app/CompositorMode -Inative/app/Navigation -Inative/app/System -Inative/app/Support -Inative/dock-helper/Client -Inative/dock-helper/Daemon -Inative/dock-helper/Loader -Inative/dock-helper/Payload'
for test in DWPayloadRestoreIdentityTests DWPayloadForwardOperationsTests; do
  xcrun clang -arch arm64 -mmacosx-version-min=26.0 -O2 -fobjc-arc -Wall -Wextra -Werror $native_includes \
    "tests/native/dock-helper/Payload/$test.m" -framework AppKit -o "$task_dir/$test"
  "$task_dir/$test"
done
python3 -I tests/native/dock-helper/Client/DWHelperClientTests.py
printf '%s\n' 'PASS: Dock helper payload and C client regressions (substituted native calls and a fake peer; not native evidence)'
