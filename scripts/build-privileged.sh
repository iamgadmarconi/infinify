#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
set -eu
cd "$(dirname "$0")/.."
mode=all
out=target/privileged
mode_selected=false
output_selected=false
while [ $# -gt 0 ]; do
  case "$1" in
    --production)
      [ "$mode_selected" = false ] || { printf '%s\n' 'usage: scripts/build-privileged.sh [--production] [--output-dir PATH]' >&2; exit 64; }
      mode_selected=true
      mode=production
      ;;
    --output-dir)
      [ $# -ge 2 ] && [ "$output_selected" = false ] || { printf '%s\n' 'usage: scripts/build-privileged.sh [--production] [--output-dir PATH]' >&2; exit 64; }
      shift
      out=$1
      output_selected=true
      ;;
    *) printf '%s\n' 'usage: scripts/build-privileged.sh [--production] [--output-dir PATH]' >&2; exit 64 ;;
  esac
  shift
done
if [ "$(uname -s)" != Darwin ] || [ "$(uname -m)" != arm64 ]; then
  echo 'Privileged helper requires Apple Silicon macOS 26+.' >&2; exit 1
fi
mkdir -p "$out"
# Sources import each other by bare name; each helper module directory is a header search path (scripts/native-includes.sh).
. scripts/native-includes.sh
xcrun clang -O2 -arch arm64 -mmacosx-version-min=26.0 -Wall -Wextra -Werror $helper_includes \
  native/dock-helper/Loader/DWDoctor.m -framework Foundation -o "$out/doctor"
# Apple arm64e payload is for Dock. The arm64 build is for our ordinary fixture
# host; macOS may prohibit arm64e third-party processes without boot policy changes.
# native/dock-helper/Payload/DWPayload.m (with the fragments it #imports) holds the helper; compile only that file.
architectures=arm64e
[ "$mode" = production ] || architectures='arm64 arm64e'
for arch in $architectures; do
  # The install name is part of the signed payload bytes. Keep staging paths out
  # of its identity so rebuilding unchanged source preserves helper reuse hashes.
  xcrun clang -O2 -arch "$arch" -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror $helper_includes -dynamiclib \
    -Wl,-install_name,"@rpath/payload-$arch.dylib" \
    native/dock-helper/Payload/DWPayload.m -framework AppKit -o "$out/payload-$arch.dylib"
done
# Protocol v2 client library for the desktop shell.
xcrun clang -O2 -arch arm64 -mmacosx-version-min=26.0 -std=gnu11 -Wall -Wextra -Werror $helper_includes -c \
  native/dock-helper/Client/DWHelperClient.c -o "$out/dwclient.o"
# The loader's authenticated v2 readiness audit needs its own arm64e client;
# the arm64 object used by the shell cannot be linked into this executable.
xcrun clang -O2 -arch arm64e -mmacosx-version-min=26.0 -std=gnu11 -Wall -Wextra -Werror $helper_includes -c \
  native/dock-helper/Client/DWHelperClient.c -o "$out/dwclient-arm64e.o"
if [ "$mode" = all ]; then
  xcrun clang -O2 -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror $helper_includes \
    tests/native/dock-helper/Payload/HostFixture.m -framework AppKit -o "$out/host"
  xcrun clang -O2 -arch arm64 -mmacosx-version-min=26.0 -std=gnu11 -Wall -Wextra -Werror $helper_includes \
    tests/native/dock-helper/Client/ClientFixture.c "$out/dwclient.o" -o "$out/fixture-client"
fi
xcrun clang -O2 -arch arm64e -mmacosx-version-min=26.0 -Wall -Wextra -Werror $helper_includes \
  native/dock-helper/Loader/DWLoader.m "$out/dwclient-arm64e.o" -framework AppKit -o "$out/loader-arm64e"
# Ad-hoc sign the standalone production tools and Dock payload, exactly as yabai
# signs its scripting addition binaries (yabai dd845723416f5fe92af49fad5ebab00369e07edd
# src/sa.m scripting_addition_prepare_binaries: "codesign -f -s -"). An ad hoc build signs every one of them so.
# A build signed with an identity (INFINIFY_SIGN_IDENTITY, which scripts/build-app.sh passes down) signs the doctor and the loader with it,
# with the hardened runtime and no entitlements: nothing a root loader or the read-only doctor does needs one (measured, see
# docs/native/dock-helper/Daemon/README.md). The payload stays ad hoc unless INFINIFY_SIGN_PAYLOAD=1 (below): it is not an executable, the Dock
# (not Infinify) maps it, and its exact bytes are what the launch daemon's digest and the manifest pin. An ad-hoc build is signed exactly as before.
# A release build (INFINIFY_VERSION set, by scripts/build-release.sh) is timestamped as well, as notarization requires.
identity=${INFINIFY_SIGN_IDENTITY:--}
sign_tool() {
  if [ "$identity" = - ]; then codesign --force --sign - "$1"
  elif [ -n "${INFINIFY_VERSION:-}" ]; then codesign --force --sign "$identity" --options runtime --timestamp "$1"
  else codesign --force --sign "$identity" --options runtime "$1"; fi
}
sign_tool "$out/doctor"
# INFINIFY_SIGN_PAYLOAD=1, with an identity, signs the payload with it too (timestamped in a release build): notarization
# refuses any Mach-O in the bundle without a Developer ID signature. It is opt-in until the guest has shown that the Dock
# loads a payload signed so; nothing in the loader or the daemon asks for an ad hoc one (they pin its digest, taken below).
if [ "$identity" != - ] && [ "${INFINIFY_SIGN_PAYLOAD:-}" = 1 ]; then
  if [ -n "${INFINIFY_VERSION:-}" ]; then codesign --force --sign "$identity" --timestamp "$out/payload-arm64e.dylib"
  else codesign --force --sign "$identity" "$out/payload-arm64e.dylib"; fi
else
  codesign --force --sign - "$out/payload-arm64e.dylib"
fi
sign_tool "$out/loader-arm64e"
codesign --verify --strict "$out/doctor"
codesign --verify --strict "$out/payload-arm64e.dylib"
codesign --verify --strict "$out/loader-arm64e"
# The launch daemon (loadd) carries the digests of the loader and payload just signed, so that what it runs as root and
# what the Dock opens are fixed by the daemon's own signed bytes, not by anything the app bundle says about itself.
# Built last for that reason. packaging signs it with the build identity; here it is ad hoc like its siblings, and an
# ad-hoc build ships no daemon plist (launchd will not run an ad-hoc daemon, and the daemon needs a team to name its caller).
loader_sha256=$(shasum -a 256 "$out/loader-arm64e" | cut -d ' ' -f 1)
payload_sha256=$(shasum -a 256 "$out/payload-arm64e.dylib" | cut -d ' ' -f 1)
xcrun clang -O2 -arch arm64 -mmacosx-version-min=26.0 -fobjc-arc -Wall -Wextra -Werror $helper_includes \
  -DINFINIFY_LOADER_SHA256="\"$loader_sha256\"" -DINFINIFY_PAYLOAD_SHA256="\"$payload_sha256\"" \
  native/dock-helper/Daemon/Daemon.m native/dock-helper/Daemon/DWLoaddRequest.m -framework Foundation -framework Security -o "$out/loadd"
codesign --force --sign - --identifier com.marengox.infinify.loadd "$out/loadd"
codesign --verify --strict "$out/loadd"
if [ "$identity" = - ]; then signed=ad-hoc; else signed='signed (the payload and the daemon ad hoc here; packaging signs the daemon with the identity, hardened runtime)'; fi
if [ "$mode" = production ]; then
  printf '%s\n' "Built production Dock payload, client libraries, read-only doctor and opt-in loader and the launch daemon; $signed; no fixtures built, nothing injected."
else
  printf '%s\n' "Built helper, cooperative host, v2 client library and driver, read-only doctor, opt-in loader and launch daemon; $signed; nothing injected."
fi
