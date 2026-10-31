#!/bin/sh
# Installs Infinify as the desktop: builds the bundle (with --built, takes the one
# already in target/app), then copies the already-signed bytes to /Applications, where a
# disk image and Homebrew put it (--user: ~/Applications instead).
# For the owner to run; no agent or test runs it. It starts nothing, registers nothing
# and changes no setting. The next step is opening the app: its setup assistant turns on
# the login item and compositor mode, and removes a copy left in the other folder.
#
# macOS ties the Screen Recording and Accessibility grants to the bundle's signature.
# INFINIFY_SIGN_IDENTITY names the code-signing identity used during the build
# (security find-identity -v -p codesigning). The installer preserves that exact
# signature. An ad-hoc build loses Screen Recording and Accessibility grants on
# reinstall; `--built` installs the identity already used for its build.
set -eu
cd "$(dirname "$0")/.."
test "$(uname -s)" = Darwin && test "$(uname -m)" = arm64
built=false applications=/Applications other="$HOME/Applications"
for argument in "$@"; do
  case "$argument" in
    --built) [ "$built" = false ] || { printf '%s\n' "usage: scripts/install-app.sh [--built] [--user]" >&2; exit 64; }; built=true ;;
    --user) [ "$applications" = /Applications ] || { printf '%s\n' "usage: scripts/install-app.sh [--built] [--user]" >&2; exit 64; }; applications="$HOME/Applications" other=/Applications ;;
    *) printf '%s\n' "usage: scripts/install-app.sh [--built] [--user]" >&2; exit 64 ;;
  esac
done
[ "$built" = true ] || ./scripts/build-app.sh
src=target/app/Infinify.app
agent=Contents/Library/LaunchAgents/com.marengox.infinify.agent.plist
if [ ! -x "$src/Contents/MacOS/Infinify" ] || [ ! -f "$src/$agent" ]; then
  printf '%s\n' "No complete bundle at $src (executable and $agent): run scripts/install-app.sh without --built." >&2
  exit 1
fi
python3 scripts/build-app-package.py verify-source --root "$PWD" --bundle "$PWD/$src"
dest="$applications/Infinify.app"
staged="$applications/.Infinify.app.installing.$$"
replaced="$applications/.Infinify.app.replaced.$$"
mkdir -p "$applications"
if [ ! -w "$applications" ]; then
  printf '%s\n' "$applications is not writable for this user; run scripts/install-app.sh --user to install in ~/Applications." >&2
  exit 1
fi
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
# The app and helper manifest are signed once during build. Installation copies
# and verifies those exact bytes; it never changes an executable signature.
/usr/bin/codesign --verify --deep --strict "$staged"
python3 scripts/build-app-package.py verify-source --root "$PWD" --bundle "$staged"
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
printf '%s\n' "Installed $dest with the build signature preserved. Nothing was started and nothing was registered."
if [ -d "$other/Infinify.app" ]; then
  # A plain launch would follow that copy's registrations (its login item, its launch daemon); setup removes them with it.
  printf '%s\n' "Another copy is at $other/Infinify.app, and its login item and launch daemon are what start Infinify now." \
    "Open setup from the new copy; its first pane removes the other copy with both, then sets this one up:" \
    "  $dest/Contents/MacOS/Infinify setup"
else
  printf '%s\n' "Open it to set it up (permissions, the login item, compositor mode), or to start it once set up:  open $dest"
fi
printf '%s\n' "An instance that is already running keeps the previous build until it ends:"
printf '%s\n' "  $dest/Contents/MacOS/Infinify msg action quit"
printf '%s\n' "  launchctl kickstart gui/$(id -u)/com.marengox.infinify.agent   # when it runs as the login item"
