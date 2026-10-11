#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
  echo 'Privileged helper requires Apple Silicon macOS 26+.' >&2; exit 1
fi
out=target/privileged
mkdir -p "$out"
# Apple arm64e payload is for Dock. The arm64 build is for our ordinary fixture
# host; macOS may prohibit arm64e third-party processes without boot policy changes.
# payload.m includes payload-v2.m (protocol v2). DW_V2_MAIN_QUEUE=1 in the environment
# builds a payload whose v2 native calls run on the main queue instead of its own.
for arch in arm64 arm64e; do
  xcrun clang -arch "$arch" -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror -dynamiclib \
    ${DW_V2_MAIN_QUEUE:+-DDW_V2_MAIN_QUEUE="$DW_V2_MAIN_QUEUE"} \
    native/privileged/payload.m -framework AppKit -o "$out/payload-$arch.dylib"
done
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror \
  native/privileged/host.m -framework AppKit -o "$out/host"
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror \
  native/privileged/client.m -framework Foundation -o "$out/client"
# Protocol v2 client library (plain C, for the shell to link later) and the test
# driver built on it.
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -std=gnu11 -Wall -Wextra -Werror -c \
  native/privileged/dwclient.c -o "$out/dwclient.o"
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -std=gnu11 -Wall -Wextra -Werror \
  native/privileged/v2client.c "$out/dwclient.o" -o "$out/v2client"
# Disposable spike fixture: an ordinary regular-activation process the owner can see
# and click; the Dock helper transforms its one window and then restores it.
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror \
  native/privileged/spike-fixture.m -framework AppKit -o "$out/spike-fixture"
xcrun clang -arch arm64e -mmacosx-version-min=26.0 -Wall -Wextra \
  native/privileged/loader.m -framework AppKit -o "$out/loader-arm64e"
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -Wall -Wextra \
  native/privileged/doctor.m -framework Foundation -o "$out/doctor"
# Ad-hoc sign the Dock payload and loader, exactly as yabai signs its scripting
# addition binaries (yabai dd845723416f5fe92af49fad5ebab00369e07edd src/sa.m
# scripting_addition_prepare_binaries: "codesign -f -s -"). Only the ad-hoc "-"
# identity is ever used; whether Dock accepts an ad-hoc dylib on 27.2 is unproven.
codesign --force --sign - "$out/payload-arm64e.dylib"
codesign --force --sign - "$out/loader-arm64e"
printf '%s\n' 'Built helper, cooperative host, client, v2 client library and driver, spike fixture, read-only doctor and opt-in loader; payload and loader ad-hoc signed; nothing injected.'
