#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Headless regression of the Dock helper payload and its C client. restore_identity_test.m and forward-operations-test.m compile
# the real payload (native/privileged/payload.m) with substituted native calls: journal before mutation, identity fences, restore
# re-basing, handoff recovery, Space and veil rules, outcomes and native-call counts. client_protocol_test.py builds the C client
# (dwclient.c) and runs it against a fake peer on a temporary socket. No window, Dock, root, setting or permission is touched; none
# of this is native compositing evidence.
set -eu
cd "$(dirname "$0")/../.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
task_dir=$(mktemp -d "${TMPDIR:-/tmp}/infinify-privileged-regression.XXXXXX")
trap 'rm -rf "$task_dir"' EXIT HUP INT TERM
for test in restore_identity_test forward-operations-test; do
  xcrun clang -arch arm64 -mmacosx-version-min=26.0 -O2 -fobjc-arc -Wall -Wextra -Werror \
    "native/privileged/$test.m" -framework AppKit -o "$task_dir/$test"
  "$task_dir/$test"
done
python3 -I native/privileged/client_protocol_test.py
printf '%s\n' 'PASS: Dock helper payload and C client regressions (substituted native calls and a fake peer; not native evidence)'
