# Infinify

A GPL-3.0-or-later Rust and Objective-C port of [DriftWM](https://github.com/malbiruk/driftwm) to
Apple Silicon and macOS 26+. DriftWM's persistent infinite canvas becomes the desktop of live native Mac
windows: one canvas per display with its own camera, pan and zoom, DriftWM's bindings, gestures, window rules
and IPC, and native input, focus and recovery.

Infinify replaces the native desktop rather than adding an app to it: it is meant to be installed, started at
login and left running until you quit it. Literal Wayland and X11 client hosting is outside the scope.

## Requirements and status

- An Apple Silicon Mac on macOS 26 or later. The development host runs macOS 27.2, so macOS 26 execution is not
  verified. Rust 1.88+, the Xcode command-line tools and the macOS SDK build it; the build sets
  `MACOSX_DEPLOYMENT_TARGET=26.0`.
- **Screen Recording** (to capture windows) and **Accessibility** (native input, focus and sizing). While one is
  missing, a small window names it and offers an Allow button; the canvas opens once both are granted. Builds
  signed ad hoc lose both grants on every reinstall; sign with your own identity (see Install).
- Two modes. The default **capture overlay** draws live copies of the windows on the canvas and needs no change to
  SIP. **Compositor mode** has the window server itself draw the real windows where the canvas places them,
  through a helper loaded into the Dock; it needs a Developer-ID signed build, SIP debugging restrictions relaxed
  (which Dock injection requires), and a launch daemon that you approve once. See
  [Compositor mode](#compositor-mode).
- This is a pre-release. The [parity contract](docs/parity/README.md) tracks every difference from DriftWM; no row
  is `verified`. Native display-boundary clipping, physical multi-display behaviour, broad third-party
  application compatibility and macOS 26 execution remain open. The tests below do not change privacy settings or
  SIP, and nothing in them proves compositing of third-party windows.

## Install

These steps are for you to run; no script here registers a login item or a launch daemon on its own.

```sh
INFINIFY_SIGN_IDENTITY="<your signing identity>" ./scripts/install-app.sh
```

`security find-identity -v -p codesigning` lists identities. The script builds the app with that identity and copies
the exact signed bundle to `/Applications/Infinify.app` (where a disk image and Homebrew put it; `--user` installs in
`~/Applications`), after checking the outer signature, the executable hash and the helper hashes. With an identity the app, the loader, the doctor and the launch daemon are signed with the
hardened runtime; without the variable the build is ad hoc. `--built` installs the identity already used for that
build.

From a release's disk image, drag Infinify onto the Applications link beside it. Opened on the image instead (or from
Downloads), setup's first pane offers Move to Applications, which copies it there, replacing an older copy, and opens
it from there; copied into Applications by a command, which leaves macOS running it from a temporary translocated copy,
it opens itself from Applications instead.

Then `open /Applications/Infinify.app`. A copy left in the other Applications folder (an install from before this
default) keeps its login item and launch daemon until setup removes it: the script says so, and
`/Applications/Infinify.app/Contents/MacOS/Infinify setup` opens the assistant, whose first pane removes it. Until setup is done a plain launch shows the setup assistant: the two
permissions, the login item (Infinify starts at every login and after a crash), and compositor mode, the product, with
the Recovery steps while SIP still keeps the Dock helper out, or the demo (capture mode) until then. Once set up, a
plain launch and every login start compositor mode. Opening Infinify again while it runs shows the assistant again.
`Infinify uninstall` takes it off this Mac (login item, launch daemon, window settings, the bundle to the Trash). The
terminal commands do the same steps one by one: `login-item on | off | status`, `native-desktop enable | disable | status`.
[docs/native/user-guide.md](docs/native/user-guide.md#setup-the-demo-and-uninstall) says what each pane does.

### A release

For you to run, from a clean working tree; it publishes nothing.

```sh
INFINIFY_SIGN_IDENTITY="Developer ID Application: …" ./scripts/build-release.sh 0.2.0 [--notarize PROFILE]
```

It builds the app at that version (the build number is the commit count, so it only goes up), signs every artifact
with a secure timestamp, packs it with `scripts/package-dmg.sh` into a compressed disk image beside an Applications
link, mounts the image and checks the bundle inside it (signature, every file, `validate-bundle`), and writes
`target/dist/VERSION/`: `Infinify-VERSION.dmg`, `infinify-VERSION-source.tar.gz` (the same commit, for GPL-3.0
section 6), `SHA256SUMS` and `infinify.rb`, the Homebrew cask. `--notarize PROFILE` submits the image with the
`notarytool` keychain profile, keeps the service's log beside it, staples the ticket and checks the image with
`spctl`; create the profile once with `xcrun notarytool store-credentials PROFILE`, given an App Store Connect API key
(`--key AuthKey_ID.p8 --key-id ID --issuer ISSUER`, a team key with the Developer role) or an Apple ID
(`--apple-id … --team-id …` and an app-specific password). A release
signs the Dock payload with the identity too (`INFINIFY_SIGN_PAYLOAD=1`, which development builds leave off), because
the notary service refuses an ad hoc Mach-O: in the guest (macOS 27.0.1, SIP relaxed) the Dock loaded a payload signed
by team PBKWRHQV74 through the sudo path on 2026-10-30, launch outcome `ready`, the desktop presented natively. The
notary service accepted 0.2.0 that day with no issues, the arm64e loader and payload included, and a quarantined copy
of the stapled image passed Gatekeeper in the guest as `Notarized Developer ID`. The release
build replaces `target/app`. The script ends with the `gh release` and tap steps for when the repository is
public; friends then install with `brew install --cask iamgadmarconi/tap/infinify`.

## Run

```sh
./scripts/build-app.sh      # builds target/app/Infinify.app; launches nothing
open target/app/Infinify.app --args --demo
```

A plain `open` follows setup (above): the assistant, or compositor mode through the installed login item. `--demo` runs
the capture-mode desktop this section describes.

One canvas panel per display covers the whole display on every Space, under the menu bar and the Dock, which both
stay. There is no toolbar, status line or chooser; status notes go to stderr. Every real application window on
screen (a standard window or a dialog, not a popup or helper window) joins the canvas by itself.

- **Quit** with Control-Option-Escape, Control-Option-Command-Shift-Q or `Infinify msg action quit`. The scene is
  saved, the panels close and the native desktop returns.
- **What a run changes.** Stage Manager and macOS window tiling would fight the canvas, so while the canvas is
  open the run writes `false` to `GloballyEnabled`, `EnableTilingByEdgeDrag`, `EnableTopTilingByEdgeDrag` and
  `EnableTilingOptionAccelerator` in `com.apple.WindowManager` and `None` to the title-bar double-click
  (`AppleActionOnDoubleClick`, which would zoom a window's native frame behind its drawn copy) (an absent key is removed
  again afterwards), after
  saving your own values to `~/Library/Application Support/Infinify/window-prefs-snapshot.plist`. They are put
  back when it ends (quit, signal, log out) or, if it was killed, at the next launch. A setting you change
  yourself meanwhile stays as you set it. `--windowed`, `--manual` and `--only-pid` runs leave the settings alone.
- **Saved scene.** World positions are saved in `~/Library/Application Support/Infinify/scene.json`. Cameras are
  restored only with `[session] restore_camera = true`. A scene file with an unsupported schema version or invalid contents is refused whole: the
  shell says so, preserves the file and does not save over it.
- `Infinify --help` lists every option. The user options are `--state`, `--socket`, `--config`, `--super`,
  `--no-native-focus` and `--no-hover-forwarding`. `--native-desktop-helper` is the launcher's whole-desktop flag,
  started by `Infinify native-desktop`. `--windowed`, `--manual`, `--only-pid`, `--debug-pointer` and `--native-helper`
  are a test seam for live tests on disposable windows ([docs/native/user-guide.md](docs/native/user-guide.md#flags-that-change-it)).

## Controls

With no config file, DriftWM's default bindings apply under the default super key, Control-Option (`--super cmd`
uses Command instead):

| Do | With |
| --- | --- |
| Pan | drag blank canvas, or Control-Option-drag anywhere |
| Zoom | mouse wheel on blank canvas, Control-Option-scroll anywhere, or pinch |
| Move a window in the world | Option-drag (add Shift to move its snapped cluster) |
| Nearest window | Control-Option-arrows |
| Centre the focused window | Control-Option-C |
| Cycle windows, most recently focused first | Option-Tab |
| Fit / fullscreen the focused window | Control-Option-M / Control-Option-F |

Unmodified clicks and scrolling on a window reach its native application, which keeps keyboard focus; Command
editing shortcuts and Command-Tab stay with the applications. Every binding, action and default table is in
[docs/crates/desktop/CONFIG.md](docs/crates/desktop/CONFIG.md); a config file's bindings take precedence.

## Configuration

The config file is DriftWM's grammar. The app reads `--config ABSOLUTE_PATH`, else
`$XDG_CONFIG_HOME/infinify/config.toml`, else `~/.config/infinify/config.toml`; DriftWM's built-in defaults apply
when it is missing, and the file is read again whenever it changes. What a file gets wrong is drawn in the error
bar. See [CONFIG.md](docs/crates/desktop/CONFIG.md) for `[session]`, `[background]`, `[[window_rules]]`, `[effects]`
and every other table, and [RULES.md](docs/crates/desktop/RULES.md) for window rules.

## Scripting

`Infinify msg [--json] [--socket PATH] COMMAND ...` is DriftWM's IPC client for the running app. The socket is
`~/Library/Application Support/Infinify/infinify.sock` unless `--socket` says otherwise. Requests, replies and
limits are in [docs/crates/desktop/IPC.md](docs/crates/desktop/IPC.md).

## Compositor mode

`Infinify native-desktop --check | enable | disable | status` (run from a terminal, with no `DYLD_*` variable set)
drives the bundled launcher. `--check` verifies the package and runs the read-only doctor without sudo.
`enable` registers the app's launch daemon (you approve it once in Login Items & Extensions), makes the login item
start compositor mode, and starts it. A login then loads the Dock helper by itself, and a Dock restart is
noticed and reloaded from the helper's journal; three Dock restarts in a row around loads pause automatic loading
until you run `Infinify native-desktop` by hand. `status` changes nothing; `disable` reverts it. Builds signed ad
hoc cannot use the daemon.

The safety model (journal before every mutation, identity fences, the daemon accepting only this signed app, a
root-owned staged copy of the payload) is in [docs/native/dock-helper/README.md](docs/native/dock-helper/README.md); what
compositor mode does to windows, popups and drags is in
[docs/native/app/CompositorMode/COMPOSITOR-MODE.md](docs/native/app/CompositorMode/COMPOSITOR-MODE.md). It has been run only in disposable macOS
27 guests, not on a physical Mac and not on macOS 26.

## Troubleshooting

- **No canvas, a permission window instead.** Grant Screen Recording and Accessibility, then Relaunch. After an
  ad-hoc rebuild macOS drops the grants again.
- **Diagnostics.** `INFINIFY_DEBUG=1 target/app/Infinify.app/Contents/MacOS/Infinify` from a terminal adds the
  shell's diagnostics to stderr.
- **Files.** Under `~/Library/Application Support/Infinify`: `scene.json`, `infinify.sock`,
  `window-prefs-snapshot.plist`, and `native-desktop/` (`login.plist`, `login.log`, `auto-reload-paused.plist`).
- **A second instance** exits at once; nothing prevents starting one except that.
- **After sleep** a window whose capture macOS stopped is not captured again by itself.
- **Scene refused.** Move or delete `scene.json` (and any `--state` file) to start from an empty canvas.

## Development

| Path | Contents |
| --- | --- |
| `crates/canvas` | the platform-independent window canvas: scene, camera, snapping, stage |
| `crates/core` | DriftWM's pure modules ported to Rust (canvas math, config, layout), see [PORT.md](docs/crates/core/PORT.md) |
| `crates/desktop` | the controller library and C interface: actions, navigation, sizing, rules, IPC, rendering requests; [README](docs/crates/desktop/README.md) |
| `native/app` | the Objective-C shell and renderer, linked with the controller, one directory per module (Desktop, Canvas, Windows, Input, CompositorMode, Navigation (with the Accessibility focus and resize adapters), System, Support, Resources); [README](docs/native/README.md) |
| `native/dock-helper` | the Dock helper (Payload), loader and doctor (Loader), launch daemon (Daemon) and client library (Client); [README](docs/native/dock-helper/README.md) |
| `tests/native` | the headless regressions and the disposable AppKit fixtures that the live tests start, one directory per module of `native/app` and `native/dock-helper`; [how they run](docs/native/testing.md) |
| `scripts` | `build-app.sh`, `build-privileged.sh`, `install-app.sh`, `build-release.sh`, `package-dmg.sh`, the launcher and packaging helpers |
| `docs` | all Markdown documentation outside this file and `AGENTS.md`: `docs/native` (user guide, module docs), `docs/crates` (each crate's contracts), `docs/parity`; [index](docs/README.md) |
| `docs/parity` | the parity contract |

```sh
./scripts/check.sh                               # full suite, on request: fmt, clippy, tests, build, packaging, e2e
./scripts/build-app.sh                           # app bundle in target/app
cargo fmt --check
cargo clippy -p driftwm-core -p driftwm-canvas -p driftwm-desktop --all-targets --locked -- -D warnings
python3 scripts/test-build-app-package.py       # packaging
```

Focused tests (run these, not the whole suite): `cargo test -p driftwm-canvas --test snap_parity --test stage_parity`
and `cargo test -p driftwm-desktop --test controller_flow --test navigation_flow --test native_resize_flow`, plus the
`tests/e2e` scripts below. Headless scripts build a small program from the real shell sources and run it with no
window, event, permission or Dock; the live ones start disposable fixture windows or need a guest.

| Script | Covers | Live |
| --- | --- | --- |
| `background-tiff.sh` | crafted and mutated TIFF wallpapers: a picture or an error, never a crash or hang | no |
| `capture-configuration.sh` | capture request and rate state | no |
| `compositor-lifetime.sh` | the CPU lifetime fence of the compositor | no |
| `controller-hit.sh` | the controller's `{"hit": null}` answer through the shell's hit reply | no |
| `desktop-navigation.sh`, `desktop-resize.sh` | the navigation and resize coordinators against the real controller | no |
| `family-geometry.sh` | renderer queries for window families | no |
| `ipc-limits.sh` | IPC limits and the atomic screenshot write on the production server and writer | no |
| `mac-wallpaper-refresh.sh` | the wallpaper refresh timing policy | no |
| `multitouch-source.sh` | synthetic MultitouchSupport records and the Dock-control decision | no |
| `native-daemon.sh` | the launch daemon's and Dock reloader's decisions, caller requirement and artifact checks | no |
| `native-launcher.sh` | the bundled launcher's modes against stub tools and a throwaway HOME | no |
| `native-decorations.sh`, `native-display-space-cache.sh`, `native-family-recovery.sh`, `native-frame-restore.sh`, `native-input-policy.sh`, `native-placement-validation.sh`, `native-presenter-readiness.sh`, `native-view-transfer.sh` | the native presenter, views, placement, input policy and recovery logic with substituted native calls | no |
| `native-focus.sh` | the focus adapter refuses an identity that is not a live window | no |
| `privileged-regression.sh` | the Dock payload and its C client with substituted native calls | no |
| `root-capture-mailbox.sh` | the root capture mailbox and captured-input acceptance code | no |
| `system-takeover.sh` | the Stage Manager, tiling and title-bar double-click snapshot and restore against an in-memory store | no |
| `window-discovery.sh`, `window-events.sh` | window discovery scheduling and the application and window lifecycle events | no |
| `scoped-windows.sh`, `scoped-sizing.sh`, `scoped-resize-drag.sh`, `scoped-native.sh`, `physical-resize-edge.sh`, `native-drag-drop.sh` | the product on disposable fixture windows of the test's own (`--only-pid`) | yes |
| `privileged-fixture.sh`, `compositor-dnd.sh` | the Dock helper and drag-and-drop in compositor mode; guest only, off unless a live flag is given | yes |

[AGENTS.md](AGENTS.md) holds the development rules: default commands are read-only, native mutation touches only
the disposable fixture a test starts, the original state is restored on every exit, and a reducer test or a
successful API return is never presented as proof of third-party window compositing.

## Provenance and licence

Infinify is distributed under [GPL-3.0-or-later](LICENSE). [NOTICE](NOTICE) names every upstream the code embeds or
adapts, with repository, commit and licence: DriftWM v0.21.0
(`df3de27b26c7998e8a460cffd8a4925cbed3a322`), Sunlight (MIT), yabai (MIT), iss (ISC) and the Smithay and
xkbcommon-derived tables (MIT). Each embedded file's header names the upstream path it follows. The app bundle
carries LICENSE, NOTICE and the Sunlight and yabai notices.
