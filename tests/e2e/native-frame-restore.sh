#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
cd "$(dirname "$0")/../.."
mkdir -p target/resize
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror \
  native/resize/frame-regression.m -framework AppKit -o target/resize/frame-regression
./target/resize/frame-regression
