#!/bin/bash
# A public release, in build/release/: the notarized zip and DMG, Sparkle's appcast.xml and the Homebrew cask.
#   NOTARY_PROFILE=<profile> scripts/release.sh            # build and check; prints how to publish
#   NOTARY_PROFILE=<profile> scripts/release.sh --publish  # also creates the GitHub release with gh
# Bump CFBundleShortVersionString and CFBundleVersion in Info.plist first: Sparkle offers an update only
# when CFBundleVersion is higher than the one installed. Needs a Developer ID Application identity, a
# notarytool profile, and Sparkle's private key in the login keychain (`make sparkle-keys`).
set -euo pipefail
cd "$(dirname "$0")/.."
source packaging/release.conf

[[ -n "${NOTARY_PROFILE:-}" ]] || { echo "Set NOTARY_PROFILE (xcrun notarytool store-credentials <profile>)" >&2; exit 1; }
[[ -n "$SPARKLE_PUBLIC_KEY" ]] || { echo "Set SPARKLE_PUBLIC_KEY in packaging/release.conf (make sparkle-keys)" >&2; exit 1; }

scripts/package.sh
VERSION=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' Info.plist)
TAG="v$VERSION"
OUT=build/release
rm -rf "$OUT"
mkdir -p "$OUT/updates"
cp "build/Sunlight-$VERSION.zip" "build/Sunlight-$VERSION.dmg" "$OUT/"
spctl --assess --type open --context context:primary-signature -v "$OUT/Sunlight-$VERSION.dmg"
# The same DMG under a name that never changes, for the website's Download button
# (sunlight.software/download → releases/latest/download/Sunlight.dmg).
cp "$OUT/Sunlight-$VERSION.dmg" "$OUT/Sunlight.dmg"

# The appcast, from the published one so earlier versions stay listed. Only the zip goes in: Sparkle
# installs from it, and a DMG of the same version would be a duplicate entry.
cp "$OUT/Sunlight-$VERSION.zip" "$OUT/updates/"
curl -fsSL "$SPARKLE_FEED_URL" -o "$OUT/updates/appcast.xml" 2>/dev/null || rm -f "$OUT/updates/appcast.xml"
GENERATE=$(find .build/artifacts -type f -name generate_appcast | head -1)
[[ -x "$GENERATE" ]] || { echo "Sparkle's generate_appcast isn't in .build/artifacts; run swift build first" >&2; exit 1; }
"$GENERATE" --download-url-prefix "https://github.com/$RELEASES_REPO/releases/download/$TAG/" "$OUT/updates"
cp "$OUT/updates/appcast.xml" "$OUT/appcast.xml"

# The cask, with this version and the DMG's checksum.
SHA=$(shasum -a 256 "$OUT/Sunlight-$VERSION.dmg" | cut -d ' ' -f 1)
sed -e "s|^  version \".*\"|  version \"$VERSION\"|" -e "s|^  sha256 \".*\"|  sha256 \"$SHA\"|" \
    -e "s|spacefarm-digital/sunlight-releases|$RELEASES_REPO|g" packaging/homebrew/sunlight.rb > "$OUT/sunlight.rb"

if [[ "${1:-}" == "--publish" ]]; then
  gh release create "$TAG" --repo "$RELEASES_REPO" --title "Sunlight $VERSION" --generate-notes \
    "$OUT/Sunlight-$VERSION.dmg" "$OUT/Sunlight.dmg" "$OUT/Sunlight-$VERSION.zip" "$OUT/appcast.xml"
  echo "Published $TAG to $RELEASES_REPO. Copy $OUT/sunlight.rb to Casks/sunlight.rb in $TAP_REPO and push it."
else
  echo "Ready in $OUT. To publish: scripts/release.sh --publish (or upload both DMGs, the zip and appcast.xml"
  echo "to a $TAG release of $RELEASES_REPO yourself), then put $OUT/sunlight.rb in $TAP_REPO as Casks/sunlight.rb."
fi
