#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
./scripts/build-privileged.sh
exec python3 native/privileged/fixture_test.py
