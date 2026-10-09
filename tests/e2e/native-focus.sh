#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."
./scripts/build-focus.sh
./target/focus/geometry-check
if [ "${1:-}" = '--live-owned-focus' ]; then
    exec python3 native/focus/e2e.py "$@"
fi
if [ "$#" -ne 0 ]; then
    printf '%s\n' 'Unknown option; live gate requires --live-owned-focus' >&2
    exit 64
fi
./target/focus/probe --doctor
printf '%s\n' 'Build, C ABI and inverse-camera checks passed. Live focus/input gate NOT RUN.'
