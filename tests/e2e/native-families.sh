#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."

case ${1:-} in
  '') live=false ;;
  --live-owned-fixture) live=true; shift ;;
  *) echo "Usage: $0 [--live-owned-fixture [--lifecycle-only [evidence-directory]|evidence-directory]]" >&2; exit 2 ;;
esac
case ${1:-} in
  '') [ "$#" -eq 0 ] || exit 2 ;;
  --lifecycle-only)
    [ "$#" -le 2 ] || { echo "Usage: $0 [--live-owned-fixture [--lifecycle-only [evidence-directory]|evidence-directory]]" >&2; exit 2; }
    case ${2:-} in -*) echo "Usage: $0 [--live-owned-fixture [--lifecycle-only [evidence-directory]|evidence-directory]]" >&2; exit 2 ;; esac
    ;;
  -*) echo "Usage: $0 [--live-owned-fixture [--lifecycle-only [evidence-directory]|evidence-directory]]" >&2; exit 2 ;;
  *) [ "$#" -eq 1 ] || { echo "Usage: $0 [--live-owned-fixture [--lifecycle-only [evidence-directory]|evidence-directory]]" >&2; exit 2; } ;;
esac

./scripts/build-families.sh
[ "$live" = true ] || { echo 'LIVE NOT RUN: pass --live-owned-fixture to launch the disposable native fixture.'; exit 0; }
if [ "${1:-}" = --lifecycle-only ]; then
  python3 native/families/run.py "${2:-target/native-families/evidence}" --lifecycle-only
else
  python3 native/families/run.py "${1:-target/native-families/evidence}"
fi
