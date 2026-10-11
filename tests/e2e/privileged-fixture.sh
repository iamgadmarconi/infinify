#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."

case ${1:-} in
  '') live=false ;;
  --live-owned-fixture) live=true; shift ;;
  *) echo "Usage: $0 [--live-owned-fixture]" >&2; exit 2 ;;
esac
[ "$#" -eq 0 ] || { echo "Usage: $0 [--live-owned-fixture]" >&2; exit 2; }

./scripts/build-privileged.sh
[ "$live" = true ] || { echo 'LIVE NOT RUN: pass --live-owned-fixture to launch the disposable native fixture.'; exit 0; }
# Protocol v1's cases first, unchanged, then protocol v2's on a host with several windows.
python3 native/privileged/fixture_test.py
exec python3 native/privileged/fixture_v2_test.py
