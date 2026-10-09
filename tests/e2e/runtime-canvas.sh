#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
cd "$(dirname "$0")/../.."
./scripts/build-privileged.sh
cargo build -p driftwm-runtime --locked
exec python3 crates/runtime/tests/runtime_canvas.py
