#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
  echo 'This build targets Apple Silicon on macOS 26 or later.' >&2
  exit 1
fi
export MACOSX_DEPLOYMENT_TARGET=26.0
exec cargo build --release --locked -p driftwm-macos -p driftwm-macos-backend -p driftwm-runtime --bins
