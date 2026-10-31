#!/bin/sh
# SPDX-License-Identifier: GPL-3.0-or-later
# Publishes a release that scripts/build-release.sh left in target/dist/VERSION. In order: a signed tag vVERSION on the
# commit the release was built from, pushed; a GitHub release with the disk image, the source archive (GPL-3.0 section 6)
# and SHA256SUMS; and the cask, committed to the tap (Casks/infinify.rb in iamgadmarconi/homebrew-tap) and pushed. Then
# `brew install --cask iamgadmarconi/tap/infinify` installs it, `brew upgrade` brings it to those who have it, and the
# app's own daily check (native/app/System/DWUpdateCheck.h) tells them it is out. For the owner to run: the tag and the
# tap commit are signed with your git signing key.
#   scripts/publish-release.sh VERSION
# Refuses, before anything is published: a release that is not notarized and stapled, files whose checksums do not match,
# a commit that is not on origin/main, a repository that is not public (Homebrew downloads without an account), and a tag
# or release of that version that already exists.
set -eu
cd "$(dirname "$0")/.."
repository=iamgadmarconi/infinify
tap=iamgadmarconi/homebrew-tap
fail() { printf 'publish-release: %s\n' "$*" >&2; exit 1; }
[ $# -eq 1 ] || { printf '%s\n' 'usage: scripts/publish-release.sh VERSION' >&2; exit 64; }
version=$1
dist=target/dist/$version
dmg=$dist/Infinify-$version.dmg
source_archive=$dist/infinify-$version-source.tar.gz
cask=$dist/infinify.rb
for file in "$dmg" "$source_archive" "$dist/SHA256SUMS" "$cask" "$dist/notary-log.json"; do
  [ -f "$file" ] || fail "$file is missing; build the release with scripts/build-release.sh $version --notarize PROFILE"
done
(cd "$dist" && shasum -a 256 -c SHA256SUMS >/dev/null) || fail "the files in $dist do not match their SHA256SUMS"
grep -q "sha256 \"$(shasum -a 256 "$dmg" | cut -d ' ' -f 1)\"" "$cask" || fail "the cask names another image than $dmg"
notary=$(python3 -I -c 'import json, sys; print(json.load(open(sys.argv[1])).get("status", ""))' "$dist/notary-log.json")
[ "$notary" = Accepted ] || fail "the notary service did not accept this image ($notary)"
xcrun stapler validate -q "$dmg" || fail "$dmg carries no stapled ticket"
commit=$(gzip -dc "$source_archive" | git get-tar-commit-id) || fail "$source_archive does not name its commit"
git fetch -q origin
git merge-base --is-ancestor "$commit" origin/main || fail "$commit is not on origin/main; push it first"
[ "$(gh repo view "$repository" --json visibility -q .visibility)" = PUBLIC ] || fail "$repository is not public, so Homebrew could not download the release"
gh repo view "$tap" >/dev/null 2>&1 || fail "the tap $tap does not exist"
! git rev-parse -q --verify "refs/tags/v$version" >/dev/null || fail "the tag v$version exists already"
! gh release view "v$version" -R "$repository" >/dev/null 2>&1 || fail "the release v$version exists already"

previous=$(git describe --tags --abbrev=0 "$commit" 2>/dev/null || true)
notes=$(mktemp "${TMPDIR:-/tmp}/infinify-notes.XXXXXX")
work=$(mktemp -d "${TMPDIR:-/tmp}/infinify-tap.XXXXXX")
trap 'rm -rf "$notes" "$work"' EXIT HUP INT TERM
{
  printf '%s\n\n' "Install with \`brew install --cask iamgadmarconi/tap/infinify\`, or open Infinify-$version.dmg and drag Infinify into Applications. Apple Silicon, macOS 26 or later; notarized by Apple."
  # shellcheck disable=SC2016 # the backticks are Markdown
  printf '%s\n\n' 'Compositor mode, where your real windows live on the canvas, needs System Integrity Protection partly relaxed in Recovery; setup shows the steps and runs a demo until then. Update with `brew upgrade --cask infinify`.'
  if [ -n "$previous" ]; then printf '%s\n\n' "Changes since $previous:"; git log --no-merges --format='- %s' "$previous..$commit"; printf '\n'; fi
  printf '%s\n' "Source: infinify-$version-source.tar.gz (commit $commit, GPL-3.0-or-later)."
} > "$notes"

git tag -s "v$version" -m "Infinify $version" "$commit"
git push -q origin "v$version"
gh release create "v$version" "$dmg" "$source_archive" "$dist/SHA256SUMS" -R "$repository" --verify-tag \
  --title "Infinify $version" --notes-file "$notes"

gh repo clone "$tap" "$work/tap" -- -q
mkdir -p "$work/tap/Casks"
cp "$cask" "$work/tap/Casks/infinify.rb"
git -C "$work/tap" add Casks/infinify.rb
git -C "$work/tap" commit -q -m "infinify $version"
git -C "$work/tap" push -q

printf '%s\n' "Published Infinify $version: https://github.com/$repository/releases/tag/v$version" \
  "Install: brew install --cask iamgadmarconi/tap/infinify" "Update:  brew upgrade --cask infinify"
