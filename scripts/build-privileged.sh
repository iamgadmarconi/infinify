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
for arch in arm64 arm64e; do
  xcrun clang -arch "$arch" -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror -dynamiclib \
    native/privileged/payload.m -framework AppKit -o "$out/payload-$arch.dylib"
done
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror \
  native/privileged/host.m -framework AppKit -o "$out/host"
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror \
  native/privileged/client.m -framework Foundation -o "$out/client"
xcrun clang -arch arm64e -mmacosx-version-min=26.0 -Wall -Wextra \
  native/privileged/loader.m -framework AppKit -o "$out/loader-arm64e"
xcrun clang -arch arm64 -mmacosx-version-min=26.0 -Wall -Wextra \
  native/privileged/doctor.m -framework Foundation -o "$out/doctor"
printf '%s\n' 'Built helper, cooperative host, client, read-only doctor and opt-in loader; nothing injected.'
