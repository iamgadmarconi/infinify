#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
./scripts/build-families.sh
if [ "${1:-}" = --lifecycle-only ]; then
  python3 native/families/run.py "${2:-target/native-families/evidence}" --lifecycle-only
else
  python3 native/families/run.py "${1:-target/native-families/evidence}"
fi
