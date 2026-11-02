#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# The native presenter's whole-family frame cap, live, in a disposable guest. A scoped native run (--windowed --only-pid
# with --native-helper, as tests/e2e/scoped-native.sh launches one) presents the cooperative host's four windows with
# INFINIFY_DEBUG=1 INFINIFY_DEBUG_NATIVE_MAX_RECORDS=3, below the window count: presentation must go on, frames carry
# exactly three records, a focused window that was left out joins the frame and is drawn by the window server at its
# placement, the family that leaves stays at its last native placement, each omitted family is logged once and nothing
# is resent at rest. A second run gives the focused family (a window and its child popup) two records under a limit of one:
# presentation must end with the record-limit line and restore every window.
# See tests/e2e/live-guest-lib.sh for GUEST_SSH, GUEST_INFINIFY and the exit status.
set -eu
cd "$(dirname "$0")/../.."
. tests/e2e/live-guest-lib.sh
live_guest_begin native-frame-cap 'native frame cap: scoped native presentation of the cooperative host fixture' "$@"
. scripts/native-includes.sh
# shellcheck disable=SC2086
live_guest_build host -O2 -fobjc-arc $helper_includes tests/native/dock-helper/Payload/HostFixture.m -framework AppKit
# shellcheck disable=SC2086
live_guest_build payload-arm64.dylib -O2 -fobjc-arc $helper_includes -dynamiclib -Wl,-install_name,@rpath/payload-arm64.dylib \
  native/dock-helper/Payload/DWPayload.m -framework AppKit
live_guest_push "$evidence/bin/host" "$evidence/bin/payload-arm64.dylib" tests/e2e/stability-guest-driver.py
if live_guest_drive frame-cap; then capped=0; else capped=$?; fi
live_gs "rm -rf $gwork/h $gwork/s $gwork/state.json; mv $gwork/evidence $gwork/evidence-cap; mkdir $gwork/evidence"
if live_guest_drive frame-cap-oversized; then oversized=0; else oversized=$?; fi
live_gs "mv $gwork/evidence $gwork/evidence-oversized; mkdir $gwork/evidence; mv $gwork/evidence-cap $gwork/evidence-oversized $gwork/evidence/"
if [ "$capped" -eq 0 ] && [ "$oversized" -eq 0 ]; then echo "PASS: native frame cap, both runs; evidence in $evidence"; exit 0; fi
echo "FAIL: native frame cap: cap run $capped, oversized-family run $oversized; evidence in $evidence"; exit 1
