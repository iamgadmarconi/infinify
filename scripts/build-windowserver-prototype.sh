#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
cd "$(dirname "$0")/.."
out=target/windowserver-prototype
if [ "$#" -gt 0 ]; then
  [ "$#" -eq 2 ] && [ "$1" = --output-dir ] || { echo 'usage: scripts/build-windowserver-prototype.sh [--output-dir PATH]' >&2; exit 64; }
  out=$2
fi
mkdir -p "$out"
xcrun clang -arch arm64e -mmacosx-version-min=26.0 -std=gnu11 -fblocks -O2 \
  -Wall -Wextra -Werror -dynamiclib -Wl,-install_name,@rpath/if-windowserver-prototype.dylib \
  native/windowserver-prototype/payload.c native/windowserver-prototype/server-abi.c native/windowserver-prototype/mailbox.c \
  -framework CoreFoundation -framework CoreGraphics -framework QuartzCore -o "$out/payload-arm64e.dylib"
xcrun clang -arch arm64e -mmacosx-version-min=26.0 -fblocks -O2 -Wall -Wextra -Werror \
  native/windowserver-prototype/loader.m native/windowserver-prototype/server-abi.c native/windowserver-prototype/mailbox.c \
  -framework Foundation -framework CoreFoundation -framework CoreGraphics -framework QuartzCore -o "$out/ws-loader-arm64e"
codesign --force --sign - "$out/payload-arm64e.dylib"
codesign --force --sign - "$out/ws-loader-arm64e"
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -std=gnu11 -O2 -Wall -Wextra -Werror -dynamiclib \
  native/windowserver-prototype/mailbox-client.c native/windowserver-prototype/mailbox.c -o "$out/libmailbox-client.dylib"
codesign --force --sign - "$out/libmailbox-client.dylib"
printf '%s\n' "Built isolated WindowServer prototype in $out; no executable run, no payload loaded."
