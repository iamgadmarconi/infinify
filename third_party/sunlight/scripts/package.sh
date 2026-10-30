#!/bin/bash
# Builds Sunlight.app from a release build, signs it, and packs it as a zip and a DMG:
#   scripts/package.sh            # build/Sunlight.app, build/Sunlight-<version>.zip and .dmg
#   scripts/package.sh --app-only # just build/Sunlight.app
# SIGN picks the signing identity. Unset, it's the first Developer ID Application identity in the keychain,
# else the first Apple Development one, else ad-hoc ("-"). A real identity keeps the Accessibility and
# Screen Recording grants across rebuilds; ad-hoc gives every build a new identity.
# NOTARY_PROFILE, with a Developer ID identity, notarizes the app and the DMG and staples both, so they open
# without a Gatekeeper warning: `xcrun notarytool store-credentials <profile>` saves one in the keychain.
set -euo pipefail
cd "$(dirname "$0")/.."
source packaging/release.conf

if [[ -z "${SIGN:-}" ]]; then
  IDENTITIES=$(security find-identity -v -p codesigning 2>/dev/null || true)
  SIGN=$( { grep '"Developer ID Application: ' <<<"$IDENTITIES"; grep '"Apple Development: ' <<<"$IDENTITIES"; } \
    | head -1 | sed -E 's/.*"(.*)"/\1/' || true)
  SIGN="${SIGN:--}"
fi
APP=build/Sunlight.app
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
BUNDLE_ID=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' Info.plist)
NOTARY_PROFILE="${NOTARY_PROFILE:-}"
if [[ -n "$NOTARY_PROFILE" && "$SIGN" != "Developer ID Application: "* ]]; then
  echo "Notarizing needs a Developer ID Application identity, not ${SIGN/#-/ad-hoc}" >&2
  exit 1
fi

# A real identity signs with the hardened runtime, which notarization requires; a Developer ID one also
# with a secure timestamp. Ad-hoc builds stay as they were.
SIGN_FLAGS=(--force --sign "$SIGN")
[[ "$SIGN" != "-" ]] && SIGN_FLAGS+=(--options runtime)
[[ "$SIGN" == "Developer ID Application: "* ]] && SIGN_FLAGS+=(--timestamp)

swift build -c release
BIN_DIR=$(swift build -c release --show-bin-path)

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Sunlight" "$APP/Contents/MacOS/Sunlight"
# SwiftPM stamps the binary as built with the SDK of the deployment target (macOS 15), and macOS draws
# an app that says so the old way: round-knobbed switches, pre-Liquid Glass controls. Stamped with the
# SDK it was really built with, it gets today's. The deployment target stays.
SDK_VERSION=$(xcrun --sdk macosx --show-sdk-version)
MIN_VERSION=$(/usr/libexec/PlistBuddy -c "Print :LSMinimumSystemVersion" Info.plist)
vtool -set-build-version macos "$MIN_VERSION" "$SDK_VERSION" -replace -output "$APP/Contents/MacOS/Sunlight" "$APP/Contents/MacOS/Sunlight"
cp Info.plist "$APP/Contents/Info.plist"
# The icon: compiled from Resources/Sunlight.icon when Xcode is installed, so macOS 26 and later get the
# Liquid Glass icon in every appearance from Assets.car (Info.plist's CFBundleIconName); otherwise just the
# checked-in Resources/Sunlight.icns, which macOS 15 uses either way (CFBundleIconFile).
if scripts/compile-icon.sh "$APP/Contents/Resources"; then :
elif [[ $? == 2 ]]; then cp Resources/Sunlight.icns "$APP/Contents/Resources/Sunlight.icns"
else echo "Compiling Resources/Sunlight.icon failed" >&2; exit 1
fi
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Sparkle, for updates. Sunlight isn't sandboxed, so Sparkle's XPC services aren't needed; the rest is
# re-signed inside out, as nested code has to be. The feed and key go into Info.plist from release.conf,
# and the app leaves Sparkle off without them.
SPARKLE_SOURCE="$BIN_DIR/Sparkle.framework"
[[ -d "$SPARKLE_SOURCE" ]] || SPARKLE_SOURCE=$(find .build/artifacts -maxdepth 6 -type d -path '*macos*/Sparkle.framework' | head -1)
ditto "$SPARKLE_SOURCE" "$APP/Contents/Frameworks/Sparkle.framework"
SPARKLE="$APP/Contents/Frameworks/Sparkle.framework"
rm -rf "$SPARKLE/Versions/B/XPCServices" "$SPARKLE/XPCServices"
codesign "${SIGN_FLAGS[@]}" "$SPARKLE/Versions/B/Autoupdate"
codesign "${SIGN_FLAGS[@]}" "$SPARKLE/Versions/B/Updater.app"
codesign "${SIGN_FLAGS[@]}" "$SPARKLE"
if [[ -n "$SPARKLE_FEED_URL" && -n "$SPARKLE_PUBLIC_KEY" ]]; then
  /usr/libexec/PlistBuddy -c "Add :SUFeedURL string $SPARKLE_FEED_URL" "$APP/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_KEY" "$APP/Contents/Info.plist"
fi

# Live windows: the helper (with the Dock add-on and its loader built in) goes in Contents/Helpers, signed
# before the app, as nested code has to be. With a real identity it's signed like the app and carries the
# launch daemon's plist, so the app can register it with SMAppService: launchd won't run an ad-hoc daemon,
# and the daemon only answers apps from its own team. Ad-hoc builds leave the daemon out and reach root
# through sudo; an ad-hoc signature is the same for the same binary, so the helper's SHA-256, which the
# passwordless sudoers rule is pinned to, only changes when its code does. (A certificate signature carries
# its signing time, so with one every build would ask for the password again; the daemon needs none.)
scripts/build-live-windows.sh
mkdir -p "$APP/Contents/Helpers"
cp build/live-windows/SunlightLiveWindows "$APP/Contents/Helpers/SunlightLiveWindows"
if [[ "$SIGN" == "-" ]]; then
  codesign --force --sign - --identifier "$BUNDLE_ID.live-windows" "$APP/Contents/Helpers/SunlightLiveWindows"
else
  mkdir -p "$APP/Contents/Library/LaunchDaemons"
  cp Resources/LaunchDaemons/*.plist "$APP/Contents/Library/LaunchDaemons/"
  codesign "${SIGN_FLAGS[@]}" --identifier "$BUNDLE_ID.live-windows" "$APP/Contents/Helpers/SunlightLiveWindows"
fi
codesign "${SIGN_FLAGS[@]}" --identifier "$BUNDLE_ID" "$APP"
codesign --verify --strict --deep "$APP"
echo "Built $APP ($VERSION, $BUNDLE_ID, signed ${SIGN/#-/ad-hoc})"

# Submits a file to Apple's notary service, waits for the verdict, and staples the ticket to $2.
notarize() {
  echo "Notarizing $(basename "$1")…"
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --timeout 30m > build/notary.log 2>&1 || true
  cat build/notary.log
  if ! grep -q "status: Accepted" build/notary.log; then
    ID=$(grep -m1 '  id:' build/notary.log | awk '{print $2}')
    [[ -n "$ID" ]] && xcrun notarytool log "$ID" --keychain-profile "$NOTARY_PROFILE" >&2
    echo "Notarization of $(basename "$1") failed" >&2
    exit 1
  fi
  xcrun stapler staple "$2"
}

if [[ -n "$NOTARY_PROFILE" ]]; then
  ditto -c -k --keepParent "$APP" build/notarize.zip
  notarize build/notarize.zip "$APP"
  rm -f build/notarize.zip
fi

[[ "${1:-}" == "--app-only" ]] && exit 0

ZIP=build/Sunlight-$VERSION.zip
DMG=build/Sunlight-$VERSION.dmg
rm -f "$ZIP" "$DMG"
ditto -c -k --keepParent "$APP" "$ZIP"

# The DMG: the app and an Applications shortcut in a window with the hill background and the icons where
# its arrow points (packaging/dmg), and the app icon as the volume's. The window layout is written onto the
# volume and the custom-icon flag set on it, so the image is built read-write first and compressed after.
TMP=$(mktemp -d)
RW=build/Sunlight-rw.dmg
MOUNT=
trap 'if [[ -n "$MOUNT" ]]; then hdiutil detach "$MOUNT" -quiet 2>/dev/null || true; fi; rm -rf "$TMP" "$RW"' EXIT
mkdir "$TMP/stage" "$TMP/mnt"
scripts/dmg-stage.sh "$TMP/stage"
hdiutil create -quiet -volname Sunlight -srcfolder "$TMP/stage" -fs HFS+ -format UDRW -ov "$RW"
MOUNT=$(hdiutil attach -readwrite -noverify -noautoopen -mountrandom "$TMP/mnt" "$RW" | awk -F'\t' '/Apple_HFS/ {print $NF}')
test -d "$MOUNT"
swift scripts/make-dmg-layout.swift "$MOUNT"
if xcrun --find SetFile >/dev/null 2>&1; then xcrun SetFile -a C "$MOUNT"
else echo "No SetFile (it comes with the Xcode command-line tools), so the disk gets a plain icon" >&2; fi
hdiutil detach "$MOUNT" -quiet
MOUNT=
hdiutil convert -quiet -format UDZO -imagekey zlib-level=9 -ov "$RW" -o "$DMG"
if [[ "$SIGN" != "-" ]]; then
  codesign --force --sign "$SIGN" $([[ "$SIGN" == "Developer ID Application: "* ]] && echo --timestamp) "$DMG"
fi
[[ -n "$NOTARY_PROFILE" ]] && notarize "$DMG" "$DMG"
echo "Packed $ZIP and $DMG${NOTARY_PROFILE:+, notarized}"
