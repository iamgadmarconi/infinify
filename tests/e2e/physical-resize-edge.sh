#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Real CGEvent edge resizing; no DebugPointer press/drag injection.
set -eu
cd "$(dirname "$0")/../.."
exec python3 tests/e2e/physical-resize-edge.py "$@"
