#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."

case ${1:-} in
  '') live=false ;;
  --live-owned-fixture) live=true; shift ;;
  *) echo "Usage: $0 [--live-owned-fixture [evidence-directory]]" >&2; exit 2 ;;
esac
[ "$#" -le 1 ] || { echo "Usage: $0 [--live-owned-fixture [evidence-directory]]" >&2; exit 2; }
case ${1:-} in -*) echo "Usage: $0 [--live-owned-fixture [evidence-directory]]" >&2; exit 2 ;; esac

./scripts/build-resize.sh
[ "$live" = true ] || { echo 'LIVE NOT RUN: pass --live-owned-fixture to launch the disposable native fixture.'; exit 0; }
python3 native/resize/e2e.py "${1:-target/resize/evidence}"
