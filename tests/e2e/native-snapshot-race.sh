#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Windows closing while native frames name them, live, in a disposable guest. A scoped native run presents three of the
# cooperative host's windows; eight more are in the helper's list but hidden (HostFixture --churn 8). During each of eight
# camera-pan bursts the host shows one of them and closes it 500, 620, ... 1340 ms later (around adoption time), so frames that name it are in flight
# when it goes. Checked: presentation never ends, no closed window stays in the frame, the remaining windows stay placed,
# and at rest after each close at most two frames go out in 1.5 s (a snapshot retry every 250 ms would send six). Whether
# the helper ever answered DW2_SNAPSHOT ("its original could not be read") for a closing window is reported: when it never
# did, the run ends NOT REACHED (exit 3), since the snapshot-specific retry path was then not exercised.
# See tests/e2e/live-guest-lib.sh for GUEST_SSH, GUEST_INFINIFY and the exit status.
set -eu
cd "$(dirname "$0")/../.."
. tests/e2e/live-guest-lib.sh
live_guest_begin native-snapshot-race 'snapshot race: windows of the cooperative host fixture close under native frames' "$@"
. scripts/native-includes.sh
# shellcheck disable=SC2086
live_guest_build host -O2 -fobjc-arc $helper_includes tests/native/dock-helper/Payload/HostFixture.m -framework AppKit
# shellcheck disable=SC2086
live_guest_build payload-arm64.dylib -O2 -fobjc-arc $helper_includes -dynamiclib -Wl,-install_name,@rpath/payload-arm64.dylib \
  native/dock-helper/Payload/DWPayload.m -framework AppKit
live_guest_push "$evidence/bin/host" "$evidence/bin/payload-arm64.dylib" tests/e2e/stability-guest-driver.py
if live_guest_drive snapshot-race; then status=0; else status=$?; fi
echo "Result $status; evidence in $evidence"; exit "$status"
