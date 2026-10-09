#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
./scripts/build-resize.sh
python3 native/resize/e2e.py "${1:-target/resize/evidence}"
