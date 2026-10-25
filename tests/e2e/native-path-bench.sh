#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# No native work without an explicit fixture or run subcommand and live flag.
set -eu
cd "$(dirname "$0")/../.."
if [ "$#" -eq 0 ]; then
  echo 'LIVE NOT RUN: use trace/compare for saved data, or fixture/run --live-owned-fixture with explicit paths'
  exit 0
fi
exec python3 native/performance/native_path_bench.py "$@"
