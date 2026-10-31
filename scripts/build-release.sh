#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds a release of Infinify in target/dist/VERSION: the app at that version in a disk image, a source archive of the
# same commit (GPL-3.0 section 6), SHA256SUMS and the Homebrew cask. For the owner to run: it signs with your identity.
#   INFINIFY_SIGN_IDENTITY="Developer ID Application: …" scripts/build-release.sh VERSION [--notarize PROFILE]
# VERSION is MAJOR.MINOR.PATCH; the build number is the number of commits on HEAD, so it only goes up. The working tree
# must be clean, because the source archive has to be the source of the app.
# --notarize submits the image to Apple's notary service with the notarytool keychain profile PROFILE (created once with
# `xcrun notarytool store-credentials PROFILE --apple-id … --team-id …`), waits, keeps the service's log beside the image,
# then staples the ticket and checks the image with spctl. Without it the image is signed but not notarized.
# It replaces target/app with the release build and publishes nothing: scripts/publish-release.sh VERSION puts the files
# it leaves on GitHub and in the tap. The app it builds names this repository (INFINIFY_RELEASE_REPOSITORY), whose latest
# release it compares itself with once a day (native/app/System/DWUpdateCheck.h).
set -eu
cd "$(dirname "$0")/.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
usage='usage: scripts/build-release.sh VERSION [--notarize PROFILE]'
fail() { printf 'build-release: %s\n' "$*" >&2; exit 1; }
repository=iamgadmarconi/infinify
if [ $# -eq 1 ]; then profile=
elif [ $# -eq 3 ] && [ "$2" = --notarize ] && [ -n "$3" ]; then profile=$3
else printf '%s\n' "$usage" >&2; exit 64; fi
version=$1
printf '%s\n' "$version" | grep -Eq '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$' \
  || fail "VERSION must be MAJOR.MINOR.PATCH, such as 0.2.0: $version"
identity=${INFINIFY_SIGN_IDENTITY:--}
[ "$identity" != - ] || fail 'a release is signed with your Developer ID: set INFINIFY_SIGN_IDENTITY (security find-identity -v -p codesigning)'
[ -z "$(GIT_OPTIONAL_LOCKS=0 git status --porcelain --untracked-files=all)" ] \
  || fail 'the working tree has changes; commit them first, so the source archive is the source of the app'
commit=$(git rev-parse HEAD)
build=$(git rev-list --count HEAD)
dist=target/dist/$version
[ ! -e "$dist" ] || fail "$dist exists; remove it to build $version again"

# The Dock payload is signed with the identity too (notarization refuses an ad hoc Mach-O); the guest showed on 2026-10-30
# that the Dock loads it so. INFINIFY_SIGN_PAYLOAD=0 keeps it ad hoc.
INFINIFY_SIGN_PAYLOAD=${INFINIFY_SIGN_PAYLOAD:-1}
export INFINIFY_SIGN_PAYLOAD
INFINIFY_VERSION=$version INFINIFY_BUILD_NUMBER=$build INFINIFY_RELEASE_REPOSITORY=$repository ./scripts/build-app.sh
python3 -I scripts/build-app-package.py verify-source --root "$PWD" >/dev/null

mkdir -p "$dist"
dmg=$dist/Infinify-$version.dmg
source_archive=$dist/infinify-$version-source.tar.gz
./scripts/package-dmg.sh target/app/Infinify.app "$dmg" --sign "$identity" --validate-native
git archive --format=tar.gz --prefix="infinify-$version/" -o "$source_archive" "$commit"

if [ -n "$profile" ]; then
  [ "$INFINIFY_SIGN_PAYLOAD" = 1 ] || printf '%s\n' 'build-release: the Dock payload is signed ad hoc (INFINIFY_SIGN_PAYLOAD=0), which the notary service rejects; its log still says what else it found.' >&2
  xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait --output-format json > "$dist/notary-submit.json" || true
  read_json() { python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1])).get(sys.argv[2], ""))' "$1" "$2" 2>/dev/null || true; }
  submission=$(read_json "$dist/notary-submit.json" id)
  status=$(read_json "$dist/notary-submit.json" status)
  [ -n "$submission" ] || fail "notarytool did not submit the image; its answer is in $dist/notary-submit.json"
  xcrun notarytool log "$submission" --keychain-profile "$profile" "$dist/notary-log.json" >/dev/null || true
  [ "$status" = Accepted ] || fail "the notary service answered ${status:-nothing}; its findings are in $dist/notary-log.json"
  xcrun stapler staple -q "$dmg"
  spctl --assess --type open --context context:primary-signature "$dmg" || fail 'Gatekeeper does not accept the stapled image'
  notarized=notarized
else
  notarized='signed, not notarized'
fi

(cd "$dist" && shasum -a 256 "Infinify-$version.dmg" "infinify-$version-source.tar.gz" > SHA256SUMS)
dmg_sha256=$(shasum -a 256 "$dmg" | cut -d ' ' -f 1)
cat > "$dist/infinify.rb" <<EOF
cask "infinify" do
  version "$version"
  sha256 "$dmg_sha256"

  url "https://github.com/$repository/releases/download/v#{version}/Infinify-#{version}.dmg"
  name "Infinify"
  desc "Infinite canvas desktop, ported from DriftWM"
  homepage "https://github.com/$repository"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on arch: :arm64
  depends_on macos: ">= :tahoe"

  app "Infinify.app"

  # brew upgrade runs uninstall too (all but signal): quit lets the new copy replace a running one, and brew opens it again
  # afterwards. Taking the login item and the launch daemon away is for a real removal only, so it is zap's.
  uninstall quit: "com.marengox.infinify"

  zap early_script: {
        executable:   "#{appdir}/Infinify.app/Contents/MacOS/Infinify",
        args:         ["uninstall", "--leave-app"],
        must_succeed: false,
      },
      trash:        "~/Library/Application Support/Infinify"

  caveats <<~CAVEATS
    Open Infinify to set it up. Compositor mode, where your real windows live on the canvas, needs System Integrity
    Protection partly relaxed in Recovery; setup shows the steps, and runs a demo until then.
  CAVEATS
end
EOF

printf '\n%s\n' "Infinify $version (build $build, $commit), $notarized, in $dist:"
printf '  %s\n' "Infinify-$version.dmg" "infinify-$version-source.tar.gz" SHA256SUMS "infinify.rb (the cask; goes in Casks/ of your homebrew-tap repository)"
printf '%s\n' "Nothing was published. To publish it: scripts/publish-release.sh $version"
