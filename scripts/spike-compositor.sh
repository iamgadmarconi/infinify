#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Owner's single command for the Dock compositing spike. Builds the privileged
# artifacts, then runs the driver (default --dock). This script never runs sudo
# itself; only the driver's own step 4 does, letting sudo prompt on the terminal.
# See native/privileged/README.md "Dock spike (owner-run)".
set -eu
cd "$(dirname "$0")/.."
# A sidecar left by an earlier run means that run's payload may still be mapped inside
# Dock: relinking the file under it is not something to try. Stop before the build.
if [ -e target/privileged/payload-arm64e.dylib.json ]; then
  echo 'A helper from an earlier run may still be loaded in Dock.' >&2
  echo 'Run "killall Dock", delete target/privileged/payload-arm64e.dylib.json, then run this again.' >&2
  exit 1
fi
./scripts/build-privileged.sh
exec python3 native/privileged/spike.py "$@"
