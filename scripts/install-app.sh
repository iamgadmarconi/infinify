#!/bin/sh
# Installs Infinify as the desktop: builds the bundle (with --built, takes the one
# already in target/app), copies it to ~/Applications/Infinify.app and signs the copy.
# For the owner to run; no agent or test runs it. It starts nothing, registers nothing
# and changes no setting. The login item is the owner's next step:
#   ~/Applications/Infinify.app/Contents/MacOS/Infinify login-item on
#
# macOS ties the Screen Recording and Accessibility grants to the bundle's signature.
# INFINIFY_SIGN_IDENTITY names a code-signing identity in the keychain
# (security find-identity -v -p codesigning): signed with the same one every time, the
# installed copy keeps both grants across reinstalls. Without it the copy is signed ad
# hoc, and every reinstall loses both.
set -eu
cd "$(dirname "$0")/.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
if [ $# -gt 1 ] || { [ $# -eq 1 ] && [ "$1" != --built ]; }; then
  printf '%s\n' "usage: scripts/install-app.sh [--built]" >&2
  exit 64
fi
[ $# -eq 1 ] || ./scripts/build-app.sh
src=target/app/Infinify.app
agent=Contents/Library/LaunchAgents/com.marengox.infinify.agent.plist
if [ ! -x "$src/Contents/MacOS/Infinify" ] || [ ! -f "$src/$agent" ]; then
  printf '%s\n' "No complete bundle at $src (executable and $agent): run scripts/install-app.sh without --built." >&2
  exit 1
fi
applications="$HOME/Applications"
dest="$applications/Infinify.app"
staged="$applications/.Infinify.app.installing.$$"
replaced="$applications/.Infinify.app.replaced.$$"
mkdir -p "$applications"
# However this ends, an interrupt included: the staged copy goes, and a bundle that was
# moved aside comes back unless the new one took its place.
finish() {
  rm -rf "$staged"
  if [ -e "$replaced" ]; then
    if [ -e "$dest" ]; then rm -rf "$replaced"; else mv "$replaced" "$dest"; fi
  fi
}
trap finish EXIT
trap 'exit 130' INT
trap 'exit 129' HUP
trap 'exit 143' TERM
ditto "$src" "$staged"
# "-" is how codesign spells ad hoc (scripts/build-app.sh's default): not an identity.
if [ "${INFINIFY_SIGN_IDENTITY:--}" != - ]; then
  codesign --force --sign "$INFINIFY_SIGN_IDENTITY" "$staged"
  signed="with $INFINIFY_SIGN_IDENTITY"
else
  {
    printf '%s\n' "========================================================================"
    printf '%s\n' "WARNING: INFINIFY_SIGN_IDENTITY names no identity. This copy is signed AD HOC."
    printf '%s\n' "macOS will DROP its Screen Recording and Accessibility grants on EVERY"
    printf '%s\n' "reinstall, and Infinify will ask for both again each time."
    printf '%s\n' "Set INFINIFY_SIGN_IDENTITY to a signing identity to keep them."
    printf '%s\n' "========================================================================"
  } >&2
  codesign --force --sign - "$staged"
  signed="ad hoc"
fi
codesign --verify --strict "$staged"
# An instance that is running keeps the files it was started from: the bundle in place
# is moved aside whole and only then removed, never overwritten file by file.
if [ -e "$dest" ]; then
  mv "$dest" "$replaced"
fi
if ! mv "$staged" "$dest"; then
  [ ! -e "$replaced" ] || mv "$replaced" "$dest"
  exit 1
fi
rm -rf "$replaced"
printf '%s\n' "Installed $dest, signed $signed. Nothing was started and nothing was registered."
printf '%s\n' "Start it at login, and again after a crash:  $dest/Contents/MacOS/Infinify login-item on"
printf '%s\n' "An instance that is already running keeps the previous build until it ends:"
printf '%s\n' "  $dest/Contents/MacOS/Infinify msg action quit"
printf '%s\n' "  launchctl kickstart gui/$(id -u)/com.marengox.infinify.agent   # when it runs as the login item"
