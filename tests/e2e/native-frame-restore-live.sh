#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
cd "$(dirname "$0")/../.."
live=false
case ${1:-} in
  '') ;;
  --live-owned-fixture) live=true; shift ;;
  *) echo "Usage: $0 [--live-owned-fixture [evidence-directory]]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "Usage: $0 [--live-owned-fixture [evidence-directory]]" >&2; exit 2; }
case ${1:-} in -*) echo "Invalid evidence directory" >&2; exit 2 ;; esac
mkdir -p target/resize
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror \
  native/resize/frame-live-probe.m native/resize/resize.m -framework AppKit -o target/resize/frame-live-probe
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror \
  -DDW_FRAME_LIVE_PREFLIGHT_REGRESSION native/resize/frame-live-probe.m native/resize/resize.m \
  -framework AppKit -o target/resize/frame-live-preflight-regression
target/resize/frame-live-preflight-regression
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror \
  native/resize/fixture.m -framework AppKit -o target/resize/fixture
[ "$live" = true ] || { echo 'LIVE NOT RUN: pass --live-owned-fixture to launch the disposable native fixture.'; exit 0; }
exec python3 native/resize/frame-live-e2e.py --live-owned-fixture "${1:-target/resize/frame-live-evidence}"
