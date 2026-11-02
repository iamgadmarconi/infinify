#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Keys without a canvas panel, live, in a disposable guest, through the INFINIFY_DEBUG_HIDE_SCREENS seam
# (docs/native/app/Desktop/README.md). A --manual desktop run (it leaves the window settings alone and adopts no window)
# has its chooser's Open canvas button clicked (one HID click in the guest; Infinify's AX tree cannot reach the button). Run 1 hides the screens for the first 8 s: no panel
# and no key at all, and a posted exit chord does nothing; then panels and the full key set with the system key filter;
# then a runtime loss of every display from 16 s: own keys only (no filter), quit and the exit chord still registered;
# then panels and the filter again. Run 2 loses every display 6 s after opening and the posted Control-Option-Escape must
# end the run with status 0. Key state is read from INFINIFY_DEBUG's DebugInput request: registration, not a delivered
# press, except for the posted chord. See tests/e2e/live-guest-lib.sh for GUEST_SSH, GUEST_INFINIFY and the exit status.
set -eu
cd "$(dirname "$0")/../.."
. tests/e2e/live-guest-lib.sh
live_guest_begin zero-screen-keys 'zero-screen launch and runtime display loss: which keys are taken' "$@"
live_guest_build chooser-click tests/native/app/Desktop/ChooserClickFixture.c -framework ApplicationServices -framework CoreFoundation
live_guest_build exit-chord tests/native/app/Input/ExitChordFixture.c -framework ApplicationServices -framework CoreFoundation
live_guest_push "$evidence/bin/chooser-click" "$evidence/bin/exit-chord" tests/e2e/stability-guest-driver.py
if live_guest_drive zero-screen; then status=0; else status=$?; fi
echo "Result $status; evidence in $evidence"; exit "$status"
