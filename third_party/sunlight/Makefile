APP        = build/Sunlight.app
EXE        = $(APP)/Contents/MacOS/Sunlight
BUNDLE_ID  = com.spacefarm.sunlight
# Signed with the first Developer ID Application or Apple Development identity in the keychain, so the
# Accessibility and Screen Recording grants survive rebuilds; ad-hoc where there's none. To choose:
#   make run SIGN="Apple Development: Your Name (TEAMID)"    # or SIGN=- for ad-hoc
SIGN      ?=

.PHONY: build app package dist sparkle-keys icon dmg-background live-windows run release status clean

build:
	swift build -c release

# build/Sunlight.app, signed. `package` adds build/Sunlight-<version>.zip and .dmg beside it.
app:
	SIGN="$(SIGN)" scripts/package.sh --app-only

package:
	SIGN="$(SIGN)" scripts/package.sh

# A public release in build/release/: notarized zip and DMG, Sparkle appcast, Homebrew cask. Needs
# NOTARY_PROFILE=<notarytool keychain profile>; see scripts/release.sh and INSTALL.md.
dist:
	SIGN="$(SIGN)" NOTARY_PROFILE="$(NOTARY_PROFILE)" scripts/release.sh

# Makes Sparkle's update-signing key pair once (the private half goes in the login keychain) and prints
# the public half for SPARKLE_PUBLIC_KEY in packaging/release.conf.
sparkle-keys:
	swift build -c release
	"$$(find .build/artifacts -type f -name generate_keys | head -1)"

# Refreshes Resources/Sunlight.icns, the fallback for builds without Xcode, from Resources/Sunlight.icon after
# changing it in Icon Composer. `make app` compiles the .icon itself when Xcode 26 or later is installed.
icon:
	scripts/compile-icon.sh build/icon
	cp build/icon/Sunlight.icns Resources/Sunlight.icns

# Re-renders the DMG window's background, packaging/dmg/background.png and background@2x.png (the hill
# photo with the install arrow), after changing scripts/make-dmg-background.swift. Both are checked in. The
# window's size and the icons' places are in scripts/make-dmg-layout.swift, which `make package` runs.
dmg-background:
	swift scripts/make-dmg-background.swift packaging/dmg

# Runs the binary straight out of the bundle so logs land in this terminal.
run: app
	$(EXE)

# Takeover mode escape hatches. They run the built binary; if the bundle is gone, rebuild it first.
release:
	@test -x $(EXE) || $(MAKE) app
	$(EXE) --release

status:
	@test -x $(EXE) || $(MAKE) app
	$(EXE) --status

# Just the live-window helper, add-on and loader, into build/live-windows/.
live-windows:
	scripts/build-live-windows.sh

clean:
	rm -rf .build build
